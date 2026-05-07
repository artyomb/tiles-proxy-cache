# frozen_string_literal: true

require 'securerandom'
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
    result = StatsAggregator.new(routes:).call

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

  def initialize(routes:, sqlite_options: DEFAULT_SQLITE_OPTIONS, db_connector: nil)
    @routes = routes
    @sqlite_options = sqlite_options
    @db_connector = db_connector || method(:connect_sqlite)
  end

  def call
    route_stats = @routes.each_with_object({}) do |(name, route), stats|
      stats[name.to_s] = collect_route_stats(route, name.to_s)
    end

    {
      route_stats: route_stats,
      totals: {
        tiles: route_stats.values.sum { _1[:tiles_count] },
        misses: route_stats.values.sum { _1[:misses_count] },
        cache_size: route_stats.values.sum { _1[:cache_size] }
      }
    }
  end

  def collect_route_stats(route, source_name)
    db_path = resolve_mbtiles_path(route[:mbtiles_file])
    raise ArgumentError, "MBTiles path is not configured for #{source_name}" if db_path.nil? || db_path.empty?

    @db_connector.call(db_path, **@sqlite_options) do |db|
      collect_source_stats(route:, source_name:, db:)
    end
  end

  def collect_source_stats(route:, source_name:, db:)
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

    autoscan_statuses = if db.table_exists?(:tile_scan_progress)
                          db[:tile_scan_progress]
                            .where(source: source_name)
                            .to_hash(:zoom_level, :status)
                        else
                          {}
                        end

    errors_by_zoom = if db.table_exists?(:misses)
                       db[:misses]
                         .select(:zoom_level, Sequel.function(:count, :zoom_level).as(:count))
                         .where(zoom_level: min_zoom..max_zoom)
                         .group(:zoom_level)
                         .to_hash(:zoom_level, :count)
                     else
                       {}
                     end

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
      misses_count: db.table_exists?(:misses) ? db[:misses].count : 0,
      cache_size: get_tiles_size(route),
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
  DEFAULT_TIMEOUT = 60
  DEFAULT_KILL_GRACE_PERIOD = 5
  POLL_INTERVAL = 0.1

  Handle = Struct.new(:pid, :reader, :stderr_reader, :started_at, keyword_init: true)
  Result = Struct.new(:status, :result, :error, keyword_init: true)

  def initialize(timeout: DEFAULT_TIMEOUT, kill_grace_period: DEFAULT_KILL_GRACE_PERIOD)
    @timeout = timeout
    @kill_grace_period = kill_grace_period
  end

  def start(&)
    reader, writer = IO.pipe
    stderr_reader, stderr_writer = IO.pipe
    started_at = Time.now.utc

    pid = Process.spawn(
      stats_child_env,
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

  def wait(handle)
    deadline = monotonic_time + @timeout

    loop do
      waited_pid, process_status = Process.waitpid2(handle.pid, Process::WNOHANG)
      if waited_pid
        payload = load_payload(handle.reader)
        stderr_output = handle.stderr_reader.read.to_s
        return payload_to_result(payload, process_status, stderr_output)
      end

      if monotonic_time >= deadline
        terminate(handle.pid)
        wait_for_exit(handle.pid)
        load_payload(handle.reader)
        return Result.new(status: 'timed_out', error: "Stats job timed out after #{@timeout}s")
      end

      sleep POLL_INTERVAL
    end
  rescue => e
    Result.new(status: 'failed', error: "Stats job runner failed: #{e.message}")
  ensure
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

  def load_payload(reader)
    Marshal.load(reader)
  rescue EOFError
    nil
  rescue TypeError, ArgumentError => e
    { ok: false, error: { class: e.class.name, message: "Stats job payload is invalid: #{e.message}" } }
  end

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

  def stats_child_env
    {
      'BUNDLE_GEMFILE' => ENV['BUNDLE_GEMFILE'] || File.expand_path('Gemfile', __dir__),
      'RACK_ENV' => ENV['RACK_ENV'].to_s,
      'STATS_JOB_CHILD' => '1',
      'STATS_CONFIG_FOLDER' => stats_config_folder
    }
  end

  def stats_config_folder = ENV['RACK_ENV'] == 'production' ? '/configs' : File.expand_path('configs', __dir__)

  def process_status_detail(process_status)
    return unless process_status
    return "signal=#{process_status.termsig}" if process_status.signaled?

    "exitstatus=#{process_status.exitstatus}"
  end

  def close_ios(*ios)
    ios.each { _1&.close unless _1&.closed? }
  end
end

class StatsJobManager
  def initialize(runner: StatsForkRunner.new, job_factory:, logger: LOGGER)
    @runner = runner
    @job_factory = job_factory
    @logger = logger
    @mutex = Mutex.new
    @current_job = nil
  end

  def start
    otl_span('stats.job.start', {}) do
      cancel_active_job

      job_id = SecureRandom.uuid
      handle = @runner.start { @job_factory.call }
      job = {
        job_id: job_id,
        status: 'running',
        started_at: handle.started_at.iso8601,
        finished_at: nil,
        result: nil,
        error: nil,
        pid: handle.pid
      }

      @mutex.synchronize { @current_job = job }
      log('started', job_id:, pid: handle.pid)

      Thread.new do
        Thread.current.report_on_exception = false
        finalize_job(job_id, handle)
      end

      snapshot(job)
    end
  end

  def fetch(job_id)
    @mutex.synchronize do
      return nil unless @current_job && @current_job[:job_id] == job_id

      snapshot(@current_job)
    end
  end

  def shutdown
    cancel_active_job
  end

  private

  def finalize_job(job_id, handle)
    result = @runner.wait(handle)
    finished_at = Time.now.utc.iso8601

    @mutex.synchronize do
      return unless @current_job && @current_job[:job_id] == job_id

      @current_job[:status] = result.status
      @current_job[:result] = result.result
      @current_job[:error] = result.error
      @current_job[:finished_at] = finished_at
      @current_job[:pid] = nil
    end

    if result.status != 'completed'
      @logger.warn("event=stats_job_failed job_id=#{job_id} pid=#{handle.pid} status=#{result.status} error=#{result.error}")
    end

    log(result.status, job_id:, pid: handle.pid, started_at: handle.started_at, finished_at: Time.now.utc)
  end

  def cancel_active_job
    job = @mutex.synchronize do
      next nil unless @current_job&.dig(:status) == 'running'

      job = @current_job.dup
      @current_job = nil
      job
    end

    return unless job

    @runner.terminate(job[:pid])
    started_at = Time.iso8601(job[:started_at]) rescue nil
    log('cancelled', job_id: job[:job_id], pid: job[:pid], started_at:, finished_at: Time.now.utc)
  end

  def log(status, job_id:, pid:, started_at: nil, finished_at: nil)
    duration = started_at && finished_at ? " duration=#{(finished_at - started_at).round(3)}s" : ''
    @logger.info("stats job_id=#{job_id} pid=#{pid} status=#{status}#{duration}")
  rescue StandardError
    nil
  end

  def snapshot(job) = job.dup
end

StatsJobEntry.call if ENV['STATS_JOB_CHILD'] == '1' && $PROGRAM_NAME == __FILE__
