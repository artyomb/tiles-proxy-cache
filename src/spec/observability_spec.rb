# frozen_string_literal: true

RSpec.describe Observability do
  around do |example|
    original_env = ENV.to_h
    example.run
  ensure
    ENV.replace(original_env)
  end

  describe '.configure_environment!' do
    it 'keeps stack-service-base in performance mode with service info logs by default' do
      ENV.delete('PERFORMANCE')
      ENV.delete('QUIET')
      ENV['CONSOLE_LEVEL'] = 'all'

      described_class.configure_environment!

      expect(ENV['PERFORMANCE']).to eq('true')
      expect(ENV['QUIET']).to eq('false')
      expect(ENV['CONSOLE_LEVEL']).to eq('info')
    end

    it 'does not override an explicit console level' do
      ENV['CONSOLE_LEVEL'] = 'error'

      described_class.configure_environment!

      expect(ENV['CONSOLE_LEVEL']).to eq('error')
    end
  end

  describe '.rack_instrumentation_config' do
    it 'suppresses Rack spans for tile requests' do
      config = described_class.rack_instrumentation_config

      expect(config[:untraced_requests].call('REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/base/12/2401/1532')).to eq(true)
      expect(config[:untraced_requests].call('REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/api/stats/jobs')).to eq(false)
    end

    it 'can suppress all Rack requests for quiet auto instrumentation mode' do
      config = described_class.rack_instrumentation_config(untraced_all: true)

      expect(config[:untraced_requests].call('REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/api/stats/jobs')).to eq(true)
    end
  end

  describe '.suppress_async_task_exception?' do
    it 'suppresses only expected client disconnect noise' do
      expect(described_class.suppress_async_task_exception?(Errno::EPIPE.new)).to eq(true)
      expect(described_class.suppress_async_task_exception?(Errno::ECONNRESET.new)).to eq(true)

      expect(described_class.suppress_async_task_exception?(RuntimeError.new('boom'))).to eq(false)
    end
  end

  describe '.upstream_slow_ms' do
    it 'uses the service slow upstream threshold' do
      ENV['TPC_UPSTREAM_SLOW_MS'] = '2500'

      expect(described_class.upstream_slow_ms).to eq(2500)
    end
  end

  describe '.measure_duration' do
    it 'returns the result, duration and wall clock boundaries' do
      result, duration_ms, started_at, finished_at = described_class.measure_duration { 'ok' }

      expect(result).to eq('ok')
      expect(duration_ms).to be >= 0
      expect(started_at).to be_a(Time)
      expect(finished_at).to be_a(Time)
      expect(finished_at).to be >= started_at
    end
  end

  describe '.upstream_host' do
    it 'extracts host from templated upstream target' do
      host = described_class.upstream_host('https://tiles.example.test/{z}/{x}/{y}.png')

      expect(host).to eq('tiles.example.test')
    end
  end

  describe '.suppress_socket_trace?' do
    it 'suppresses stack-service-base socket trace logs unless explicitly enabled' do
      expect(described_class.suppress_socket_trace?).to eq(true)

      ENV['TPC_SOCKET_TRACE_LOGS'] = 'true'

      expect(described_class.suppress_socket_trace?).to eq(false)
    end
  end
end

RSpec.describe 'SQL observability' do
  around do |example|
    original_env = ENV.to_h
    example.run
  ensure
    ENV.replace(original_env)
  end

  it 'uses Sequel native slow SQL warning threshold without info-level fast SQL' do
    ENV['TPC_SQL_SLOW_MS'] = '750'
    db = Sequel.connect('sqlite:/')

    Observability.configure_sql_logging(db)

    expect(db.sql_log_level).to eq(:debug)
    expect(db.log_warn_duration).to eq(0.75)
  ensure
    db&.disconnect
  end
end

RSpec.describe UpstreamObservability do
  class FakeUpstreamSpan
    attr_reader :name, :attributes, :start_timestamp, :kind, :events, :end_timestamp
    attr_accessor :status

    def initialize(name:, attributes:, start_timestamp:, kind:)
      @name = name
      @attributes = attributes
      @start_timestamp = start_timestamp
      @kind = kind
      @events = []
    end

    def add_event(name, attributes: nil, timestamp: nil)
      @events << { name: name, attributes: attributes, timestamp: timestamp }
    end

    def finish(end_timestamp: nil)
      @end_timestamp = end_timestamp
    end
  end

  class FakeUpstreamTracer
    attr_reader :spans

    def initialize
      @spans = []
    end

    def start_span(name, attributes:, start_timestamp:, kind:)
      FakeUpstreamSpan.new(name: name, attributes: attributes, start_timestamp: start_timestamp, kind: kind).tap do |span|
        @spans << span
      end
    end
  end

  around do |example|
    original_env = ENV.to_h
    original_tracer = defined?($tracer_) ? $tracer_ : nil
    example.run
  ensure
    ENV.replace(original_env)
    $tracer_ = original_tracer
  end

  it 'creates a detailed manual client span for slow upstream requests' do
    ENV['TPC_UPSTREAM_SLOW_MS'] = '1500'
    $tracer_ = FakeUpstreamTracer.new
    started_at = Time.utc(2026, 5, 7, 10, 0, 0)
    finished_at = started_at + 1.7

    described_class.record(
      source: 'demo',
      z: 12,
      x: 2401,
      y: 1532,
      status: 200,
      reason: 'ok',
      duration_ms: 1700,
      started_at: started_at,
      finished_at: finished_at,
      bytes: 512,
      content_type: 'image/png',
      host: 'tiles.example.test'
    )

    span = $tracer_.spans.first
    expect(span.name).to eq('upstream.slow')
    expect(span.kind).to eq(:client)
    expect(span.start_timestamp).to eq(started_at)
    expect(span.end_timestamp).to eq(finished_at)
    expect(span.attributes).to include(
      'tpc.upstream.event' => 'upstream_slow',
      'tpc.upstream.duration_ms' => 1700,
      'http.response.status_code' => 200,
      'server.address' => 'tiles.example.test'
    )
    expect(span.status).to be_nil
  end

  it 'does not create spans for normal upstream requests' do
    ENV['TPC_UPSTREAM_SLOW_MS'] = '1500'
    $tracer_ = FakeUpstreamTracer.new

    described_class.record(
      source: 'demo',
      z: 12,
      x: 2401,
      y: 1532,
      status: 200,
      reason: 'ok',
      duration_ms: 20
    )

    expect($tracer_.spans).to be_empty
  end

  it 'creates a manual client span for upstream errors' do
    $tracer_ = FakeUpstreamTracer.new
    started_at = Time.utc(2026, 5, 7, 10, 0, 0)
    finished_at = started_at + 0.05

    described_class.record(
      source: 'demo',
      z: 12,
      x: 2401,
      y: 1532,
      status: 503,
      reason: 'http_error',
      duration_ms: 50,
      started_at: started_at,
      finished_at: finished_at,
      error_class: 'Faraday::TimeoutError',
      error: 'timeout'
    )

    span = $tracer_.spans.first
    expect(span.name).to eq('upstream.error')
    expect(span.attributes).to include(
      'tpc.upstream.event' => 'upstream_error',
      'http.response.status_code' => 503,
      'error.type' => 'Faraday::TimeoutError',
      'exception.message' => 'timeout'
    )
  end
end
