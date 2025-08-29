require 'sinatra'
require 'sequel'
require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'
require 'stack-service-base'
require 'yaml'
require 'autoforme'
require_relative 'view_helpers'
require_relative 'metadata_manager'

StackServiceBase.rack_setup self

START_TIME = Time.now

ERROR_TILES_PATH = "#{__dir__}/assets/error_tiles"

CONFIG_FOLDER = ENV['RACK_ENV'] == 'production' ? '/configs' : "#{__dir__}/configs"

ROUTES = Dir["#{CONFIG_FOLDER}/*.{yaml,yml}"].map {YAML.load_file(_1, symbolize_names: true) }.reduce({}, :merge)

SAFE_KEYS = %i[path target tileSize minzoom maxzoom mbtiles_file miss_timeout miss_max_records]
DB_SAFE_KEYS = SAFE_KEYS + %i[db]

require_relative 'gost.rb' if ENV['GOST']

RATE_PER_SEC = 1

get "/" do
  @total_sources = ROUTES.length
  @total_tiles = ROUTES.values.sum { |route| route[:db][:tiles].count }
  @total_misses = ROUTES.values.sum { |route| route[:db][:misses].count }
  @total_cache_size = ROUTES.values.sum { |route| get_tiles_size(route) }
  @uptime = Time.now - START_TIME
  @original_config = ROUTES.transform_values { |route| route.slice(*SAFE_KEYS) }
  slim :index
end

get "/db" do
  source = params[:source]&.strip || ROUTES.keys.first.to_s
  return status(400), "Invalid source parameter" unless source&.match?(/^[A-Za-z0-9_-]+$/)
  
  route = ROUTES[source.to_sym]
  return status(404), "Source not found" unless route
  
  @source, @route = source, route.slice(*DB_SAFE_KEYS)
  slim :database
end

get "/map" do
  source = params[:source]&.strip
  return status(400), "Invalid source parameter" unless source&.match?(/^[A-Za-z0-9_-]+$/)
  
  @route = ROUTES[source.to_sym]
  @route ? slim(:map, layout: :map_layout) : 
    (status 404; "Source not found")
end

get "/map/style" do
  source = params[:source]&.strip
  return status(400), "Invalid source parameter" unless source&.match?(/^[A-Za-z0-9_-]+$/)
  
  route = ROUTES[source.to_sym]
  route ? (content_type :json; generate_single_source_style(route, source)) :
    (status 404; "Source not found")
end

configure do
  ROUTES.each do |_name, route|
    uri = URI.parse route[:target].gsub( /[{}]/, '_')

    client = Faraday.new( url: "#{uri.scheme}://#{uri.host}", ssl: { verify: false }) do |f|
      f.request  :retry, max: 2, interval: 0.2, backoff_factor: 2
      # f.response :json, content_type: /\bjson$/
      f.options.timeout      = 15
      f.options.open_timeout = 10
      f.adapter :net_http_persistent, pool_size: 10, idle_timeout: 60
    end
    route[:client] = client

    db_path = "sqlite://" + route[:mbtiles_file]
    db = Sequel.connect(db_path, max_connections:8)

    db.run "PRAGMA page_size=4096"      # or 8192/16384; set once
    db.run "VACUUM"

    db.run "PRAGMA journal_mode=WAL"
    db.run "PRAGMA synchronous=NORMAL"
    db.run "PRAGMA locking_mode=NORMAL"
    db.run "PRAGMA busy_timeout=10000"
    db.run "PRAGMA temp_store=MEMORY"
    db.run "PRAGMA cache_size=-131072"     # ~128 MiB
    db.run "PRAGMA mmap_size=536870912"    # 512 MiB
    db.run "PRAGMA wal_autocheckpoint=0"

    db.create_table?(:metadata){ String :name, null:false; String :value; index :name }
    db.create_table?(:tiles){
      Integer :zoom_level,  null:false
      Integer :tile_column, null:false
      Integer :tile_row,    null:false
      File    :tile_data,   null:false
      unique [:zoom_level,:tile_column,:tile_row], name: :tile_index
    }
    db.create_table?(:misses){ Integer :z; Integer :x; Integer :y; Integer :ts; String :reason; String :details; Integer :status; File :response_body }
    route[:db] = db
    MetadataManager.initialize_metadata(db, route, _name)
    
    route[:content_type] = "image/#{db[:metadata].where(name: 'format').get(:value) || 'png'}"

    route[:locks] = Hash.new { |h,k| h[k] = Mutex.new }

    # Thread.new do
    #   interval = 1.0 / RATE_PER_SEC
    #   loop do
    #     z,x,y = route[:queue].pop
    #     k = key(z,x,y)
    #     route[:locks][k].synchronize { fetch_and_store(route, z, x, y) }
    #     sleep interval
    #   rescue => e
    #     warn "seeder err: #{e}"
    #   end
    # end

    # --- periodic WAL checkpoint ---
    # Thread.new do
    #   loop do
    #     sleep 30
    #     route[:db].run "PRAGMA wal_checkpoint(PASSIVE)"
    #   end
    # end
  end
end


ROUTES.each do |_name, route|
  get route[:path]  do
    z = params[:z].to_i; x = params[:x].to_i; y = params[:y].to_i
    tms = tms_y(z,y)

    # 1) try MBTiles
    if (blob = route[:db][:tiles].where(zoom_level:z, tile_column:x, tile_row:tms).get(:tile_data))
      headers build_response_headers(route, :hit)
      content_type route[:content_type]
      return blob
    end

    # 2) check recent miss (rate limiting)
    if (miss_status = should_skip_request?(route, z, x, y))
      error_tile = generate_error_tile(miss_status)
      headers build_response_headers(route, :error)
      content_type route[:content_type]
      return error_tile
    end

    # 3) miss → fetch; lock per tile
    k = key(z,x,y)
    blob = nil
    route[:locks][k].synchronize do
      # re-check after acquiring lock
      blob = route[:db][:tiles].where(zoom_level:z, tile_column:x, tile_row:tms).get(:tile_data)
      unless blob
        result = fetch_http(route:, x: params[:x], y:params[:y] , z: params[:z])

        if result[:error]
          record_miss(route, z, x, y, result[:reason], result[:details], result[:status], result[:body])
          
          error_tile = generate_error_tile(result[:status])
          headers build_response_headers(route, :error)
          content_type route[:content_type]
          return error_tile
        else
          route[:db][:tiles].insert_conflict(target: [:zoom_level,:tile_column,:tile_row],
                                update: {tile_data: Sequel[:excluded][:tile_data]}).
            insert(zoom_level:z, tile_column:x, tile_row:tms, tile_data:Sequel.blob(result[:data]))
          blob = result[:data]
        end
      end
    end

    if blob
      headers build_response_headers(route, :miss)
      content_type route[:content_type]
      blob
    else
      status 404
      headers build_response_headers(route, :error)
      ""
    end
  end

  get route[:path].gsub( /\/:[zxy]/, '') do
    host = request.env['rack.url_scheme'] + '://'+  request.env['HTTP_HOST']
    path = route[:path].gsub(':z', '{z}').gsub(':x', '{x}').gsub(':y', '{y}')

    content_type :json
    {
      version: 8,
      id: "raster",
      name: "Raster",
      sources: {
        raster: { type: "raster", tiles: [host + path],
                  tileSize: route[:tileSize] || 256,
                  minzoom: route[:minzoom] || 1,
                  maxzoom: route[:maxzoom] || 20
        }
      },
      layers: [
        { id: 'raster', type: 'raster', source: "raster", layout: { visibility: "visible" }, paint: { "raster-resampling": "nearest" } }
      ]
    }.to_json
  end
end


helpers do
  include ViewHelpers
  def tms_y(z,y) (1<<z) - 1 - y end
  def key(z,x,y) "#{z}/#{x}/#{y}" end

  def should_skip_request?(route, z, x, y)
    timeout = route[:miss_timeout] || 300
    cutoff_time = Time.now.to_i - timeout
    
    # Lazy cleanup
    route[:db][:misses].where(z: z, x: x, y: y, ts: 0..cutoff_time).delete

    miss = route[:db][:misses].where(z: z, x: x, y: y).first
    miss ? miss[:status] : nil
  end

  def cleanup_misses_if_needed(route)
    max_records = route[:miss_max_records] || 10000
    return unless route[:db][:misses].count > max_records
    
    # Keep 80% of max_records, delete oldest
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
    target_path = route[:target].gsub( '{z}', params[:z])
                                .gsub( '{x}', params[:x])
                                .gsub( '{y}', params[:y])

    args = { method:       :get,
             target_path:  target_path,
             body_content: request.body,
             headers:       build_request_headers.merge((route[:headers]&.dig(:request) || {}).transform_keys(&:to_s))
    }
    args.delete(:body_content) if args[:method] in [:get, :head, :delete, :options]

    response = route[:client].send(*args.values)

    error_checks = {
      'http_error' => -> { ![200, 304, 206].include?(response.status) && response.status >= 400 ? "HTTP #{response.status}" : nil },
      'small_size' => -> { response.body.size < 100 ? "Response size: #{response.body.size} bytes" : nil },
      'wrong_content_type' => -> { !response.headers['content-type']&.include?('image/') ? "Content-Type: #{response.headers['content-type']}" : nil }
    }
    
    error_checks.each do |reason, check|
      details = check.call
      if details
        LOGGER.info("fetch_http error: #{reason} - #{details} (status: #{response.status}, source: #{route[:target]}, tile: #{z}/#{x}/#{y})")
        return { error: true, reason: reason, details: details, status: response.status, body: response.body }
      end
    end

    status response.status
    copy_headers_from_response(response.headers)

    { error: false, data: response.body }
  end

  # def fetch_and_store(route, z,x,y)
  #   # skip if already present
  #   return true if route[:db][:tiles].where(zoom_level:z, tile_column:x, tile_row:tms_y(z,y)).get(1)
  #   # avoid hammering dead tiles (cache 404 for 10 min)
  #   stale = (Time.now.to_i - 600)
  #   miss = route[:db][:misses].where(z:z,x:x,y:y).reverse(:ts).get(:ts)
  #   return false if miss && miss > stale
  #
  #   data = fetch_http(url(z,x,y))
  #   if data
  #     route[:db][:misses].insert_conflict(target: [:zoom_level,:tile_column,:tile_row],
  #                           update: {tile_data: Sequel[:excluded][:tile_data]}).
  #       insert(zoom_level:z, tile_column:x, tile_row:tms_y(z,y), tile_data:Sequel.blob(data))
  #     true
  #   else
  #     route[:db][:misses].insert(z:z,x:x,y:y,ts:Time.now.to_i)
  #     false
  #   end
  # end

  def request_headers
    env.inject({}){|acc, (k,v)| acc[$1.downcase] = v if k =~ /^http_(.*)/i; acc}.transform_keys(&:to_sym)
  end

  def build_request_headers
    headers = {}
    skip_headers = %w[host connection proxy-connection content-length if-none-match if-modified-since]

    request.env.each do |key, value|
      next unless key.start_with?('HTTP_')
      header = key[5..-1].tr('_', '-').split('-').map(&:capitalize).join('-')
      headers[header] = value unless skip_headers.include?(header.downcase)
    end

    headers.merge!({ 'Cache-Control' => 'no-cache', 'Pragma' => 'no-cache' })
    headers
  end

  def build_response_headers(route, cache_status)
    response_headers = route[:headers]&.dig(:response) || {}
    
    case cache_status
    when :hit
      max_age = response_headers.dig(:'Cache-Control', :'max-age', :hit) || 86400
      { "Cache-Control" => "public, max-age=#{max_age}", "X-Cache-Status" => "HIT" }
    when :miss
      max_age = response_headers.dig(:'Cache-Control', :'max-age', :miss) || 300
      { "Cache-Control" => "public, max-age=#{max_age}", "X-Cache-Status" => "MISS" }
    when :error, :else
      { "Cache-Control" => "no-store", "X-Cache-Status" => "ERROR" }
    end
  end
  def copy_headers_from_response(response_headers)
    skip_headers = %w[connection proxy-connection transfer-encoding content-length]

    response_headers.each do |name, value|
      headers[name] = value unless skip_headers.include?(name.downcase)
    end
  end

  def generate_error_tile(status_code)
    tile_file = case status_code
      when 401 then "#{ERROR_TILES_PATH}/error_401.png"
      when 403 then "#{ERROR_TILES_PATH}/error_403.png"
      when 404 then "#{ERROR_TILES_PATH}/error_404.png"
      when 429 then "#{ERROR_TILES_PATH}/error_429.png"
      when 500 then "#{ERROR_TILES_PATH}/error_500.png"
      when nil then "#{ERROR_TILES_PATH}/error_other.png"
      else "#{ERROR_TILES_PATH}/error_other.png"
                end
    File.read(tile_file)
  rescue Errno::ENOENT
    status 404
    return ""
  end
end

run Sinatra::Application