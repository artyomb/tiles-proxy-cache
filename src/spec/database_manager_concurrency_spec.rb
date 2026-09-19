# frozen_string_literal: true

require 'async'
require 'sequel'
require 'timeout'
require_relative '../database_manager'

RSpec.describe 'SQLite connection pool concurrency' do
  it 'uses Sequel fiber identity with its thread-safe pool' do
    db = Sequel.connect('sqlite::memory:', max_connections: 1)

    expect(Sequel.current).to equal(Fiber.current)
    expect(db.pool.pool_type).to eq(:timed_queue)
  ensure
    db&.disconnect
  end

  it 'hands a connection from a native thread back to a waiting async fiber' do
    db = Sequel.connect('sqlite::memory:', max_connections: 1)
    connection_held = Queue.new
    release_connection = Queue.new
    background_error = Queue.new
    ticks = 0

    background = Thread.new do
      db.synchronize do
        connection_held << true
        release_connection.pop
      end
    rescue => e
      background_error << e
    end
    Timeout.timeout(1) { connection_held.pop }

    result = Timeout.timeout(2) do
      Async do |task|
        query = task.async { db.get(Sequel.lit('1')) }
        ticker = task.async do
          until query.finished?
            ticks += 1
            task.sleep 0.01
          end
        end

        Timeout.timeout(1) { Thread.pass until db.pool.num_waiting.positive? }
        release_connection << true
        query.wait.tap { ticker.wait }
      end.wait
    end

    expect(result).to eq(1)
    expect(ticks).to be_positive
    expect(background_error).to be_empty
  ensure
    release_connection << true if background&.alive?
    background&.join(1)
    db&.disconnect
  end
end
