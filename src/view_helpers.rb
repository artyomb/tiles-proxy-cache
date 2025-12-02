# frozen_string_literal: true

module ViewHelpers
  def get_tiles_size(route)
    db = route[:db]
    db.table_exists?(:tiles) ? (db[:tiles].sum(Sequel.function(:length, :tile_data)) || 0) : 0
  end

  def tiles_per_zoom(z, route = nil)
    return 4 ** z unless route

    bounds_str = route.dig(:metadata, :bounds) || '-180,-85.0511,180,85.0511'
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
    db = route[:db]

    cached_counts = db.table_exists?(:tiles) ? db[:tiles]
      .select(:zoom_level, Sequel.function(:count, :zoom_level).as(:count))
      .where(zoom_level: min_zoom..max_zoom)
      .group(:zoom_level)
      .to_hash(:zoom_level, :count) : {}

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
    db = route[:db]

    total_possible = (min_zoom..max_zoom).sum { |z| tiles_per_zoom(z, route) }
    total_cached = db.table_exists?(:tiles) ? db[:tiles].where(zoom_level: min_zoom..max_zoom).count : 0

    format('%.8f', (total_cached.to_f / total_possible) * 100).sub(/\.?0+$/, '')
  end

  def zoom_level_observability_data(route, source_name = nil)
    min_zoom = route[:minzoom] || 1
    max_zoom = route[:maxzoom] || 20
    db = route[:db]

    has_progress_table = db.table_exists?(:tile_scan_progress)
    autoscan_statuses = {}
    if has_progress_table && source_name
      autoscan_statuses = db[:tile_scan_progress]
        .where(source: source_name.to_s)
        .to_hash(:zoom_level, :status)
    end

    errors_by_zoom = db.table_exists?(:misses) ? db[:misses]
      .select(:zoom_level, Sequel.function(:count, :zoom_level).as(:count))
      .where(zoom_level: min_zoom..max_zoom)
      .group(:zoom_level)
      .to_hash(:zoom_level, :count) : {}

    cached_by_zoom = db.table_exists?(:tiles) ? db[:tiles]
      .select(:zoom_level, Sequel.function(:count, :zoom_level).as(:count))
      .where(zoom_level: min_zoom..max_zoom)
      .group(:zoom_level)
      .to_hash(:zoom_level, :count) : {}

    generated_by_zoom = db.table_exists?(:tiles) ? db[:tiles]
      .select(:zoom_level, Sequel.function(:count, :zoom_level).as(:count))
      .where(zoom_level: min_zoom..max_zoom)
      .where(Sequel[:generated] > 0)
      .group(:zoom_level)
      .to_hash(:zoom_level, :count) : {}

    (min_zoom..max_zoom).map do |z|
      possible = tiles_per_zoom(z, route)
      cached = cached_by_zoom[z] || 0
      errors = errors_by_zoom[z] || 0
      generated = generated_by_zoom[z] || 0
      remaining = [possible - cached - errors, 0].max

      percentage = possible > 0 ? ((cached.to_f / possible) * 100).round(1) : 0
      autoscan_status = autoscan_statuses[z] || 'waiting'

      {
        zoom: z,
        percentage: percentage,
        cached: cached,
        possible: possible,
        errors: errors,
        remaining: remaining,
        generated: generated,
        autoscan_status: autoscan_status
      }
    end
  end

  def d3_coverage_data(route, source_name = nil)
    zoom_level_observability_data(route, source_name).map do |stat|
      {
        zoom: stat[:zoom],
        percentage: stat[:percentage],
        cached: stat[:cached],
        possible: stat[:possible],
        errors: stat[:errors],
        remaining: stat[:remaining],
        generated: stat[:generated],
        autoscan_status: stat[:autoscan_status]
      }
    end
  end

  def generate_single_source_style(route, source_name, debug_mode = false)
    base_url = request.base_url
    encoding = route.dig(:metadata, :encoding)
    is_terrain = %w[terrarium mapbox].include?(encoding)

    bounds = route.dig(:metadata, :bounds).split(',')&.map(&:to_f)

    tile_url = "#{base_url}#{route[:path].gsub(':z', '{z}').gsub(':x', '{x}').gsub(':y', '{y}')}"
    tile_url += '?debug=true' if debug_mode

    style = {
      version: 8,
      name: "#{source_name.gsub('_', ' ')}",
      sources: {
        source_name => {
          type: is_terrain ? 'raster-dem' : 'raster',
          tiles: [tile_url],
          tileSize: route[:tile_size],
          minzoom: route[:minzoom] || 1,
          maxzoom: route[:maxzoom] || 20
        }
      },
      layers: []
    }

    style[:glyphs] = 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf' if is_terrain
    style[:sources][source_name][:bounds] = bounds if bounds

    if is_terrain
      style[:metadata] = {
        filters: { source_name.downcase => [
          { id: source_name.downcase },
          { id: 'color_relief_layer' },
          { id: 'brown_relief_layer' },
          { id: 'hillshade_layer' },
          { id: 'contour_layer' },
          { id: 'satellite_layer' }
        ] },
        locale: { 'en-US' => { source_name.downcase =>
                              source_name.gsub('_', ' '), 'color_relief_layer' => 'Color Relief', 'brown_relief_layer' => 'Brown Relief', 'hillshade_layer' => 'Hillshade', 'contour_layer' => 'Contour Lines', 'satellite_layer' => 'Satellite' } }
      }
    else
      style[:metadata] = {
        filters: { 'background' => [{ id: 'background' }] },
        locale: { 'en-US' => { 'background' => source_name.gsub('_', ' ') } }
      }
    end
    
    style[:metadata][:base_map] = { type: route.dig(:style_metadata, :base_map, :type) }

    if is_terrain
      style[:sources][source_name][:encoding] = encoding

      base_maxzoom = [route[:maxzoom], 15].max.clamp(15, 18)
      style[:sources][:base] = { type: 'raster', tiles: ['https://mt1.google.com/vt/lyrs=p&x={x}&y={y}&z={z}'], tileSize: 256, maxzoom: base_maxzoom }
      style[:sources][:satellite] = { type: 'raster', tiles: ['https://mt2.google.com/vt/lyrs=s,h&x={x}&y={y}&z={z}'], tileSize: 256, maxzoom: base_maxzoom }

      style[:layers] << {
        id: 'base-terrain',
        type: 'raster',
        source: 'base',
        metadata: { filter_id: source_name.downcase }
      }
      style[:layers] << {
        id: 'satellite-overlay',
        type: 'raster',
        source: 'satellite',
        layout: { visibility: 'none' },
        metadata: { filter_id: 'satellite_layer' }
      }
      style[:layers] << {
        id: 'color-relief',
        type: 'color-relief',
        source: source_name,
        layout: { visibility: 'none' },
        paint: {
          "color-relief-color": ['interpolate', ['linear'], ['elevation'],
                                 # Sea depths
                                 -1000, 'rgba(0, 0, 139, 0.3)', -500, 'rgba(0, 0, 205, 0.35)', -100, 'rgba(0, 191, 255, 0.4)', -10, 'rgba(135, 206, 235, 0.45)',
                                 # Lowlands (0-200m)
                                 0, 'rgba(34, 139, 34, 0.2)', 50, 'rgba(50, 205, 50, 0.25)', 100, 'rgba(144, 238, 144, 0.3)', 200, 'rgba(154, 205, 50, 0.35)',
                                 # Uplands (200-500m)
                                 300, 'rgba(255, 255, 0, 0.4)', 400, 'rgba(255, 215, 0, 0.45)', 500, 'rgba(255, 165, 0, 0.5)',
                                 # Low mountains (500-1000m)
                                 600, 'rgba(255, 140, 0, 0.55)', 800, 'rgba(255, 69, 0, 0.6)', 1000, 'rgba(255, 99, 71, 0.6)',
                                 # Medium mountains (1000-2000m)
                                 1200, 'rgba(205, 92, 92, 0.6)', 1500, 'rgba(160, 82, 45, 0.65)', 1800, 'rgba(139, 69, 19, 0.65)', 2000, 'rgba(128, 0, 0, 0.7)',
                                 # High mountains (2000m+)
                                 2500, 'rgba(105, 105, 105, 0.7)', 3000, 'rgba(64, 64, 64, 0.7)', 4000, 'rgba(47, 79, 79, 0.7)', 5000, 'rgba(25, 25, 112, 0.7)', 6000, 'rgba(0, 0, 0, 0.7)']
        },
        metadata: { filter_id: 'color_relief_layer' }
      }
      style[:layers] << {
        id: 'brown-relief',
        type: 'color-relief',
        source: source_name,
        layout: { visibility: 'none' },
        paint: {
          "color-relief-color": ['interpolate', ['linear'], ['elevation'],
                                 # Sea level
                                 -1, 'rgba(255, 255, 255, 0.2)', 0, 'rgba(255, 253, 244, 0.25)',
                                 # Low elevations (0-91m)
                                 91, 'rgba(252, 255, 234, 0.3)',
                                 # Medium elevations (305-610m)
                                 305, 'rgba(252, 249, 216, 0.4)', 610, 'rgba(251, 239, 181, 0.45)',
                                 # Higher elevations (914-1219m)
                                 914, 'rgba(253, 219, 121, 0.55)', 1219, 'rgba(232, 173, 81, 0.6)',
                                 # Mountain elevations (1524-1829m)
                                 1524, 'rgba(217, 142, 51, 0.6)', 1829, 'rgba(181, 93, 22, 0.65)',
                                 # High mountains (2438-3048m)
                                 2438, 'rgba(156, 73, 19, 0.65)', 3048, 'rgba(147, 62, 21, 0.7)',
                                 # Very high mountains (4572-9144m)
                                 4572, 'rgba(121, 49, 11, 0.7)', 9144, 'rgba(0, 0, 4, 0.7)']
        },
        metadata: { filter_id: 'brown_relief_layer' }
      }
      style[:layers] << {
        id: 'hillshade',
        type: 'hillshade',
        source: source_name,
        layout: { visibility: 'none' },
        paint: {
          "hillshade-shadow-color": '#473B24',
          "hillshade-highlight-color": '#FFFFFF',
          "hillshade-accent-color": '#CCAA88'
        },
        metadata: { filter_id: 'hillshade_layer' }
      }
      style[:sources]["#{source_name}_contours"] = {
        type: 'vector',
        tiles: ["#{source_name}_contour_protocol://{z}/{x}/{y}"],
        maxzoom: 15
      }
      style[:layers] << {
        id: 'contours',
        type: 'line',
        source: "#{source_name}_contours",
        "source-layer": 'contours',
        layout: { visibility: 'none' },
        paint: {
          "line-color": ['match', %w[get level], 1, '#4A4A4A', '#8A8A8A'],
          "line-width": ['match', %w[get level], 1, 1.5, 0.8],
          "line-opacity": 0.7
        },
        metadata: { filter_id: 'contour_layer' }
      }
      style[:layers] << {
        id: 'contour-labels',
        type: 'symbol',
        source: "#{source_name}_contours",
        "source-layer": 'contours',
        filter: ['>', %w[get level], 0],
        layout: {
          visibility: 'none',
          "symbol-placement": 'line',
          "text-size": 10,
          "text-field": ['concat', ['number-format', %w[get ele], {}], 'm'],
          "text-font": ['Noto Sans Bold']
        },
        paint: {
          "text-color": '#333333',
          "text-halo-color": '#ffffff',
          "text-halo-width": 1.5
        },
        metadata: { filter_id: 'contour_layer' }
      }
      style[:terrain] = {
        source: source_name,
        exaggeration: 1.5
      }
    else
      style[:layers] << {
        id: source_name.downcase,
        type: 'raster',
        source: source_name,
        layout: { visibility: 'visible' },
        paint: { "raster-resampling": 'linear' },
        metadata: { filter_id: 'background' }
      }
    end

    style.to_json
  end
end
