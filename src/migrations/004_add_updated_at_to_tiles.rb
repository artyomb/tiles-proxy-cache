Sequel.migration do
  up do
    next unless table_exists?(:tiles)

    columns = schema(:tiles).map(&:first)
    unless columns.include?(:updated_at)
      alter_table(:tiles) do
        add_column :updated_at, DateTime
      end
    end

    run "UPDATE tiles SET updated_at = datetime('now', 'utc') WHERE updated_at IS NULL"

    begin
      add_index :tiles, [:zoom_level, :updated_at], name: :idx_tiles_zoom_updated
    rescue Sequel::DatabaseError => e
      raise unless e.message.include?('already exists')
    end
  end

  down do
    next unless table_exists?(:tiles)

    raise Sequel::Error, 'Irreversible migration: dropping updated_at column would require table recreation'
  end
end

