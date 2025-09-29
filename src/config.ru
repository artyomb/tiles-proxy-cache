require 'sinatra'
require 'sequel'
require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'
require 'stack-service-base'
require 'maplibre-preview'
require 'yaml'
require_relative 'view_helpers'
require_relative 'metadata_manager'
require_relative 'background_tile_loader'
require_relative 'database_manager'

register MapLibrePreview::Extension

StackServiceBase.rack_setup self

START_TIME = Time.now

CONFIG_FOLDER = ENV['RACK_ENV'] == 'production' ? '/configs' : "#{__dir__}/configs"

ROUTES = Dir["#{CONFIG_FOLDER}/*.{yaml,yml}"].map { YAML.load_file(_1, symbolize_names: true) }.reduce({}, :merge)

SAFE_KEYS = %i[path target minzoom maxzoom mbtiles_file miss_timeout miss_max_records metadata style_metadata autoscan]
DB_SAFE_KEYS = SAFE_KEYS + %i[db]

require_relative 'ext/lerc_extension'

get "/" do
  @total_sources = ROUTES.length
  @uptime = Time.now - START_TIME
  @original_config = ROUTES.transform_values { |route| route.slice(*SAFE_KEYS) }
  
  slim :index
end

get "/api/stats" do
  content_type :json
  
  route_stats = ROUTES.transform_values do |route|
    tiles_count = route[:db][:tiles].count
    misses_count = route[:db][:misses].count
    cache_size = get_tiles_size(route)
    coverage_data = d3_coverage_data(route)
    coverage_percentage = total_coverage_percentage(route)
    
    {
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
  render_maplibre_preview
end


get "/admin/vacuum" do
  content_type :json
  DatabaseManager.vacuum_all_databases(ROUTES)
  { status: "success", message: "VACUUM started for all databases" }.to_json
rescue => e
  status 500
  { status: "error", message: e.message }.to_json
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
  end
end

ROUTES.each do |_name, route|
  get route[:path] do
    z, x, y = params[:z].to_i, params[:x].to_i, params[:y].to_i
    tms = tms_y(z, y)

    if (blob = get_cached_tile(route, z, x, tms))
      return serve_tile(route, blob, :hit)
    end

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
    route[:db][:tiles].where(zoom_level: z, tile_column: x, tile_row: tms).get(:tile_data)
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
      blob = get_cached_tile(route, z, x, tms)
      return blob if blob

      result = fetch_http(route:, x: x, y: y, z: z)

      if result[:error]
        record_miss(route, z, x, y, result[:reason], result[:details], result[:status], result[:body])
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

    route[:db][:misses].where(z: z, x: x, y: y, ts: 0..cutoff_time).delete

    miss = route[:db][:misses].where(z: z, x: x, y: y).first
    miss&.[](:status)
  end

  def cleanup_misses_if_needed(route)
    max_records = route[:miss_max_records] || 10000
    return unless route[:db][:misses].count > max_records

    keep_count = (max_records * 0.8).to_i
    route[:db][:misses].reverse(:ts).offset(keep_count).delete
  end

  def record_miss(route, z, x, y, reason, details, status, body)
    route[:db][:misses].where(z: z, x: x, y: y).delete

    route[:db][:misses].insert(
      z: z, x: x, y: y, ts: Time.now.to_i,
      reason: reason, details: details, status: status,
      response_body: Sequel.blob(body || '')
    )

    cleanup_misses_if_needed(route)
  end

  def fetch_http(route:, x:, y:, z:)
    target_path = route[:target].gsub('{z}', z.to_s)
                                .gsub('{x}', x.to_s)
                                .gsub('{y}', y.to_s)
    
    target_path += "?#{URI.encode_www_form(route[:query_params])}" if route[:query_params]

    headers = build_request_headers.merge((route[:headers]&.dig(:request) || {}).transform_keys(&:to_s))
    response = route[:client].get(target_path, nil, headers)

    return handle_response_error(response, route, z, x, y) if (error = validate_response(response, route))

    status response.status
    copy_headers_from_response(response.headers)
    
    data = response.body
    if route[:source_format] == "lerc" && data && !data.empty?
      if response.headers['content-type']&.include?('text/html')
        return { error: true, reason: 'arcgis_html_error', details: 'ArcGIS returned HTML error page', status: 404, body: data }
      end
      
      begin
        decoded_data = LercFFI.lerc_to_mapbox_png(data)
        if decoded_data
          headers['Content-Type'] = 'image/png'
          data = decoded_data
        else
          return { error: true, reason: 'lerc_decode_failed', details: 'Failed to decode LERC data', status: 500, body: data }
        end
      rescue => e
        return { error: true, reason: 'lerc_decode_error', details: e.message, status: 500, body: data }
      end
    end
    
    { error: false, data: data }
  end

  def validate_response(response, route)
    return "HTTP #{response.status}" if ![200, 304, 206].include?(response.status) && response.status >= 400
    
    return nil if route[:source_format] == "lerc"
    
    return "Response size: #{response.body.size} bytes" if response.body.size < 100
    return "Content-Type: #{response.headers['content-type']}" unless response.headers['content-type']&.include?('image/')
    nil
  end

  def handle_response_error(response, route, z, x, y)
    error = validate_response(response, route)
    LOGGER.info("fetch_http error: #{error} (status: #{response.status}, source: #{route[:target]}, tile: #{z}/#{x}/#{y})")
    { error: true, reason: 'fetch_error', details: error, status: response.status, body: response.body }
  end

  def build_request_headers
    skip_headers = %w[host connection proxy-connection content-length if-none-match if-modified-since]

    headers = request.env.filter_map do |key, value|
      next unless key.start_with?('HTTP_')
      header = key[5..-1].tr('_', '-').split('-').map(&:capitalize).join('-')
      [header, value] unless skip_headers.include?(header.downcase)
    end.to_h

    headers.merge('Cache-Control' => 'no-cache', 'Pragma' => 'no-cache')
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
                            else
                              ["no-store", "ERROR"]
                            end

    { "Cache-Control" => cache_control, "X-Cache-Status" => status }
  end

  def copy_headers_from_response(response_headers)
    skip_headers = %w[connection proxy-connection transfer-encoding content-length]
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
  end
end

run Sinatra::Application