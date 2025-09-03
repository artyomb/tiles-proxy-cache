require 'faraday'
require 'tempfile'

module MetadataManager
  extend self

  def initialize_metadata(db, route, route_name)
    return if db[:metadata].count > 0

    format_and_size = detect_format_and_tile_size(route)

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
    test_url = route[:target].gsub('{z}', '1').gsub('{x}', '0').gsub('{y}', '0')

    response = Faraday.get(test_url) do |req|
      req.headers.merge!(test_headers(route))
      req.options.timeout = 5
    end

    format = detect_format_from_content_type(response.headers['content-type'])
    tile_size = detect_tile_size_from_data(response.body, format)

    { format: format, tile_size: tile_size }
  rescue => e
    LOGGER.error("Failed to detect format and tile size: #{e}")
    LOGGER.warn("Using fallback values: format=png, tile_size=256")
    { format: 'png', tile_size: 256 }
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
