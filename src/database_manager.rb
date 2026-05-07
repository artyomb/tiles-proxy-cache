require 'sequel'
Sequel.extension :migration
require_relative 'metadata_manager'
require_relative 'observability_setup'

module DatabaseManager
  extend self

  def setup_route_database(route, route_name)
    db_path = "sqlite://" + route[:mbtiles_file]
    db = Sequel.connect(db_path, max_connections: 20, **Observability.sql_logging_options)

    Observability.configure_sql_logging(db)
    configure_sqlite_pragmas(db)
    create_tables(db)
    apply_migrations(db)
    route[:db] = db
    
    integrate_wal_files(db, route_name)
    
    MetadataManager.sync_metadata(db, route, route_name)
    
    format_value = db[:metadata].where(name: 'format').get(:value)
    route[:content_type] = format_value ? "image/#{format_value}" : 'image/png'
    
    tile_size_value = db[:metadata].where(name: 'tileSize').get(:value)
    route[:tile_size] = tile_size_value ? tile_size_value.to_i : nil

    route[:locks] = Hash.new { |h,k| h[k] = Mutex.new }

    db
  end

  def vacuum_all_databases(routes) = routes.each { |name, route| vacuum_database(route[:db], name) }

  def vacuum_database(db, name = nil)
    name_str = name ? " for #{name}" : ""
    otl_span('db.vacuum', { source: name }) do
      LOGGER.info("Starting VACUUM operation#{name_str}...")
      start_time = Time.now
      db.run "VACUUM"
      duration = Time.now - start_time
      LOGGER.info("VACUUM completed#{name_str} in #{duration.round(2)}s")
    end
  rescue => e
    LOGGER.error("event=db_vacuum_failed source=#{name} error=#{e.message}")
  end

  def integrate_wal_files(db, name = nil)
    name_str = name ? " for #{name}" : ""
    otl_span('db.wal_integrate', { source: name }) do
      LOGGER.info("Integrating WAL files#{name_str} on startup...")
      db.run "PRAGMA wal_checkpoint(RESTART)"
      db.run "PRAGMA wal_checkpoint(TRUNCATE)"
      LOGGER.info("WAL integration completed#{name_str}")
    end
  rescue => e
    LOGGER.error("event=db_wal_integrate_failed source=#{name} error=#{e.message}")
  end

  def record_miss(route, z, x, y, reason, details, status, body)
    tile_row = (1 << z) - 1 - y

    route[:db][:misses].where(
      zoom_level: z,
      tile_column: x,
      tile_row: tile_row
    ).delete

    route[:db][:misses].insert(
      zoom_level: z,
      tile_column: x,
      tile_row: tile_row,
      ts: Time.now.to_i,
      reason: reason,
      details: details,
      status: status,
      response_body: Sequel.blob(body || '')
    )

    log_problem_miss(route, z, x, y, reason, status, details)
  end

  private

  def log_problem_miss(route, z, x, y, reason, status, details)
    reason = reason.to_s
    return if reason == 'permanent:http_204'
    return if %w[http_204 transparent corrupted].include?(reason)
    return if status.to_i < 500 && !reason.match?(/error|timeout|network|refused/)

    LOGGER.warn("event=tile_miss_recorded source=#{route[:observability_source]} z=#{z} x=#{x} y=#{y} status=#{status} reason=#{reason} details=#{details.to_s[0, 300]}")
  end

  def configure_sqlite_pragmas(db)
    db.run "PRAGMA page_size=4096"      # or 8192/16384; set once
    db.run "PRAGMA journal_mode=WAL"
    db.run "PRAGMA synchronous=NORMAL"
    db.run "PRAGMA locking_mode=NORMAL"
    db.run "PRAGMA busy_timeout=10000"
    db.run "PRAGMA temp_store=MEMORY"
    db.run "PRAGMA cache_size=-131072"     # ~128 MiB
    db.run "PRAGMA mmap_size=536870912"    # 512 MiB
    db.run "PRAGMA wal_autocheckpoint=1000"
  end

  def create_tables(db)
    db.create_table?(:metadata){ String :name, null:false; String :value; unique :name }
    db.create_table?(:tiles){
      Integer :zoom_level,  null:false
      Integer :tile_column, null:false
      Integer :tile_row,    null:false
      File    :tile_data,   null:false
      Integer :generated,   default: 0  # 0=original, 1=generated, 2=needs_regeneration
      DateTime :updated_at, default: Sequel.lit("datetime('now', 'utc')")
      unique [:zoom_level,:tile_column,:tile_row], name: :tile_index
      index :zoom_level, name: :idx_tiles_zoom_level
      index [:zoom_level, Sequel.function(:length, :tile_data)], name: :idx_tiles_zoom_size
      index [:zoom_level, :generated], name: :idx_tiles_zoom_generated
      index [:zoom_level, :updated_at], name: :idx_tiles_zoom_updated
    }
    db.create_table?(:misses){ 
      Integer :zoom_level, null: false
      Integer :tile_column, null: false
      Integer :tile_row, null: false
      Integer :ts, null: false
      String :reason
      String :details
      Integer :status
      File :response_body
      primary_key [:zoom_level, :tile_column, :tile_row], name: :misses_pk
      index [:zoom_level, :status], name: :idx_misses_zoom_status
      index :ts, name: :idx_misses_ts
    }
  end

  def apply_migrations(db)
    migrations_path = File.join(__dir__, 'migrations')
    return unless Dir.exist?(migrations_path) && !Dir[File.join(migrations_path, '*.rb')].empty?

    otl_span('db.migrations', {}) do
      Sequel::Migrator.run(db, migrations_path, table: :schema_info)
      LOGGER.info("Migrations applied successfully")
    end
  rescue => e
    LOGGER.error("event=db_migration_failed error=#{e.message}")
    raise
  end
end
