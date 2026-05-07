# frozen_string_literal: true

require 'uri'

module Observability
  extend self

  DEFAULT_CONSOLE_LEVEL = 'info'
  DEFAULT_UPSTREAM_SLOW_MS = 1_500

  def configure_environment!
    ENV['PERFORMANCE'] ||= 'true'
    ENV['QUIET'] ||= 'false'
    ENV['CONSOLE_LEVEL'] = ENV.fetch('TPC_LOG_LEVEL', DEFAULT_CONSOLE_LEVEL) if ENV['CONSOLE_LEVEL'].nil? || ENV['CONSOLE_LEVEL'] == 'all'
    ENV['OTEL_LOG_LEVEL'] = 'info' if ENV.fetch('OTEL_LOG_LEVEL', 'info') == 'debug'
    ENV['OTEL_TRACES_EXPORTER'] = 'otlp' if ENV['OTEL_TRACES_EXPORTER'] == 'console,otlp'
    ENV['OTEL_LOGS_EXPORTER'] = 'otlp' if ENV['OTEL_LOGS_EXPORTER'] == 'otlp,console'
  end

  def patch_stack_service_base!
    configure_environment!
    patch_otel_initialize!
    patch_async_client_disconnect_warnings!
    patch_socket_trace_noise!
  end

  def otel_auto_instrumentation
    ENV.fetch('TPC_OTEL_AUTO_INSTRUMENTATION', 'none').downcase
  end

  def rack_instrumentation_config(untraced_all: false)
    {
      use_rack_events: false,
      untraced_requests: lambda do |env|
        untraced_all || tile_request?(env) || env['PATH_INFO'] == '/healthcheck'
      end
    }
  end

  def suppress_async_task_exception?(exception)
    exception.is_a?(Errno::EPIPE) || exception.is_a?(Errno::ECONNRESET)
  end

  def suppress_socket_trace?
    ENV.fetch('TPC_SOCKET_TRACE_LOGS', 'false') != 'true'
  end

  def upstream_slow_ms
    Integer(ENV.fetch('TPC_UPSTREAM_SLOW_MS', DEFAULT_UPSTREAM_SLOW_MS.to_s))
  end

  def sql_logging_options
    {
      sql_log_level: ENV.fetch('TPC_SQL_LOG_LEVEL', 'debug').to_sym,
      log_warn_duration: Float(ENV.fetch('TPC_SQL_SLOW_MS', '500')) / 1000
    }
  end

  def configure_sql_logging(db)
    options = sql_logging_options
    db.sql_log_level = options[:sql_log_level] if db.respond_to?(:sql_log_level=)
    db.log_warn_duration = options[:log_warn_duration] if db.respond_to?(:log_warn_duration=)
    db
  end

  def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def measure_duration
    started_at = monotonic_time
    wall_started_at = Time.now.utc
    result = yield
    wall_finished_at = Time.now.utc
    [result, ((monotonic_time - started_at) * 1000).round, wall_started_at, wall_finished_at]
  end

  def upstream_host(target)
    URI.parse(target.to_s.gsub(/[{}]/, '_')).host
  rescue URI::InvalidURIError
    nil
  end

  private

  def patch_otel_initialize!
    return unless Object.method_defined?(:otel_initialize) || Object.private_method_defined?(:otel_initialize)
    return if Object.method_defined?(:tpc_ssbase_otel_initialize) || Object.private_method_defined?(:tpc_ssbase_otel_initialize)

    # reason: ssbase does not expose instrumentation selection before rack_setup calls otel_initialize.
    Object.class_eval do
      alias_method :tpc_ssbase_otel_initialize, :otel_initialize

      def otel_initialize
        return tpc_ssbase_otel_initialize if Observability.otel_auto_instrumentation == 'all'

        Observability.send(:otel_initialize_limited)
      end
    end
  end

  def otel_initialize_limited
    Object.class_eval do
      return unless defined?(OTEL_ENABLED) && OTEL_ENABLED
      return unless defined?(OpenTelemetry::SDK)

      service_name = ENV['STACK_SERVICE_NAME'] || 'tiles-proxy-cache'

      OpenTelemetry::SDK.configure do |c|
        if Observability.otel_auto_instrumentation == 'rack'
          c.use('OpenTelemetry::Instrumentation::Rack', Observability.rack_instrumentation_config)
          c.use('OpenTelemetry::Instrumentation::Sinatra', install_rack: false)
        else
          c.use('OpenTelemetry::Instrumentation::Rack', Observability.rack_instrumentation_config(untraced_all: true))
        end
      end

      at_exit do
        OpenTelemetry.tracer_provider.force_flush
        OpenTelemetry.tracer_provider.shutdown
        OpenTelemetry.logger_provider.shutdown if OpenTelemetry.respond_to?(:logger_provider)
      end

      $tracer_ = OpenTelemetry.tracer_provider.tracer(service_name)
      otl_span("#{service_name}.start", {
        stack_name: ENV['STACK_NAME'],
        service_name: service_name,
        rack_env: ENV['RACK_ENV']
      }) {}
    end
  end

  def tile_request?(env)
    env['REQUEST_METHOD'] == 'GET' && env['PATH_INFO'].to_s.match?(%r{/\d+/\d+/\d+\z})
  end

  def patch_async_client_disconnect_warnings!
    return unless defined?(Async::Task)
    return if Async::Task < AsyncClientDisconnectWarningsPatch

    Async::Task.prepend(AsyncClientDisconnectWarningsPatch)
  end

  def patch_socket_trace_noise!
    return unless defined?(StackServiceBase::SocketTrace)
    return if StackServiceBase::SocketTrace < SocketTraceNoisePatch

    StackServiceBase::SocketTrace.prepend(SocketTraceNoisePatch)
  end

  module AsyncClientDisconnectWarningsPatch
    private

    def warn(subject, message, exception: nil, **options)
      if Observability.suppress_async_task_exception?(exception)
        LOGGER.debug("event=client_disconnect task=#{subject} error_class=#{exception.class.name} error=#{exception.message}") if defined?(LOGGER)
        return
      end

      super
    end
  end

  # reason: ssbase logs low-level socket operations at info and has no env switch for it.
  module SocketTraceNoisePatch
    def bind(local_sockaddr)
      return super(local_sockaddr) unless Observability.suppress_socket_trace?

      raw_socket_method = method(__method__).super_method&.super_method
      raw_socket_method ? raw_socket_method.call(local_sockaddr) : super(local_sockaddr)
    end

    def setsockopt(level, optname, optval)
      return super(level, optname, optval) unless Observability.suppress_socket_trace?

      raw_socket_method = method(__method__).super_method&.super_method
      raw_socket_method ? raw_socket_method.call(level, optname, optval) : super(level, optname, optval)
    end
  end
end

module UpstreamObservability
  extend self

  PROBLEM_REASON_PATTERN = /invalid_content_type|decode_error|processing_error|conversion_error|exception/.freeze

  def record(source:, z:, x:, y:, status:, reason:, duration_ms:, started_at: nil, finished_at: nil,
             bytes: nil, content_type: nil, host: nil, **attrs)
    event = event_for(status: status, reason: reason, duration_ms: duration_ms)
    return unless event

    payload = {
      event: event,
      source: source,
      z: z,
      x: x,
      y: y,
      status: status,
      reason: reason,
      duration_ms: duration_ms,
      bytes: bytes,
      content_type: content_type,
      host: host
    }.merge(attrs)

    LOGGER.warn(format_log(payload)) if defined?(LOGGER)
    record_span(payload, started_at: started_at, finished_at: finished_at)
  end

  def event_for(status:, reason:, duration_ms:)
    slow_ms = upstream_slow_ms
    slow = duration_ms && slow_ms.positive? && duration_ms >= slow_ms
    problem_reason = reason.to_s.match?(PROBLEM_REASON_PATTERN)
    status_code = status.to_i

    if status_code >= 500 || status_code.zero? || problem_reason
      'upstream_error'
    elsif [401, 403, 429].include?(status_code)
      'upstream_blocked'
    elsif slow
      'upstream_slow'
    end
  end

  private

  def upstream_slow_ms
    Observability.upstream_slow_ms
  end

  def format_log(payload)
    "event=#{payload[:event]} source=#{payload[:source]} z=#{payload[:z]} x=#{payload[:x]} y=#{payload[:y]} " \
      "status=#{payload[:status]} reason=#{payload[:reason]} duration_ms=#{payload[:duration_ms]} " \
      "bytes=#{payload[:bytes]} content_type=#{payload[:content_type]} host=#{payload[:host]} " \
      "#{extra_log_attrs(payload).map { |key, value| "#{key}=#{value}" }.join(' ')}".strip
  end

  def extra_log_attrs(payload)
    payload.reject do |key, _|
      %i[event source z x y status reason duration_ms bytes content_type host].include?(key)
    end
  end

  def record_span(payload, started_at:, finished_at:)
    return unless defined?($tracer_) && $tracer_

    attributes = span_attributes(payload)
    span = nil
    begin
      span = $tracer_.start_span(
        payload[:event].tr('_', '.'),
        attributes: attributes,
        start_timestamp: started_at,
        kind: :client
      )

      if error_span?(payload) && defined?(OpenTelemetry::Trace::Status)
        span.status = OpenTelemetry::Trace::Status.error(payload[:reason].to_s)
      end
      span.add_event('upstream.result', attributes: attributes, timestamp: finished_at)
    ensure
      span&.finish(end_timestamp: finished_at || Time.now.utc)
    end
  rescue => e
    LOGGER.debug("event=upstream_span_error error_class=#{e.class.name} error=#{e.message}") if defined?(LOGGER)
  end

  def span_attributes(payload)
    {
      'tpc.upstream.event' => payload[:event],
      'tpc.source' => payload[:source],
      'tpc.tile.z' => payload[:z],
      'tpc.tile.x' => payload[:x],
      'tpc.tile.y' => payload[:y],
      'tpc.upstream.reason' => payload[:reason],
      'tpc.upstream.duration_ms' => payload[:duration_ms],
      'http.response.status_code' => payload[:status],
      'http.response.body.size' => payload[:bytes],
      'http.response.header.content_type' => payload[:content_type],
      'server.address' => payload[:host],
      'error.type' => payload[:error_class],
      'exception.message' => payload[:error]
    }.reject { |_, value| value.nil? }
  end

  def error_span?(payload)
    payload[:event] != 'upstream_slow' || payload[:status].to_i >= 500 || payload[:status].to_i.zero?
  end
end

unless ENV['TPC_OBSERVABILITY_SETUP'] == 'false'
  Observability.configure_environment!
end
