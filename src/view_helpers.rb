module ViewHelpers
  def get_tiles_size(route)
    route[:db][:tiles].sum(Sequel.function(:length, :tile_data)) || 0
  end

  def tiles_per_zoom(z) = 4 ** z

  def zoom_coverage_stats(route)
    min_zoom = route[:minzoom] || 1
    max_zoom = route[:maxzoom] || 20
    
    (min_zoom..max_zoom).map do |z|
      possible = tiles_per_zoom(z)
      cached = route[:db][:tiles].where(zoom_level: z).count
      percentage = ((cached.to_f / possible) * 100).round(1)
      
      { zoom: z, cached: cached, possible: possible, percentage: percentage }
    end
  end

  def total_coverage_percentage(route)
    min_zoom = route[:minzoom] || 1
    max_zoom = route[:maxzoom] || 20
    
    total_possible = (min_zoom..max_zoom).sum { |z| tiles_per_zoom(z) }
    total_cached = route[:db][:tiles].count
    
    ((total_cached.to_f / total_possible) * 100).round(2)
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
    host = request.env['rack.url_scheme'] + '://' + request.env['HTTP_HOST']
    
    {
      version: 8,
      name: "#{source_name} Map",
      sources: {
        source_name => {
          type: "raster",
          tiles: ["#{host}#{route[:path].gsub(':z', '{z}').gsub(':x', '{x}').gsub(':y', '{y}')}"],
          tileSize: route[:tileSize] || 256,
          minzoom: route[:minzoom] || 1,
          maxzoom: route[:maxzoom] || 20
        }
      },
      layers: [
        {
          id: source_name.downcase,
          type: "raster",
          source: source_name,
          layout: { visibility: "visible" },
          paint: { "raster-resampling": "nearest" }
        }
      ]
    }.to_json
  end
end
