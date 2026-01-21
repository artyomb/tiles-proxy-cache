# frozen_string_literal: true

require 'json'

module GeometryTileCalculator
  EPSILON = 1e-14
  LL_EPSILON = 1e-11

  class InvalidLatitudeError < StandardError; end

  extend self

  # Calculates boundary tiles for a GeoJSON geometry.
  #
  # @param geojson [Hash, String] GeoJSON geometry (Point, Polygon, MultiPolygon, Feature, FeatureCollection) or JSON string
  # @param zoom_levels [Integer, Array<Integer>] Zoom level(s) to calculate tiles for
  # @return [Hash] Hash with :west and/or :east keys, each containing zoom level keys with tile boundaries
  #   (min_x, min_y, max_x, max_y)
  def tiles_for_geojson(geojson, zoom_levels)
    bbox = geojson_bbox(geojson)
    tiles_for_bbox(bbox[0], bbox[1], bbox[2], bbox[3], zoom_levels)
  end

  # Calculates boundary tiles for a bounding box.
  #
  # @param west [Float] Western longitude (can be > 180, will be normalized)
  # @param south [Float] Southern latitude (-90 to 90)
  # @param east [Float] Eastern longitude (can be > 180, will be normalized)
  # @param north [Float] Northern latitude (-90 to 90)
  # @param zoom_levels [Integer, Array<Integer>] Zoom level(s) to calculate tiles for
  # @param truncate [Boolean] Whether to truncate coordinates to valid ranges (default: false)
  # @return [Hash] Hash with :west and/or :east keys, each containing zoom level keys with tile boundaries
  #   (min_x, min_y, max_x, max_y)
  def tiles_for_bbox(west, south, east, north, zooms, truncate: false)
    west = normalize_longitude(west)
    east = normalize_longitude(east)
    
    zooms = [zooms] unless zooms.is_a?(Array)
    result = { west: {}, east: {} }
    segment_index = 0

    each_bbox_segment(west, south, east, north, truncate: truncate) do |w, s, e, n|
      part = segment_index == 0 ? :west : :east

      zooms.each do |z|
        ul_tile = lonlat_to_tile(w, n, z)
        lr_tile = lonlat_to_tile(e - LL_EPSILON, s + LL_EPSILON, z)

        result[part][z] = {
          min_x: ul_tile[0],
          min_y: ul_tile[1],
          max_x: lr_tile[0],
          max_y: lr_tile[1]
        }
      end

      segment_index += 1
    end

    result.delete(:east) if result[:east].empty?
    result
  end

  # Calculates boundary tiles for a bounds string (format: "west,south,east,north").
  #
  # @param bounds_str [String] Bounds string in format "west,south,east,north"
  # @param zoom_levels [Integer, Array<Integer>] Zoom level(s) to calculate tiles for
  # @return [Hash] Hash with :west and/or :east keys, each containing zoom level keys with tile boundaries
  def tiles_for_bounds_string(bounds_str, zoom_levels)
    west, south, east, north = bounds_str.split(',').map(&:to_f)
    tiles_for_bbox(west, south, east, north, zoom_levels)
  end

  # Checks if a tile is within the specified bounds.
  #
  # @param x [Integer] Tile X coordinate
  # @param y [Integer] Tile Y coordinate
  # @param z [Integer] Zoom level
  # @param bounds_str [String] Bounds string in format "west,south,east,north"
  # @return [Boolean] true if tile is within bounds, false otherwise
  def tile_in_bounds?(x, y, z, bounds_str)
    tile_boundaries = tiles_for_bounds_string(bounds_str, z)
    tile_in_tile_boundaries?(x, y, z, tile_boundaries)
  end

  # Checks if a tile is within pre-calculated tile boundaries (for use with cached boundaries).
  #
  # @param x [Integer] Tile X coordinate
  # @param y [Integer] Tile Y coordinate
  # @param z [Integer] Zoom level
  # @param tile_boundaries [Hash] Pre-calculated tile boundaries from tiles_for_bbox or tiles_for_bounds_string
  # @return [Boolean] true if tile is within bounds, false otherwise
  def tile_in_tile_boundaries?(x, y, z, tile_boundaries)
    if tile_boundaries[:west] && tile_boundaries[:west][z]
      bounds = tile_boundaries[:west][z]
      return true if x >= bounds[:min_x] && x <= bounds[:max_x] && y >= bounds[:min_y] && y <= bounds[:max_y]
    end

    if tile_boundaries[:east] && tile_boundaries[:east][z]
      bounds = tile_boundaries[:east][z]
      return true if x >= bounds[:min_x] && x <= bounds[:max_x] && y >= bounds[:min_y] && y <= bounds[:max_y]
    end

    false
  end

  # Counts total number of tiles within the specified bounds for a zoom level.
  #
  # @param bounds_str [String] Bounds string in format "west,south,east,north"
  # @param zoom [Integer] Zoom level
  # @return [Integer] Total number of tiles
  def count_tiles_in_bounds_string(bounds_str, zoom)
    tile_boundaries = tiles_for_bounds_string(bounds_str, zoom)
    total = 0

    if tile_boundaries[:west] && tile_boundaries[:west][zoom]
      bounds = tile_boundaries[:west][zoom]
      total += (bounds[:max_x] - bounds[:min_x] + 1) * (bounds[:max_y] - bounds[:min_y] + 1)
    end

    if tile_boundaries[:east] && tile_boundaries[:east][zoom]
      bounds = tile_boundaries[:east][zoom]
      total += (bounds[:max_x] - bounds[:min_x] + 1) * (bounds[:max_y] - bounds[:min_y] + 1)
    end

    total
  end

  private

  def lonlat_to_tile(lng, lat, zoom, truncate: false)
    x, y = xy(lng, lat, truncate: truncate)
    z2 = 2.0**zoom

    xtile = if x <= 0
              0
            elsif x >= 1
              z2.to_i - 1
            else
              ((x + EPSILON) * z2).floor.to_i
            end

    ytile = if y <= 0
              0
            elsif y >= 1
              z2.to_i - 1
            else
              ((y + EPSILON) * z2).floor.to_i
            end

    [xtile, ytile, zoom]
  end

  def geojson_bbox(geojson)
    geojson = JSON.parse(geojson) if geojson.is_a?(String)

    min_lat = 90.0
    max_lat = -90.0
    
    min_lng_original = Float::INFINITY
    max_lng_original = -Float::INFINITY
    max_lng_normalized = -180.0
    min_lng_normalized = 180.0
    has_over_180 = false
    all_over_180 = true

    coords(geojson) do |coord|
      lng, lat = coord[0], coord[1]
      
      min_lng_original = [min_lng_original, lng].min
      max_lng_original = [max_lng_original, lng].max
      
      if lng > 180
        has_over_180 = true
        lng_normalized = lng - 360
        max_lng_normalized = [max_lng_normalized, lng_normalized].max
        min_lng_normalized = [min_lng_normalized, lng_normalized].min
      else
        all_over_180 = false
      end
      
      min_lat = [min_lat, lat].min
      max_lat = [max_lat, lat].max
    end

    if has_over_180
      if all_over_180
        west = min_lng_normalized
        east = max_lng_normalized
      else
        west = min_lng_original
        east = max_lng_normalized
      end
      [west, min_lat, east, max_lat]
    else
      [min_lng_original, min_lat, max_lng_original, max_lat]
    end
  end

  def xy(lng, lat, truncate: false)
    lng, lat = truncate_lnglat(lng, lat) if truncate

    x = lng / 360.0 + 0.5
    sinlat = Math.sin(lat * Math::PI / 180.0)

    # Check for poles before computation
    if lat <= -90
      raise InvalidLatitudeError, "Y can not be computed: lat=#{lat}"
    elsif lat >= 90
      raise InvalidLatitudeError, "Y can not be computed: lat=#{lat}"
    end

    begin
      y = 0.5 - 0.25 * Math.log((1.0 + sinlat) / (1.0 - sinlat)) / Math::PI
    rescue Math::DomainError, ZeroDivisionError
      raise InvalidLatitudeError, "Y can not be computed: lat=#{lat}"
    end

    [x, y]
  end

  def coords(obj, &block)
    coordinates = case obj
                  when Array
                    obj
                  when Hash
                    if obj['features']
                      obj['features'].map { |feat| feat.dig('geometry', 'coordinates') }
                    elsif obj['geometry']
                      obj['geometry']['coordinates']
                    else
                      obj['coordinates'] || obj
                    end
                  else
                    obj
                  end

    coordinates.each do |e|
      if e.is_a?(Numeric)
        block.call(coordinates[0..1]) if coordinates.length >= 2
        break
      else
        coords(e, &block)
      end
    end
  end

  def normalize_longitude(lng)
    return lng if lng >= -180 && lng <= 180
    lng > 180 ? lng - 360 : lng + 360
  end

  def truncate_lnglat(lng, lat)
    lng = [[lng, -180.0].max, 180.0].min
    lat = [[lat, -90.0].max, 90.0].min
    [lng, lat]
  end

  def each_bbox_segment(west, south, east, north, truncate: false)
    west, south = truncate_lnglat(west, south) if truncate
    east, north = truncate_lnglat(east, north) if truncate

    segments = if west > east
                 [[-180.0, south, east, north], [west, south, 180.0, north]]
               else
                 [[west, south, east, north]]
               end

    segments.each do |w, s, e, n|
      w = [-180.0, w].max
      s = [-85.051129, s].max
      e = [180.0, e].min
      n = [85.051129, n].min
      yield w, s, e, n
    end
  end
end
