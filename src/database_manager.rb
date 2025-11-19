require 'sequel'
require_relative 'metadata_manager'

module DatabaseManager
  extend self

  def setup_route_database(route, route_name)
    db_path = "sqlite://" + route[:mbtiles_file]
    db = Sequel.connect(db_path, max_connections: 8)

    configure_sqlite_pragmas(db)
    create_tables(db)
    route[:db] = db
    
    integrate_wal_files(db, route_name)
    
    MetadataManager.initialize_metadata(db, route, route_name)
    
    route[:content_type] = "image/#{db[:metadata].where(name: 'format').get(:value) || 'png'}"
    route[:tile_size] = db[:metadata].where(name: 'tileSize').get(:value).to_i

    route[:locks] = Hash.new { |h,k| h[k] = Mutex.new }

    cleanup_misses_if_needed(route)

    db
  end

  def vacuum_all_databases(routes) = routes.each { |name, route| vacuum_database(route[:db], name) }

  def vacuum_database(db, name = nil)
    name_str = name ? " for #{name}" : ""
    LOGGER.info("Starting VACUUM operation#{name_str}...")
    start_time = Time.now
    db.run "VACUUM"
    duration = Time.now - start_time
    LOGGER.info("VACUUM completed#{name_str} in #{duration.round(2)}s")
  rescue => e
    LOGGER.error("VACUUM failed#{name_str}: #{e.message}")
  end

  def integrate_wal_files(db, name = nil)
    name_str = name ? " for #{name}" : ""
    LOGGER.info("Integrating WAL files#{name_str} on startup...")
    
    begin
      db.run "PRAGMA wal_checkpoint(RESTART)"
      db.run "PRAGMA wal_checkpoint(TRUNCATE)"
      LOGGER.info("WAL integration completed#{name_str}")
    rescue => e
      LOGGER.error("Failed to integrate WAL#{name_str}: #{e.message}")
    end
  end

  def record_miss(route, z, x, y, reason, details, status, body)
    route[:db][:misses].where(z: z, x: x, y: y).delete

    route[:db][:misses].insert(
      z: z, x: x, y: y, ts: Time.now.to_i,
      reason: reason, details: details, status: status,
      response_body: Sequel.blob(body || '')
    )

    cleanup_misses_if_needed(route)
  end

  def cleanup_misses_if_needed(route)
    max_records = route[:miss_max_records] || 10000
    return unless route[:db][:misses].count > max_records

    keep_count = (max_records * 0.8).to_i
    cutoff_ts = route[:db][:misses].reverse(:ts).limit(keep_count).min(:ts)
    route[:db][:misses].where { ts < cutoff_ts }.delete if cutoff_ts
  end

  private

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
    db.create_table?(:metadata){ String :name, null:false; String :value; index :name }
    db.create_table?(:tiles){
      Integer :zoom_level,  null:false
      Integer :tile_column, null:false
      Integer :tile_row,    null:false
      File    :tile_data,   null:false
      unique [:zoom_level,:tile_column,:tile_row], name: :tile_index
      index :zoom_level, name: :idx_tiles_zoom_level
      index [:zoom_level, Sequel.function(:length, :tile_data)], name: :idx_tiles_zoom_size
    }
    db.create_table?(:misses){ 
      Integer :z; Integer :x; Integer :y; Integer :ts
      String :reason; String :details; Integer :status; File :response_body
      index [:z, :x, :y], name: :idx_misses_xyz
      index :ts, name: :idx_misses_ts
    }
  end
end
