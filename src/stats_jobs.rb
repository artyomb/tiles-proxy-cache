# frozen_string_literal: true

require 'time'
require 'rbconfig'
require_relative 'view_helpers'
require_relative 'observability_setup'

module StatsJobEntry
  module_function

  def call
    require 'yaml'
    require 'sequel'

    config_folder = ENV.fetch('STATS_CONFIG_FOLDER')
    routes = Dir["#{config_folder}/*.{yaml,yml}"].map { YAML.load_file(_1, symbolize_names: true) }.reduce({}, :merge)
    source = ENV.fetch('STATS_SOURCE')
    aggregator = StatsAggregator.new
    route = routes.find { |name, _| name.to_s == source }&.last
    raise ArgumentError, "Unknown stats source: #{source}" unless route

    on_progress = lambda do |progress|
      Marshal.dump({ progress: progress }, STDOUT)
      STDOUT.flush
    end
    result = aggregator.collect_route_stats(route, source, on_progress:)

    Marshal.dump({ ok: true, result: }, STDOUT)
    STDOUT.flush
    exit! 0
  rescue => e
    Marshal.dump({ ok: false, error: { class: e.class.name, message: e.message, backtrace: e.backtrace } }, STDOUT) rescue nil
    exit! 1
  end
end

class StatsAggregator
  include ViewHelpers

  DEFAULT_SQLITE_OPTIONS = {
    readonly: true,
    max_connections: 1,
    timeout: 10_000
  }.freeze

  def initialize(sqlite_options: DEFAULT_SQLITE_OPTIONS, db_connector: nil)
    @sqlite_options = sqlite_options
    @db_connector = db_connector || method(:connect_sqlite)
  end

  def collect_route_stats(route, source_name, on_progress: nil)
    db_path = resolve_mbtiles_path(route[:mbtiles_file])
    raise ArgumentError, "MBTiles path is not configured for #{source_name}" if db_path.nil? || db_path.empty?

    cache_size = get_tiles_size(route)
    on_progress&.call(cache_size:)
    @db_connector.call(db_path, **@sqlite_options) do |db|
      collect_source_stats(route:, source_name:, db:, cache_size:, on_progress:)
    end
  end

  def collect_source_stats(route:, source_name:, db:, cache_size:, on_progress:)
    min_zoom = route[:minzoom] || 1
    max_zoom = route[:maxzoom] || 20

    cached_expr = Sequel.function(:sum, Sequel.case([[{ generated: 0 }, 1], [{ generated: nil }, 1]], 0))
    generated_expr = Sequel.function(:sum, Sequel.case([[Sequel[:generated] > 0, 1]], 0))

    tiles_by_zoom = if db.table_exists?(:tiles)
                      db[:tiles]
                        .select(:zoom_level, Sequel.as(cached_expr, :cached), Sequel.as(generated_expr, :generated))
                        .where(zoom_level: min_zoom..max_zoom)
                        .group(:zoom_level)
                        .to_hash(:zoom_level)
                    else
                      {}
                    end
    on_progress&.call(tiles_count: tiles_by_zoom.values.sum { |row| (row[:cached] || 0).to_i + (row[:generated] || 0).to_i })

    autoscan_statuses = if db.table_exists?(:tile_scan_progress)
                          db[:tile_scan_progress]
                            .where(source: source_name)
                            .to_hash(:zoom_level, :status)
                        else
                          {}
                        end

    errors_by_zoom = if db.table_exists?(:misses)
                       db[:misses]
                         .select(:zoom_level, Sequel.function(:count, Sequel.lit('*')).as(:count))
                         .group(:zoom_level)
                         .to_hash(:zoom_level, :count)
                     else
                       {}
                     end
    misses_count = errors_by_zoom.values.sum(&:to_i)
    on_progress&.call(misses_count:)

    bounds_str = route.dig(:metadata, :bounds) || '-180,-85.0511,180,85.0511'

    coverage_data = (min_zoom..max_zoom).map do |zoom|
      possible = GeometryTileCalculator.count_tiles_in_bounds_string(bounds_str, zoom)
      zoom_data = tiles_by_zoom[zoom] || {}
      cached = (zoom_data[:cached] || 0).to_i
      generated = (zoom_data[:generated] || 0).to_i
      errors = (errors_by_zoom[zoom] || 0).to_i
      remaining = [possible - cached - generated - errors, 0].max

      {
        zoom: zoom,
        percentage: possible.positive? ? ((cached.to_f / possible) * 100).round(1) : 0,
        cached: cached,
        possible: possible,
        errors: errors,
        remaining: remaining,
        generated: generated,
        autoscan_status: autoscan_statuses[zoom] || 'waiting'
      }
    end

    total_cached = coverage_data.sum { _1[:cached] }
    total_generated = coverage_data.sum { _1[:generated] }
    total_possible = coverage_data.sum { _1[:possible] }

    {
      tiles_count: total_cached + total_generated,
      misses_count: misses_count,
      cache_size: cache_size,
      coverage_data: coverage_data,
      coverage_percentage: total_possible.positive? ? format('%.8f', (total_cached.to_f / total_possible) * 100).sub(/\.?0+$/, '') : '0'
    }
  end

  private

  def connect_sqlite(db_path, **options, &block)
    Sequel.connect("sqlite://#{db_path}", **Observability.sql_logging_options.merge(options), &block)
  end
end

class StatsForkRunner
  DEFAULT_TIMEOUT = 300
  DEFAULT_KILL_GRACE_PERIOD = 5
  POLL_INTERVAL = 0.1

  Handle = Struct.new(:pid, :reader, :stderr_reader, :started_at, keyword_init: true)
  Result = Struct.new(:status, :result, :error, keyword_init: true)

  def initialize(timeout: DEFAULT_TIMEOUT, kill_grace_period: DEFAULT_KILL_GRACE_PERIOD)
    @timeout = timeout
    @kill_grace_period = kill_grace_period
  end

  def start(source:)
    reader, writer = IO.pipe
    stderr_reader, stderr_writer = IO.pipe
    started_at = Time.now.utc

    pid = Process.spawn(
      stats_child_env(source),
      RbConfig.ruby,
      __FILE__,
      out: writer,
      err: stderr_writer,
      pgroup: true,
      chdir: __dir__
    )

    writer.close
    stderr_writer.close
    Handle.new(pid:, reader:, stderr_reader:, started_at:)
  rescue
    close_ios(reader, writer, stderr_reader, stderr_writer)
    raise
  end

  def wait(handle, &on_progress)
    deadline = monotonic_time + @timeout
    payload = nil
    reader_error = nil
    reader = Thread.new do
      Thread.current.report_on_exception = false
      loop do
        message = Marshal.load(handle.reader)
        if message.is_a?(Hash) && message.key?(:progress)
          on_progress&.call(message[:progress])
        else
          payload = message
        end
      end
    rescue EOFError
      nil
    rescue => e
      reader_error = e
    end

    loop do
      waited_pid, process_status = Process.waitpid2(handle.pid, Process::WNOHANG)
      if waited_pid
        reader.join(5)
        stderr_output = handle.stderr_reader.read.to_s
        return Result.new(status: 'failed', error: "Stats payload read failed: #{reader_error.message}") if reader_error && !payload

        return payload_to_result(payload, process_status, stderr_output)
      end

      if monotonic_time >= deadline
        terminate(handle.pid)
        wait_for_exit(handle.pid)
        reader.join(1)
        return Result.new(status: 'timed_out', error: "Stats job timed out after #{@timeout}s")
      end

      sleep POLL_INTERVAL
    end
  rescue => e
    Result.new(status: 'failed', error: "Stats job runner failed: #{e.message}")
  ensure
    reader&.kill if reader&.alive?
    close_ios(handle.reader, handle.stderr_reader)
  end

  def terminate(pid)
    signal_process_group(pid, 'TERM')
    deadline = monotonic_time + @kill_grace_period

    loop do
      waited_pid, = Process.waitpid2(pid, Process::WNOHANG)
      return if waited_pid
      break if monotonic_time >= deadline

      sleep POLL_INTERVAL
    end

    signal_process_group(pid, 'KILL')
  rescue Errno::ECHILD
    nil
  end

  private

  def payload_to_result(payload, process_status = nil, stderr_output = nil)
    unless payload
      error = 'Stats job returned no payload'
      error = "#{error}: #{stderr_output.lines.first&.strip}" if stderr_output && !stderr_output.empty?
      detail = process_status_detail(process_status)
      error = "#{error} (#{detail})" if detail
      return Result.new(status: 'failed', error: error)
    end
    return Result.new(status: 'completed', result: payload[:result]) if payload[:ok]

    message = payload.dig(:error, :message) || 'Stats job failed'
    Result.new(status: 'failed', error: message)
  end

  def wait_for_exit(pid)
    Process.waitpid(pid)
  rescue Errno::ECHILD
    nil
  end

  def signal_process_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end

  def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def stats_child_env(source)
    env = {
      'BUNDLE_GEMFILE' => ENV['BUNDLE_GEMFILE'] || File.expand_path('Gemfile', __dir__),
      'RACK_ENV' => ENV['RACK_ENV'].to_s,
      'STATS_JOB_CHILD' => '1',
      'STATS_CONFIG_FOLDER' => stats_config_folder
    }
    env['STATS_SOURCE'] = source
    env
  end

  def stats_config_folder = ENV['STATS_CONFIG_FOLDER'] || (ENV['RACK_ENV'] == 'production' ? '/configs' : File.expand_path('configs', __dir__))

  def process_status_detail(process_status)
    return unless process_status
    return "signal=#{process_status.termsig}" if process_status.signaled?

    "exitstatus=#{process_status.exitstatus}"
  end

  def close_ios(*ios)
    ios.each { _1&.close unless _1&.closed? }
  end
end

StatsJobEntry.call if ENV['STATS_JOB_CHILD'] == '1' && $PROGRAM_NAME == __FILE__
