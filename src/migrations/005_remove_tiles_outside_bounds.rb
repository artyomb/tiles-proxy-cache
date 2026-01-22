Sequel.migration do
  up do
    next unless table_exists?(:tiles) && table_exists?(:metadata)

    require_relative '../geometry_tile_calculator'

    bounds_str = self[:metadata].where(name: 'bounds').get(:value)
    return unless bounds_str

    zoom_levels = self[:tiles].select(:zoom_level).distinct.map { |r| r[:zoom_level] }.sort

    zoom_levels.each do |z|
      tile_boundaries = GeometryTileCalculator.tiles_for_bounds_string(bounds_str, z)

      west_bounds = tile_boundaries[:west]&.dig(z)
      east_bounds = tile_boundaries[:east]&.dig(z)

      max_tms_y = (1 << z) - 1
      tms_y = ->(xyz_y) { max_tms_y - xyz_y }

      if west_bounds && east_bounds
        west_min_y_tms = tms_y.call(west_bounds[:max_y])
        west_max_y_tms = tms_y.call(west_bounds[:min_y])
        east_min_y_tms = tms_y.call(east_bounds[:max_y])
        east_max_y_tms = tms_y.call(east_bounds[:min_y])

        self[:tiles].where(zoom_level: z).where(
          Sequel.lit('NOT ((tile_column >= ? AND tile_column <= ? AND tile_row >= ? AND tile_row <= ?) OR ' \
                     '(tile_column >= ? AND tile_column <= ? AND tile_row >= ? AND tile_row <= ?))',
                     west_bounds[:min_x], west_bounds[:max_x], west_min_y_tms, west_max_y_tms,
                     east_bounds[:min_x], east_bounds[:max_x], east_min_y_tms, east_max_y_tms)
        ).delete
      elsif west_bounds
        min_y_tms = tms_y.call(west_bounds[:max_y])
        max_y_tms = tms_y.call(west_bounds[:min_y])

        self[:tiles].where(zoom_level: z).where(
          Sequel.lit('(tile_column < ? OR tile_column > ? OR tile_row < ? OR tile_row > ?)',
                     west_bounds[:min_x], west_bounds[:max_x], min_y_tms, max_y_tms)
        ).delete
      end
    end
  end

  down do
    raise Sequel::Error, 'Irreversible migration: cannot restore deleted tiles'
  end
end
