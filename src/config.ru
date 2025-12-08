require 'sinatra'
require 'sequel'
require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'
require 'stack-service-base'
require 'maplibre-preview'
require 'yaml'
require 'vips'
require 'zlib'
require 'stringio'
require_relative 'view_helpers'
require_relative 'metadata_manager'
require_relative 'background_tile_loader'
require_relative 'database_manager'
require_relative 'tile_reconstructor'

register MapLibrePreview::Extension

StackServiceBase.rack_setup self

START_TIME = Time.now

CONFIG_FOLDER = ENV['RACK_ENV'] == 'production' ? '/configs' : "#{__dir__}/configs"

ROUTES = Dir["#{CONFIG_FOLDER}/*.{yaml,yml}"].map { YAML.load_file(_1, symbolize_names: true) }.reduce({}, :merge)

SAFE_KEYS = %i[path target minzoom maxzoom mbtiles_file miss_timeout metadata style_metadata autoscan]
DB_SAFE_KEYS = SAFE_KEYS + %i[db]

require_relative 'ext/lerc_extension'
require_relative 'ext/terrain_downsample_extension'

get "/" do
  @total_sources = ROUTES.length
  @uptime = Time.now - START_TIME
  @original_config = ROUTES.transform_values { |route| route.slice(*SAFE_KEYS) }
  
  slim :index
end

get "/api/stats" do
  content_type :json
  
  route_stats = {}
  ROUTES.each do |name, route|
    tiles_count = route[:db][:tiles].count
    misses_count = route[:db][:misses].count
    cache_size = get_tiles_size(route)
    coverage_percentage = total_coverage_percentage(route)
    coverage_data = d3_coverage_data(route, name)
    
    route_stats[name.to_s] = {
      tiles_count: tiles_count,
      misses_count: misses_count,
      cache_size: cache_size,
      coverage_data: coverage_data,
      coverage_percentage: coverage_percentage
    }
  end

  total_tiles = route_stats.values.sum { |stats| stats[:tiles_count] }
  total_misses = route_stats.values.sum { |stats| stats[:misses_count] }
  total_cache_size = route_stats.values.sum { |stats| stats[:cache_size] }
  
  {
    route_stats: route_stats,
    totals: {
      tiles: total_tiles,
      misses: total_misses,
      cache_size: total_cache_size
    }
  }.to_json
end

get "/db" do
  source, route = validate_and_get_route(params[:source] || ROUTES.keys.first.to_s)
  @source, @route = source, route.slice(*DB_SAFE_KEYS)
  slim :database
end

get "/map" do
  if params[:source]
    _, route = validate_and_get_route(params[:source])
    style_url = "#{request.base_url}#{route[:path].gsub(/\/:[zxy]/, '')}"
    style_url += "?debug=true" if params[:debug] == 'true'
    
    params[:style_url] = style_url
  end
  slim :maplibre_map, layout: :maplibre_layout
end


get "/admin/vacuum" do
  content_type :json
  DatabaseManager.vacuum_all_databases(ROUTES)
  { status: "success", message: "VACUUM started for all databases" }.to_json
rescue => e
  status 500
  { status: "error", message: e.message }.to_json
end

get "/api/reconstructor/:source/status" do
  content_type :json
  
  source, route = validate_and_get_route(params[:source])
  reconstructor = route[:reconstructor]
  
  halt 404, { error: "Reconstructor not configured" }.to_json unless reconstructor
  
  reconstructor.status.to_json
end

post "/api/reconstructor/:source/start" do
  content_type :json
  
  source, route = validate_and_get_route(params[:source])
  reconstructor = route[:reconstructor]
  
  halt 404, { error: "Reconstructor not configured" }.to_json unless reconstructor
  halt 409, { error: "Already running" }.to_json if reconstructor.running?
  
  if reconstructor.start_reconstruction
    { success: true }.to_json
  else
    halt 500, { error: "Failed to start" }.to_json
  end
end

def create_http_client(uri, route)
  base_config = {
    url: "#{uri.scheme}://#{uri.host}",
    ssl: { verify: false }
  }

  Faraday.new(base_config) do |f|
    f.request :retry, max: 2, interval: 0.2, backoff_factor: 2
    f.options.timeout = 15
    f.options.open_timeout = 10
    f.adapter :net_http_persistent, pool_size: 10, idle_timeout: 60
  end
end

configure do
  ROUTES.each do |_name, route|
    uri = URI.parse route[:target].gsub(/[{}]/, '_')

    client = create_http_client(uri, route)
    route[:client] = client

    DatabaseManager.setup_route_database(route, _name)

    if route.dig(:autoscan, :enabled)
      loader = BackgroundTileLoader.new(route, _name.to_s)
      route[:autoscan_loader] = loader
      loader.start_scanning
      loader.start_wal_checkpoint_thread
    end

    if route[:gap_filling]
      reconstructor = TileReconstructor.new(route, _name.to_s)
      route[:reconstructor] = reconstructor
      reconstructor.start_scheduler
    end
  end
end

ROUTES.each do |_name, route|
  get route[:path] do
    z, x, y = params[:z].to_i, params[:x].to_i, params[:y].to_i
    tms = tms_y(z, y)

    if (tile = get_cached_tile(route, z, x, tms))
      cache_status = { 1 => :gen, 2 => :regen }.fetch(tile[:generated], :hit)
      return serve_tile(route, tile[:tile_data], cache_status)
    end

    source_real_minzoom = route.dig(:gap_filling, :source_real_minzoom)
    return serve_no_content if source_real_minzoom && z < source_real_minzoom

    if (miss_status = should_skip_request?(route, z, x, y))
      return debug_mode? ? serve_error_tile(route, miss_status) : serve_no_content
    end

    blob = fetch_with_lock(route, z, x, y, tms)
    blob ? serve_tile(route, blob, :miss) : (debug_mode? ? serve_error_tile(route, 404) : serve_no_content)
  end

  get route[:path].gsub(/\/:[zxy]/, '') do
    content_type :json
    generate_single_source_style(route, _name.to_s, debug_mode?)
  end
end

helpers do
  include ViewHelpers

  def tms_y(z, y) = (1 << z) - 1 - y

  def key(z, x, y) = "#{z}/#{x}/#{y}"

  def debug_mode?
    params[:debug] == 'true'
  end

  def validate_and_get_route(source)
    source = source&.strip
    halt 400, "Invalid source parameter" unless source&.match?(/^[A-Za-z0-9_-]+$/)

    route = ROUTES[source.to_sym]
    halt 404, "Source not found" unless route

    [source, route]
  end

  def get_cached_tile(route, z, x, tms)
    route[:db][:tiles].where(zoom_level: z, tile_column: x, tile_row: tms).select(:tile_data, :generated).first
  end

  def serve_tile(route, blob, status)
    headers build_response_headers(route, status)
    content_type route[:content_type]
    blob
  end

  def serve_error_tile(route, status_code)
    headers build_response_headers(route, :error)
    content_type route[:content_type]
    generate_error_tile(status_code)
  end

  def serve_no_content
    status 204
    ""
  end

  def fetch_with_lock(route, z, x, y, tms)
    route[:locks][key(z, x, y)].synchronize do
      tile = get_cached_tile(route, z, x, tms)
      return tile[:tile_data] if tile

      result = fetch_http(route:, x: x, y: y, z: z)

      if result[:error]
        DatabaseManager.record_miss(route, z, x, y, result[:reason], result[:details], result[:status], result[:body])
        return nil
      end

      route[:db][:tiles].insert_conflict(target: [:zoom_level, :tile_column, :tile_row],
                                         update: { tile_data: Sequel[:excluded][:tile_data] })
                        .insert(zoom_level: z, tile_column: x, tile_row: tms,
                                tile_data: Sequel.blob(result[:data]))
      result[:data]
    end
  end

  def should_skip_request?(route, z, x, y)
    timeout = route[:miss_timeout] || 300
    cutoff_time = Time.now.to_i - timeout
    tile_row = tms_y(z, y)

    route[:db][:misses].where(
      zoom_level: z,
      tile_column: x,
      tile_row: tile_row,
      ts: 0..cutoff_time
    ).delete

    miss = route[:db][:misses].where(
      zoom_level: z,
      tile_column: x,
      tile_row: tile_row
    ).first
    miss&.[](:status)
  end

  def fetch_http(route:, x:, y:, z:)
    target_path = route[:target].gsub('{z}', z.to_s)
                                .gsub('{x}', x.to_s)
                                .gsub('{y}', y.to_s)
    
    target_path += "?#{URI.encode_www_form(route[:query_params])}" if route[:query_params]

    headers = build_request_headers(route)
    response = route[:client].get(target_path, nil, headers)

    return handle_response_error(response, route, z, x, y) if (error = validate_response(response, route))

    status response.status
    copy_headers_from_response(response.headers)
    
    data = response.body
    
    if response.headers['content-encoding']&.include?('gzip')
      data = Zlib::GzipReader.new(StringIO.new(data)).read rescue data
    end
    
    if route[:source_format] == "lerc" && data && !data.empty?
      if response.headers['content-type']&.include?('text/html')
        return { error: true, reason: 'arcgis_html_error', details: build_error_details(response, "ArcGIS returned HTML error page"), status: 404, body: data }
      end
      
      begin
        decoded_data = LercFFI.lerc_to_mapbox_png(data)
        if decoded_data.nil?
          return { error: true, reason: 'arcgis_nodata', details: build_error_details(response, "LERC tile has no valid pixels (empty tile)"), status: 404, body: data }
        end
        
        headers['Content-Type'] = 'image/png'
        data = decoded_data
      rescue => e
        return { error: true, reason: 'lerc_decode_error', details: build_error_details(response, "LERC decode error: #{e.message}"), status: 500, body: data }
      end
    end
    
    if route[:downsample_config]&.dig(:enabled) && data && !data.empty?
      begin
        encoding = route[:metadata][:encoding]
        target_size = route[:downsample_config][:target_size]
        method = route[:downsample_config][:method]
        source_format = route[:metadata][:format]
        output_format = route[:metadata][:format]
        
        if source_format == 'webp'
          img = Vips::Image.new_from_buffer(data, '')
          data = img.write_to_buffer('.png')
        end
        
        data = TerrainDownsampleFFI.downsample_png(data, target_size, encoding, method)
        
        if output_format == 'webp'
          data = convert_to_webp(data, route)
          headers['Content-Type'] = 'image/webp'
        else
          headers['Content-Type'] = 'image/png'
        end
      rescue => e
        return { error: true, reason: 'image_processing_error', details: build_error_details(response, "Image processing error: #{e.message}"), status: 500, body: data }
      end
    elsif route[:webp_config] && route[:source_format] == 'png'
      begin
        data = convert_to_webp(data, route)
        headers['Content-Type'] = 'image/webp'
      rescue => e
        return { error: true, reason: 'webp_conversion_error', details: build_error_details(response, "WebP conversion error: #{e.message}"), status: 500, body: data }
      end
    end
    
    { error: false, data: data }
  end

  def validate_response(response, route)
    return "HTTP #{response.status}" if ![200, 304, 206].include?(response.status) && response.status >= 400
    
    return nil if route[:source_format] == "lerc"
    
    return "Content-Type: #{response.headers['content-type']}" unless response.headers['content-type']&.include?('image/')
    nil
  end

  def handle_response_error(response, route, z, x, y)
    error = validate_response(response, route)
    details = build_error_details(response, error)
    LOGGER.info("fetch_http error: #{error} (status: #{response.status}, source: #{route[:target]}, tile: #{z}/#{x}/#{y})")
    { error: true, reason: 'fetch_error', details: details, status: response.status, body: response.body }
  end

  otl_def def build_error_details(response, error, include_body: true)
    details = [error]
    
    response_headers = response.headers.select { |k, v| %w[content-type content-length server date].include?(k.downcase) }
    details << "Response headers: #{response_headers.map { |k, v| "#{k}=#{v}" }.join(', ')}" if response_headers.any?
    
    if include_body && response.body && !response.body.empty?
      content_type = response.headers['content-type'] || ''
      unless content_type.include?('octet-stream') || content_type.include?('image/')
        body_preview = response.body.force_encoding('UTF-8').strip[0, 200]
        body_preview += "..." if response.body.length > 200
        details << body_preview
      end
    end
    
    details.join(' | ')
  end

  otl_def def convert_to_webp(data, route)
    webp_config = route[:webp_config]
    lossless = webp_config[:lossless].nil? ? true : webp_config[:lossless]
    params = lossless ? { lossless: true, effort: webp_config[:effort]} : { lossless: false, Q: webp_config[:quality]}

    otl_current_span { _1.add_attributes params }
    Vips::Image.new_from_buffer(data, '').write_to_buffer('.webp', **params)
  end

  def build_request_headers(route)
    base_headers = {
      'Accept' => 'image/webp,image/apng,image/*,*/*;q=0.8',
      'Accept-Language' => 'en-US,en;q=0.9,ru;q=0.8',
      'Accept-Encoding' => 'gzip, deflate, br',
      'DNT' => '1',
      'Connection' => 'keep-alive',
      'Upgrade-Insecure-Requests' => '1',
      'Sec-Fetch-Dest' => 'image',
      'Sec-Fetch-Mode' => 'no-cors',
      'Sec-Fetch-Site' => 'cross-site',
      'Cache-Control' => 'no-cache',
      'Pragma' => 'no-cache'
    }

    config_headers = (route[:headers]&.dig(:request) || {}).transform_keys(&:to_s)
    base_headers.merge(config_headers)
  end

  def build_response_headers(route, cache_status)
    response_headers = route[:headers]&.dig(:response) || {}

    cache_control, status = case cache_status
                            when :hit
                              max_age = response_headers.dig(:'Cache-Control', :'max-age', :hit) || 86400
                              ["public, max-age=#{max_age}", "HIT"]
                            when :miss
                              max_age = response_headers.dig(:'Cache-Control', :'max-age', :miss) || 300
                              ["public, max-age=#{max_age}", "MISS"]
                            when :gen
                              max_age = response_headers.dig(:'Cache-Control', :'max-age', :hit) || 86400
                              ["public, max-age=#{max_age}", "GEN"]
                            when :regen
                              max_age = response_headers.dig(:'Cache-Control', :'max-age', :miss) || 300
                              ["public, max-age=#{max_age}", "REGEN"]
                            else
                              ["no-store", "ERROR"]
                            end

    { "Cache-Control" => cache_control, "X-Cache-Status" => status }
  end

  def copy_headers_from_response(response_headers)
    skip_headers = %w[connection proxy-connection transfer-encoding content-length content-encoding]
    response_headers.each { |name, value| headers[name] = value unless skip_headers.include?(name.downcase) }
  end

  def generate_error_tile(status_code)
    error_tiles_path = "#{__dir__}/assets/error_tiles"
    tile_file = case status_code
                when 401 then "#{error_tiles_path}/error_401.png"
                when 403 then "#{error_tiles_path}/error_403.png"
                when 404 then "#{error_tiles_path}/error_404.png"
                when 429 then "#{error_tiles_path}/error_429.png"
                when 500 then "#{error_tiles_path}/error_500.png"
                else "#{error_tiles_path}/error_other.png"
                end
    File.read(tile_file)
  rescue Errno::ENOENT
    status 404
    return ""
  end
end

at_exit do
  ROUTES.each do |_name, route|
    route[:autoscan_loader]&.stop_scanning
    
    if route[:reconstructor]
      route[:reconstructor].stop_scheduler
      sleep 1 if route[:reconstructor].running?
    end
  end
end

run Sinatra::Application