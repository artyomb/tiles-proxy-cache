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
    
    MetadataManager.initialize_metadata(db, route, route_name)
    
    route[:content_type] = "image/#{db[:metadata].where(name: 'format').get(:value) || 'png'}"
    route[:tile_size] = db[:metadata].where(name: 'tileSize').get(:value).to_i

    route[:locks] = Hash.new { |h,k| h[k] = Mutex.new }

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
    }
    db.create_table?(:misses){ Integer :z; Integer :x; Integer :y; Integer :ts; String :reason; String :details; Integer :status; File :response_body }
  end
end
