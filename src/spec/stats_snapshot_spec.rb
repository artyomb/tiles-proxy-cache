# frozen_string_literal: true

require 'tmpdir'
require 'logger'
require 'sequel'
require 'yaml'
require_relative '../stats_snapshot'

RSpec.describe 'Statistics snapshots' do
  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'Timed out waiting for statistics' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  it 'counts every miss once and keeps per-zoom coverage within the configured range' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'tiles.mbtiles')
      db = Sequel.sqlite(path)
      db.create_table(:tiles) do
        Integer :zoom_level
        Integer :generated
      end
      db.create_table(:misses) { Integer :zoom_level }
      db[:tiles].multi_insert([{ zoom_level: 1, generated: 0 }, { zoom_level: 1, generated: 2 }, { zoom_level: 1, generated: -5 }])
      db[:misses].multi_insert([{ zoom_level: 1 }, { zoom_level: 1 }, { zoom_level: 8 }])
      db.disconnect

      route = { mbtiles_file: path, minzoom: 1, maxzoom: 2 }
      result = StatsAggregator.new.collect_route_stats(route, 'Demo')

      expect(result[:tiles_count]).to eq(2)
      expect(result[:misses_count]).to eq(3)
      expect(result[:coverage_data].first).to include(cached: 1, generated: 1, errors: 2)
      expect(result[:coverage_data].last[:errors]).to eq(0)
    end
  end

  it 'runs the selected source in a child process using an isolated config' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'tiles.mbtiles')
      db = Sequel.sqlite(path)
      db.create_table(:tiles) do
        Integer :zoom_level
        Integer :generated
      end
      db[:tiles].insert(zoom_level: 1, generated: 0)
      db.disconnect
      File.write(File.join(dir, 'routes.yaml'), { Demo: { mbtiles_file: path, minzoom: 1, maxzoom: 1 } }.to_yaml)

      previous = ENV['STATS_CONFIG_FOLDER']
      ENV['STATS_CONFIG_FOLDER'] = dir
      runner = StatsForkRunner.new(timeout: 5)
      progress = []
      result = runner.wait(runner.start(source: 'Demo')) { |update| progress << update }

      expect(result.status).to eq('completed')
      expect(result.result[:tiles_count]).to eq(1)
      expect(progress.map(&:keys)).to eq([[:cache_size], [:tiles_count], [:misses_count]])
    ensure
      ENV['STATS_CONFIG_FOLDER'] = previous
    end
  end

  it 'publishes each finished source while another is still running and survives a new manager instance' do
    Dir.mktmpdir do |dir|
      routes = { First: {}, Second: {} }
      store = StatsSnapshotStore.new(routes:, path: File.join(dir, 'stats.json'))
      store.update { _1['last_scheduled_at'] = Time.now.utc.iso8601 }
      gate = Queue.new
      runner = Object.new
      runner.define_singleton_method(:start) { |source:| Struct.new(:source).new(source) }
      runner.define_singleton_method(:wait) do |handle, &on_progress|
        if handle.source == 'Second'
          on_progress.call(tiles_count: 1)
          gate.pop
        end
        StatsForkRunner::Result.new(status: 'completed', result: { tiles_count: 1, misses_count: 2, cache_size: 3 })
      end
      runner.define_singleton_method(:terminate) { |_| nil }
      manager = StatsRefreshManager.new(routes:, store:, runner:, logger: Logger.new(File::NULL))

      manager.refresh
      wait_until { manager.snapshot[:sources]['First']['status'] == 'completed' && manager.snapshot[:sources]['Second']['status'] == 'running' }
      expect(manager.snapshot[:totals]).to eq(tiles: 1, misses: 2, cache_size: 3)
      expect(manager.snapshot[:sources]['Second']['progress']).to eq('tiles_count' => 1)
      gate << true
      wait_until { manager.snapshot[:complete] }
      expect(StatsRefreshManager.new(routes:, store:, runner:, logger: Logger.new(File::NULL)).snapshot[:totals]).to eq(tiles: 2, misses: 4, cache_size: 6)
      manager.shutdown
    end
  end

  it 'starts an hourly sweep without a page request and retains the last good value after a failed refresh' do
    Dir.mktmpdir do |dir|
      routes = { First: {} }
      store = StatsSnapshotStore.new(routes:, path: File.join(dir, 'stats.json'))
      status = Queue.new
      status << 'completed'
      status << 'timed_out'
      runner = Object.new
      runner.define_singleton_method(:start) { |source:| Struct.new(:source).new(source) }
      runner.define_singleton_method(:wait) do |_handle|
        outcome = status.pop
        StatsForkRunner::Result.new(status: outcome, result: { tiles_count: 7, misses_count: 8, cache_size: 9 }, error: 'Too slow')
      end
      runner.define_singleton_method(:terminate) { |_| nil }
      manager = StatsRefreshManager.new(routes:, store:, runner:, logger: Logger.new(File::NULL))

      expect(manager.snapshot[:sources]['First']['status']).to eq('never_synced')
      manager.start
      wait_until { manager.snapshot[:complete] }
      previous = manager.snapshot[:sources]['First']['updated_at']
      manager.refresh('First')
      wait_until { manager.snapshot[:sources]['First']['status'] == 'timed_out' }
      entry = manager.snapshot[:sources]['First']
      expect(entry['data']['tiles_count']).to eq(7)
      expect(entry['updated_at']).to eq(previous)
      manager.shutdown
    end
  end

  it 'invalidates a saved value when the source database configuration changes' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'stats.json')
      old_store = StatsSnapshotStore.new(routes: { Demo: { mbtiles_file: 'old.mbtiles' } }, path:)
      old_store.update do |state|
        state['sources']['Demo']['data'] = { 'tiles_count' => 10 }
        state['sources']['Demo']['updated_at'] = Time.now.utc.iso8601
      end

      new_store = StatsSnapshotStore.new(routes: { Demo: { mbtiles_file: 'new.mbtiles' } }, path:)
      expect(new_store.read['sources']['Demo']).to include('status' => 'queued', 'data' => nil)
    end
  end

  it 'runs a manually requested card before the remaining hourly queue' do
    Dir.mktmpdir do |dir|
      routes = { First: {}, Middle: {}, Last: {} }
      store = StatsSnapshotStore.new(routes:, path: File.join(dir, 'stats.json'))
      store.update { _1['last_scheduled_at'] = Time.now.utc.iso8601 }
      gate = Queue.new
      order = []
      runner = Object.new
      runner.define_singleton_method(:start) { |source:| Struct.new(:source).new(source) }
      runner.define_singleton_method(:wait) do |handle|
        order << handle.source
        gate.pop if handle.source == 'First'
        StatsForkRunner::Result.new(status: 'completed', result: { tiles_count: 1, misses_count: 0, cache_size: 0 })
      end
      runner.define_singleton_method(:terminate) { |_| nil }
      manager = StatsRefreshManager.new(routes:, store:, runner:, logger: Logger.new(File::NULL))

      manager.refresh
      wait_until { manager.snapshot[:sources]['First']['status'] == 'running' }
      manager.refresh('Last')
      gate << true
      wait_until { manager.snapshot[:complete] }
      expect(order).to eq(%w[First Last Middle])
      manager.shutdown
    end
  end
end
