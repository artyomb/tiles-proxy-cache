Sequel.migration do
  up do
    next unless table_exists?(:tiles)

    columns = schema(:tiles).map(&:first)
    next if columns.include?(:generated)

    alter_table(:tiles) do
      add_column :generated, Integer, default: 0
    end

    add_index :tiles, [:zoom_level, :generated], name: :idx_tiles_zoom_generated
  end

  down do
    raise Sequel::Error, 'Irreversible migration: dropping generated column would require table recreation'
  end
end

