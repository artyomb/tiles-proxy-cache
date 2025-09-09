module ViewHelpers
  def get_tiles_size(route)
    route[:db][:tiles].sum(Sequel.function(:length, :tile_data)) || 0
  end

  def tiles_per_zoom(z, route = nil)
    return 4 ** z unless route

    bounds_str = route.dig(:metadata, :bounds) || "-180,-85.0511,180,85.0511"
    west, south, east, north = bounds_str.split(',').map(&:to_f)

    min_x = [(west + 180) / 360 * (1 << z), 0].max.floor
    min_y = [(1 - Math.log(Math.tan(north * Math::PI / 180) + 1 / Math.cos(north * Math::PI / 180)) / Math::PI) / 2 * (1 << z), 0].max.floor
    max_x = [(east + 180) / 360 * (1 << z), (1 << z) - 1].min.floor
    max_y = [(1 - Math.log(Math.tan(south * Math::PI / 180) + 1 / Math.cos(south * Math::PI / 180)) / Math::PI) / 2 * (1 << z), (1 << z) - 1].min.floor

    (max_x - min_x + 1) * (max_y - min_y + 1)
  end

  def zoom_coverage_stats(route)
    min_zoom = route[:minzoom] || 1
    max_zoom = route[:maxzoom] || 20

    cached_counts = route[:db][:tiles]
                      .select(:zoom_level, Sequel.function(:count, :zoom_level).as(:count))
                      .where(zoom_level: min_zoom..max_zoom)
                      .group(:zoom_level)
                      .to_hash(:zoom_level, :count)

    (min_zoom..max_zoom).map do |z|
      possible = tiles_per_zoom(z, route)
      cached = cached_counts[z] || 0
      percentage = ((cached.to_f / possible) * 100).round(1)

      { zoom: z, cached: cached, possible: possible, percentage: percentage }
    end
  end

  def total_coverage_percentage(route)
    min_zoom = route[:minzoom] || 1
    max_zoom = route[:maxzoom] || 20

    total_possible = (min_zoom..max_zoom).sum { |z| tiles_per_zoom(z, route) }
    total_cached = route[:db][:tiles].where(zoom_level: min_zoom..max_zoom).count

    sprintf('%.8f', (total_cached.to_f / total_possible) * 100).sub(/\.?0+$/, '')
  end

  def d3_coverage_data(route)
    zoom_coverage_stats(route).map do |stat|
      {
        zoom: stat[:zoom],
        percentage: stat[:percentage],
        cached: stat[:cached],
        possible: stat[:possible]
      }
    end
  end

  def generate_single_source_style(route, source_name)
    base_url = request.base_url
    encoding = route.dig(:metadata, :encoding)
    is_terrain = encoding == 'terrarium' || encoding == 'mapbox'

    style = {
      version: 8,
      name: "#{source_name} Map",
      sources: {
        source_name => {
          type: is_terrain ? "raster-dem" : "raster",
          tiles: ["#{base_url}#{route[:path].gsub(':z', '{z}').gsub(':x', '{x}').gsub(':y', '{y}')}"],
          tileSize: route[:tile_size],
          minzoom: route[:minzoom] || 1,
          maxzoom: route[:maxzoom] || 20
        }
      },
      layers: []
    }

    style[:metadata] = {
      filters: { source_name.downcase => [{ id: source_name.downcase }] },
      locale: { "en" => { source_name.downcase => source_name.gsub('_', ' ') } }
    }

    if is_terrain
      style[:sources][source_name][:encoding] = encoding
      base_maxzoom = [route[:maxzoom], 15].max.clamp(15, 18)
      style[:sources][:base] = { type: "raster", tiles: ["https://mt1.google.com/vt/lyrs=p&x={x}&y={y}&z={z}"], tileSize: 256, maxzoom: base_maxzoom }
      style[:layers] << {
        id: "base-terrain",
        type: "raster",
        source: "base",
        metadata: { filter_id: source_name.downcase }
      }
      style[:terrain] = {
        source: source_name,
        exaggeration: ["interpolate", ["linear"], ["zoom"], 0, 0.5, 6, 1.0, 10, 1.5, 14, 1.2, 18, 1.0]
      }
    else
      style[:layers] << {
        id: source_name.downcase,
        type: "raster",
        source: source_name,
        layout: { visibility: "visible" },
        paint: { "raster-resampling": "cubic" },
        metadata: { filter_id: source_name.downcase }
      }
    end

    style.to_json
  end
end
