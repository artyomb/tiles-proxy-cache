require 'faraday'
require 'tempfile'

module MetadataManager
  extend self

  def initialize_metadata(db, route, route_name)
    return if db[:metadata].count > 0

    format_and_size = route.dig(:metadata, :format) ? 
      { format: route.dig(:metadata, :format), tile_size: (route.dig(:metadata, :tileSize) || 256).to_i } :
      detect_format_and_tile_size(route)

    metadata = {
      'name' => format_name(route_name),
      'format' => format_and_size[:format],
      'tileSize' => format_and_size[:tile_size].to_s,
      'bounds' => route.dig(:metadata, :bounds) || '-180,-85.0511,180,85.0511',
      'center' => route.dig(:metadata, :center) || '0,0,3',
      'minzoom' => (route[:minzoom] || 1).to_s,
      'maxzoom' => (route[:maxzoom] || 20).to_s,
      'type' => route.dig(:metadata, :type) || 'baselayer',
      'encoding' => route.dig(:metadata, :encoding) || ''
    }

    db[:metadata].multi_insert(metadata.map { |k, v| { name: k, value: v } })
  end

  private

  def format_name(route_name)
    route_name.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')
  end

  def detect_format_and_tile_size(route)
    min_zoom = route[:minzoom] || 1
    max_zoom = route[:maxzoom] || 20
    range = max_zoom - min_zoom
    test_zooms = range <= 3 ? (min_zoom..max_zoom).to_a : 
                 [min_zoom, min_zoom + range / 3, min_zoom + range * 2 / 3, max_zoom].map(&:round).uniq
    
    hot_spots = [[37.6176, 55.7558], [-0.1276, 51.5074], [-74.0060, 40.7128], [0, 0]]
    
    test_zooms.each do |zoom|
      hot_spots.each do |lon, lat|
        x = ((lon + 180) / 360 * (1 << zoom)).floor
        y = ((1 - Math.log(Math.tan(lat * Math::PI / 180) + 1 / Math.cos(lat * Math::PI / 180)) / Math::PI) / 2 * (1 << zoom)).floor
        
        next if x < 0 || y < 0 || x >= (1 << zoom) || y >= (1 << zoom)
        
        result = try_fetch_tile(route, zoom, x, y)
        return result if result
      end
    end
    
    LOGGER.warn("Failed to detect format and tile size, using fallback")
    { format: 'png', tile_size: 256 }
  end

  def try_fetch_tile(route, zoom, x, y)
    test_url = route[:target].gsub('{z}', zoom.to_s).gsub('{x}', x.to_s).gsub('{y}', y.to_s)
    test_url += "?#{URI.encode_www_form(route[:query_params])}" if route[:query_params]
    uri = URI.parse(test_url)

    response = route[:client].get(uri.path + (uri.query ? "?#{uri.query}" : '')) do |req|
      req.headers.merge!(test_headers(route))
      req.options.timeout = 5
    end

    return nil unless response.success? && response.body&.size.to_i > 100
    return nil unless response.headers['content-type']&.include?('image/')

    format = detect_format_from_content_type(response.headers['content-type'])
    tile_size = detect_tile_size_from_data(response.body, format)

    return nil unless format && tile_size

    { format: format, tile_size: tile_size }
  rescue => e
    LOGGER.debug("Failed to test zoom=#{zoom}, x=#{x}, y=#{y}: #{e.message}")
    nil
  end

  def detect_format_from_content_type(content_type)
    case content_type
    when /image\/png/ then 'png'
    when /image\/jpe?g/ then 'jpg'
    when /image\/webp/ then 'webp'
    when /image\/tiff/ then 'tiff'
    when /image\/bmp/ then 'bmp'
    when /image\/gif/ then 'gif'
    else nil
    end
  end

  def detect_tile_size_from_data(image_data, format)
    return nil unless image_data && format

    Tempfile.create(['tile', ".#{format}"]) do |f|
      f.binmode
      f.write(image_data)
      f.close
      output = `file "#{f.path}" 2>/dev/null`
      standard_sizes = [256, 512, 1024, 128, 64, 32]

      return output.match(/height=(\d+).*width=(\d+)/) { |m| $1.to_i if $1.to_i == $2.to_i && standard_sizes.include?($1.to_i) } if format == 'tiff'

      standard_sizes.each do |size|
        if output.include?("#{size}x#{size}") || output.include?("#{size} x #{size}")
          return size
        end
      end
      nil
    end
  rescue => e
    LOGGER.warn("Failed to detect tile size: #{e}")
    nil
  end

  def test_headers(route)
    config_headers = route.dig(:headers, :request) || {}

    default_headers = {
      'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept' => 'image/png,image/jpeg,image/webp,image/tiff,image/bmp,image/gif,*/*',
      'Accept-Language' => 'en-US,en;q=0.9',
      'Cache-Control' => 'no-cache'
    }

    default_headers.merge(config_headers)
  end
end
