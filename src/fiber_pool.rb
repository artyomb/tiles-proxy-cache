# fiber_pool.rb — an extension of fiber_pool from stack-service-base to support SQLite.
#
# stack-service-base/fiber_pool.rb applies FiberConnectionPool only for Postgres:
#   @opts[:adapter] == 'postgres' ? {pool_class: FiberConnectionPool} : super
#
# This file overrides that prepend, adding SQLite support.
#
# IMPORTANT: require AFTER StackServiceBase.rack_setup, because pre_init
# inside rack_setup loads fiber_pool from the gem and installs its own prepend.
# Our repeated prepend is placed on top of it in the ancestors chain.

# SQLite patch: override disconnect in FiberConnectionPool via a refinement-like patch
# to properly close prepared statements on disconnect.
# For SQLite, conn.close does not close prepared statements — disconnect_connection is required.
FiberConnectionPool.prepend(Module.new do
  def disconnect(symbol)
    until @stock.empty?
      conn = @stock.shift
      begin
        @db.disconnect_connection(conn)
      rescue
        conn.close rescue nil
      end
    end
  end
end)

# Override the prepend from stack-service-base, adding SQLite support.
Sequel::Database.prepend(Module.new do
  def connection_pool_default_options
    %w[postgres sqlite].include?(@opts[:adapter]) ? {pool_class: FiberConnectionPool} : super
  end
end)
