require 'faraday'

module MetadataManager
  extend self

  def initialize_metadata(db, route, route_name)
    return if db[:metadata].count > 0
    
    metadata = {
      'name' => format_name(route_name),
      'format' => detect_format(route),
      'bounds' => route.dig(:metadata, :bounds) || '-180,-85.0511,180,85.0511',
      'center' => route.dig(:metadata, :center) || '0,0,3',
      'minzoom' => (route[:minzoom] || 1).to_s,
      'maxzoom' => (route[:maxzoom] || 20).to_s,
      'type' => route.dig(:metadata, :type) || 'baselayer'
    }
    
    db[:metadata].multi_insert(metadata.map { |k, v| { name: k, value: v } })
  end

  private

  def format_name(route_name)
    route_name.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')
  end

  def detect_format(route)
    test_url = route[:target].gsub('{z}', '1').gsub('{x}', '0').gsub('{y}', '0')
    
    response = Faraday.get(test_url) do |req|
      req.headers.merge!(test_headers(route))
      req.options.timeout = 5
    end
    
    case response.headers['content-type']
    when /image\/png/ then 'png'
    when /image\/jpe?g/ then 'jpg' 
    when /image\/webp/ then 'webp'
    else 'png'
    end
  rescue
    'png'
  end

  def test_headers(route)
    config_headers = route.dig(:headers, :request) || {}
    
    default_headers = {
      'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept' => 'image/png,image/jpeg,image/webp,*/*',
      'Accept-Language' => 'en-US,en;q=0.9',
      'Cache-Control' => 'no-cache'
    }
    
    default_headers.merge(config_headers)
  end
end
