# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'time'
require_relative 'stats_jobs'

class StatsSnapshotStore
  attr_reader :path

  def initialize(routes:, path:)
    @names = routes.keys.map(&:to_s)
    @signatures = routes.to_h do |name, route|
      relevant = [route[:mbtiles_file], route[:minzoom], route[:maxzoom], route.dig(:metadata, :bounds)]
      [name.to_s, Digest::SHA256.hexdigest(JSON.generate(relevant))]
    end
    @path = path
  end

  def read
    with_lock(File::LOCK_SH) { load_state }
  end

  def update
    with_lock(File::LOCK_EX) do
      state = load_state
      if yield(state) != false
        temporary = "#{@path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        File.write(temporary, JSON.generate(state))
        File.rename(temporary, @path)
      end
      state
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end
  end

  private

  def with_lock(mode)
    FileUtils.mkdir_p(File.dirname(@path))
    File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(mode)
      yield
    end
  end

  def load_state
    state = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    state['sources'] ||= {}
    @names.each do |name|
      entry = state['sources'][name]
      next if entry && entry['signature'] == @signatures[name]

      state['sources'][name] = {
        'signature' => @signatures[name],
        'status' => entry ? 'queued' : 'never_synced',
        'requested_at' => entry ? Time.now.utc.iso8601(6) : nil,
        'data' => nil,
        'updated_at' => nil
      }
    end
    state['sources'].select! { |name, _| @names.include?(name) }
    state
  end
end

class StatsRefreshManager
  REFRESH_INTERVAL = 3600
  IDLE_POLL_INTERVAL = 2

  def initialize(routes:, store:, runner: StatsForkRunner.new(timeout: 300), logger: LOGGER)
    @names = routes.keys.map(&:to_s)
    @store = store
    @runner = runner
    @logger = logger
    @mutex = Mutex.new
    @thread = nil
    @stopping = false
    @handle = nil
  end

  def start
    @mutex.synchronize do
      @thread = Thread.new { work_loop } unless @thread&.alive?
    end
  end

  def shutdown
    @mutex.synchronize do
      @stopping = true
      @runner.terminate(@handle.pid) if @handle
    end
    @thread&.join(1)
  end

  def snapshot
    state = @store.read
    sources = state.fetch('sources')
    available = sources.values.filter_map { _1['data'] }
    totals = {
      tiles: available.sum { _1.fetch('tiles_count') },
      misses: available.sum { _1.fetch('misses_count') },
      cache_size: available.sum { _1.fetch('cache_size') }
    }
    updated = sources.values.map { _1['updated_at'] }

    {
      sources: sources,
      route_stats: sources.transform_values { _1['data'] }.compact,
      totals: totals,
      complete: available.length == @names.length,
      last_synced_at: updated.all? ? updated.min : nil,
      last_scheduled_at: state['last_scheduled_at']
    }
  end

  def refresh(source = nil)
    raise ArgumentError, "Unknown stats source: #{source}" if source && !@names.include?(source)

    now = Time.now.utc.iso8601(6)
    targets = source ? [source] : @names
    @store.update do |state|
      targets.each do |name|
        entry = state.fetch('sources').fetch(name)
        entry['requested_at'] = now
        entry['status'] = 'queued' unless entry['status'] == 'running'
        entry['priority'] = 1 if source
      end
    end
    start
    snapshot
  end

  private

  def work_loop
    FileUtils.mkdir_p(File.dirname(@store.path))
    loop do
      break if @stopping

      File.open("#{@store.path}.worker.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        if lock.flock(File::LOCK_EX | File::LOCK_NB)
          schedule_if_due
          run_queued_sources
        end
      end
      sleep IDLE_POLL_INTERVAL
    end
  rescue => e
    @logger.error("event=stats_refresh_worker_failed error=#{e.class}: #{e.message}")
    sleep IDLE_POLL_INTERVAL
    retry unless @stopping
  end

  def schedule_if_due
    now = Time.now.utc
    @store.update do |state|
      previous = state['last_scheduled_at'] && Time.iso8601(state['last_scheduled_at'])
      next false if previous && now - previous < REFRESH_INTERVAL

      state['last_scheduled_at'] = now.iso8601(6)
      @names.each do |name|
        entry = state.fetch('sources').fetch(name)
        next if entry['requested_at'] || entry['status'] == 'running'

        entry['requested_at'] = now.iso8601(6)
        entry['status'] = 'queued'
        entry['priority'] ||= 0
      end
    end
  end

  def run_queued_sources
    while !@stopping && (name = take_next_source)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run_source(name)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
      finish_source(name, result)
      @logger.info("event=stats_source_finished source=#{name} status=#{result.status} duration=#{duration}s")
    end
  end

  def take_next_source
    selected = nil
    @store.update do |state|
      name = @names.each_with_index.filter_map do |candidate, index|
        entry = state.fetch('sources').fetch(candidate)
        [entry['priority'].to_i, -index, candidate] if entry['requested_at'] || entry['status'] == 'running'
      end.max&.last
      next false unless name

      entry = state.fetch('sources').fetch(name)
      entry['requested_at'] = nil
      entry['priority'] = 0
      entry['status'] = 'running'
      entry['started_at'] = Time.now.utc.iso8601(6)
      entry['error'] = nil
      entry['progress'] = nil
      selected = name
    end
    selected
  end

  def run_source(name)
    handle = @runner.start(source: name)
    @mutex.synchronize { @handle = handle }
    @runner.wait(handle) { |progress| publish_progress(name, progress) }
  rescue => e
    StatsForkRunner::Result.new(status: 'failed', error: e.message)
  ensure
    @mutex.synchronize { @handle = nil }
  end

  def publish_progress(name, progress)
    @store.update do |state|
      entry = state.fetch('sources').fetch(name)
      entry['progress'] ||= {}
      entry['progress'].merge!(progress.transform_keys(&:to_s))
    end
  end

  def finish_source(name, result)
    @store.update do |state|
      entry = state.fetch('sources').fetch(name)
      if result.status == 'completed'
        entry['data'] = result.result
        entry['updated_at'] = Time.now.utc.iso8601(6)
        entry['error'] = nil
      else
        entry['error'] = result.error
      end
      entry['status'] = entry['requested_at'] ? 'queued' : result.status
      entry['finished_at'] = Time.now.utc.iso8601(6)
      entry['started_at'] = nil
      entry['progress'] = nil
    end
  end
end
