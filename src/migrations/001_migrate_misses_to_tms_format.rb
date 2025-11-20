Sequel.migration do
  up do
    if table_exists?(:misses)
      columns = self[:misses].columns
      
      if columns.include?(:z) && !columns.include?(:zoom_level)
        create_table(:misses_new) do
          Integer :zoom_level, null: false
          Integer :tile_column, null: false
          Integer :tile_row, null: false
          Integer :ts, null: false
          String :reason
          String :details
          Integer :status
          File :response_body
          
          primary_key [:zoom_level, :tile_column, :tile_row], name: :misses_pk
          index [:zoom_level, :status], name: :idx_misses_new_zoom_status
          index :ts, name: :idx_misses_new_ts
        end
        
        self[:misses_new].insert(
          self[:misses].select(
            Sequel.as(:z, :zoom_level),
            Sequel.as(:x, :tile_column),
            Sequel.as(Sequel.lit('(1 << z) - 1 - y'), :tile_row),
            :ts,
            :reason,
            :details,
            :status,
            :response_body
          )
        )
        
        drop_table(:misses)
        rename_table(:misses_new, :misses)

        existing_indexes = indexes(:misses).keys
        alter_table(:misses) do
          drop_index :zoom_level, name: :idx_misses_new_zoom_status if existing_indexes.include?(:idx_misses_new_zoom_status)
          drop_index :ts, name: :idx_misses_new_ts if existing_indexes.include?(:idx_misses_new_ts)
        end
        
        add_index(:misses, [:zoom_level, :status], name: :idx_misses_zoom_status)
        add_index(:misses, :ts, name: :idx_misses_ts)
      end
    end
  end
  
  down do
    if table_exists?(:misses)
      columns = self[:misses].columns
      
      if columns.include?(:zoom_level) && !columns.include?(:z)
        create_table(:misses_old) do
          Integer :z
          Integer :x
          Integer :y
          Integer :ts
          String :reason
          String :details
          Integer :status
          File :response_body
          
          index [:z, :x, :y], name: :idx_misses_xyz
          index :ts, name: :idx_misses_ts
        end
        
        self[:misses_old].insert(
          self[:misses].select(
            Sequel.as(:zoom_level, :z),
            Sequel.as(:tile_column, :x),
            Sequel.as(Sequel.lit('(1 << zoom_level) - 1 - tile_row'), :y),
            :ts,
            :reason,
            :details,
            :status,
            :response_body
          )
        )
        
        drop_table(:misses)
        rename_table(:misses_old, :misses)
      end
    end
  end
end

