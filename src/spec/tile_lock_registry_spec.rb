# frozen_string_literal: true

require 'timeout'
require_relative '../tile_lock_registry'

RSpec.describe TileLockRegistry do
  subject(:registry) { described_class.new }

  it 'releases entries after successful execution' do
    result = registry.synchronize('1/2/3') { :result }

    expect(result).to eq(:result)
    expect(registry.size).to eq(0)
  end

  it 'releases entries after an exception' do
    expect do
      registry.synchronize('1/2/3') { raise 'failure' }
    end.to raise_error('failure')

    expect(registry.size).to eq(0)
  end

  it 'releases entries after a non-local return' do
    result = synchronize_with_early_return(registry)

    expect(result).to eq(:result)
    expect(registry.size).to eq(0)
  end

  it 'does not retain completed unique keys' do
    10_000.times { |index| registry.synchronize("14/#{index}/#{index}") {} }

    expect(registry.size).to eq(0)
  end

  it 'serializes all users of the same key' do
    active = 0
    max_active = 0
    counter_guard = Mutex.new

    threads = 20.times.map do
      Thread.new do
        registry.synchronize('1/2/3') do
          counter_guard.synchronize do
            active += 1
            max_active = [max_active, active].max
          end

          sleep 0.001
          counter_guard.synchronize { active -= 1 }
        end
      end
    end

    threads.each(&:join)

    expect(max_active).to eq(1)
    expect(registry.size).to eq(0)
  end

  it 'deduplicates guarded work after a cache recheck' do
    cached = false
    upstream_fetches = 0

    threads = 20.times.map do
      Thread.new do
        registry.synchronize('1/2/3') do
          next if cached

          sleep 0.001
          upstream_fetches += 1
          cached = true
        end
      end
    end

    threads.each(&:join)

    expect(upstream_fetches).to eq(1)
    expect(registry.size).to eq(0)
  end

  it 'does not create a second entry while another user is waiting' do
    owner_entered = Queue.new
    release_owner = Queue.new
    waiter_entered = Queue.new
    release_waiter = Queue.new
    newcomer_entered = Queue.new

    owner = Thread.new do
      registry.synchronize('1/2/3') do
        owner_entered << true
        release_owner.pop
      end
    end
    Timeout.timeout(1) { owner_entered.pop }

    waiter = Thread.new do
      registry.synchronize('1/2/3') do
        waiter_entered << true
        release_waiter.pop
      end
    end
    Timeout.timeout(1) { Thread.pass until waiter.status == 'sleep' }

    release_owner << true
    Timeout.timeout(1) { waiter_entered.pop }
    owner.join

    expect(registry.size).to eq(1)

    newcomer = Thread.new do
      registry.synchronize('1/2/3') { newcomer_entered << true }
    end
    Timeout.timeout(1) { Thread.pass until newcomer.status == 'sleep' || !newcomer.alive? }

    expect(newcomer).to be_alive
    expect(newcomer_entered).to be_empty

    release_waiter << true
    waiter.join
    Timeout.timeout(1) { newcomer_entered.pop }
    newcomer.join

    expect(registry.size).to eq(0)
  ensure
    release_owner << true if owner&.alive?
    release_waiter << true if waiter&.alive?
    owner&.join
    waiter&.join
    newcomer&.join
  end

  it 'allows different keys to execute concurrently' do
    first_entered = Queue.new
    release_first = Queue.new
    second_entered = Queue.new

    first = Thread.new do
      registry.synchronize('1/2/3') do
        first_entered << true
        release_first.pop
      end
    end
    Timeout.timeout(1) { first_entered.pop }

    second = Thread.new do
      registry.synchronize('1/2/4') { second_entered << true }
    end

    Timeout.timeout(1) { second_entered.pop }
    expect(registry.size).to eq(1)
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end

  def synchronize_with_early_return(registry)
    registry.synchronize('1/2/3') { return :result }
  end
end
