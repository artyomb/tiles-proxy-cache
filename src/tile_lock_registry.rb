# frozen_string_literal: true

class TileLockRegistry
  Entry = Struct.new(:mutex, :references)
  private_constant :Entry

  def initialize
    @guard = Mutex.new
    @entries = {}
  end

  def synchronize(key)
    entry = acquire(key)
    entry.mutex.synchronize { yield }
  ensure
    release(key, entry) if entry
  end

  def size = @guard.synchronize { @entries.size }

  private

  def acquire(key)
    @guard.synchronize do
      entry = (@entries[key] ||= Entry.new(Mutex.new, 0))
      entry.references += 1
      entry
    end
  end

  def release(key, entry)
    @guard.synchronize do
      entry.references -= 1
      @entries.delete(key) if entry.references.zero? && @entries[key].equal?(entry)
    end
  end
end
