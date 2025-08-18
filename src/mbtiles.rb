require "sequel"

DB = Sequel.connect("sqlite:///path/to/map.mbtiles?mode=ro") # read-only
DB.run "PRAGMA journal_mode=WAL"      # harmless if already WAL
DB.run "PRAGMA synchronous=NORMAL"
DB.run "PRAGMA locking_mode=NORMAL"
DB.run "PRAGMA foreign_keys=ON"
DB.run "PRAGMA busy_timeout=10000"
DB.run "PRAGMA temp_store=MEMORY"
DB.run "PRAGMA cache_size=-262144"    # ~256 MiB page cache (tune)
DB.run "PRAGMA mmap_size=1073741824"  # 1 GiB mmap if supported

# Example query
tiles = DB[:tiles].where(zoom_level: 10, tile_column: 511, tile_row: 340)
blob = tiles.get(:tile_data)

db_path = "path/to/map.mbtiles"
new_file = !File.exist?(db_path)

DB = Sequel.sqlite(db_path)

# If creating a brand-new file, set page_size once, then VACUUM to apply.
if new_file
  DB.run "PRAGMA page_size=4096"      # or 8192/16384; set once
  DB.run "VACUUM"
end

# WAL + performance
DB.run "PRAGMA journal_mode=WAL"
DB.run "PRAGMA synchronous=NORMAL"
DB.run "PRAGMA locking_mode=NORMAL"
DB.run "PRAGMA foreign_keys=ON"
DB.run "PRAGMA busy_timeout=10000"
DB.run "PRAGMA temp_store=MEMORY"
DB.run "PRAGMA cache_size=-262144"
DB.run "PRAGMA mmap_size=1073741824"

# Optionally disable auto-checkpoint and do it yourself
DB.run "PRAGMA wal_autocheckpoint=0"

tiles = DB[:tiles]

# Example: bulk insert XYZ folder -> MBTiles (flip Y to TMS)
def tms_y(z, y) (1 << z) - 1 - y end

DB.create_table?(:metadata) do
  String :name,  null: false
  String :value
  index :name
end

DB.create_table?(:tiles) do
  Integer :zoom_level,  null: false
  Integer :tile_column, null: false
  Integer :tile_row,    null: false # TMS Y
  File    :tile_data,   null: false # stored as BLOB

  unique [:zoom_level, :tile_column, :tile_row]
end

# --- Metadata ---
meta = {
  version: "1",
  type: "baselayer",
  format: format,
  name: name,
  description: name
}
DB[:metadata].multi_insert(meta.map { |k,v| {name: k, value: v} })

# --- Helper: XYZ → TMS ---
def xyz_to_tms_y(z, y)
  (1 << z) - 1 - y
end

# --- Insert tiles ---
DB.transaction do
  Dir.glob(File.join(xyz_dir, "*", "*", "*.{png,jpg,jpeg,webp}"), File::FNM_CASEFOLD).each do |path|
    z = File.basename(File.dirname(File.dirname(path))).to_i
    x = File.basename(File.dirname(path)).to_i
    y = File.basename(path, ".*").to_i
    tms_y = xyz_to_tms_y(z, y)
    blob = File.binread(path)

    tiles.insert(
      zoom_level:  z,
      tile_column: x,
      tile_row:    tms_y,
      tile_data:   Sequel.blob(blob)
    )
  end
end

# --- minzoom/maxzoom ---
z_levels = DB[:tiles].select(:zoom_level).distinct.map(:zoom_level)
if z_levels.any?
  DB[:metadata].insert(name: "minzoom", value: z_levels.min)
  DB[:metadata].insert(name: "maxzoom", value: z_levels.max)
end

DB.run "VACUUM"
