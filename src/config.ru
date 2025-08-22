require 'sinatra'
require 'sequel'
require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'
require 'stack-service-base'
require 'yaml'

StackServiceBase.rack_setup self

CONFIG_FOLDER = ENV['RACK_ENV'] == 'production' ? '/configs' : "#{__dir__}/configs"

ROUTES = Dir["#{CONFIG_FOLDER}/*.{yaml,yml}"].map {YAML.load_file(_1, symbolize_names: true) }.reduce({}, :merge)

require_relative 'gost.rb' if ENV['GOST']

RATE_PER_SEC = 1

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
    db.create_table?(:misses){ Integer :z; Integer :x; Integer :y; Integer :ts }
    route[:db] = db

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
      headers "Cache-Control" => "public, max-age=86400"
      content_type "image/png" # TODO
      return blob
    end

    # 2) miss → fetch; lock per tile
    k = key(z,x,y)
    blob = nil
    route[:locks][k].synchronize do
      # re-check after acquiring lock
      blob = route[:db][:tiles].where(zoom_level:z, tile_column:x, tile_row:tms).get(:tile_data)
      unless blob
        data = fetch_http(route:, x: params[:x], y:params[:y] , z: params[:z])

        if data
          route[:db][:tiles].insert_conflict(target: [:zoom_level,:tile_column,:tile_row],
                                update: {tile_data: Sequel[:excluded][:tile_data]}).
            insert(zoom_level:z, tile_column:x, tile_row:tms, tile_data:Sequel.blob(data))
          blob = data
        else
          route[:db][:misses].insert(z:z,x:x,y:y,ts:Time.now.to_i)
        end
      end
    end

    if blob
      headers "Cache-Control" => "public, max-age=300"
      content_type "image/png" # TODO
      blob
    else
      status 404
      headers "Cache-Control" => "no-store"
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
  def tms_y(z,y) (1<<z) - 1 - y end
  def key(z,x,y) "#{z}/#{x}/#{y}" end

  def fetch_http(route:, x:, y:, z:)
    target_path = route[:target].gsub( '{z}', params[:z])
                                .gsub( '{x}', params[:x])
                                .gsub( '{y}', params[:y])

    args = { method:       :get,
             target_path:  target_path,
             body_content: request.body,
             headers:      build_request_headers.merge(route[:headers] || {})
    }
    args.delete(:body_content) if args[:method] in [:get, :head, :delete, :options]

    response = route[:client].send *args.values

    status response.status
    copy_headers_from_response(response.headers)

    body response.body
  end

  def fetch_and_store(route, z,x,y)
    # skip if already present
    return true if route[:db][:tiles].where(zoom_level:z, tile_column:x, tile_row:tms_y(z,y)).get(1)
    # avoid hammering dead tiles (cache 404 for 10 min)
    stale = (Time.now.to_i - 600)
    miss = route[:db][:misses].where(z:z,x:x,y:y).reverse(:ts).get(:ts)
    return false if miss && miss > stale

    data = fetch_http(url(z,x,y))
    if data
      route[:db][:misses].insert_conflict(target: [:zoom_level,:tile_column,:tile_row],
                            update: {tile_data: Sequel[:excluded][:tile_data]}).
        insert(zoom_level:z, tile_column:x, tile_row:tms_y(z,y), tile_data:Sequel.blob(data))
      true
    else
      route[:db][:misses].insert(z:z,x:x,y:y,ts:Time.now.to_i)
      false
    end
  end

  def request_headers
    env.inject({}){|acc, (k,v)| acc[$1.downcase] = v if k =~ /^http_(.*)/i; acc}.transform_keys(&:to_sym)
  end

  def build_request_headers
    headers = {}
    skip_headers = %w[host connection proxy-connection content-length]

    request.env.each do |key, value|
      next unless key.start_with?('HTTP_')
      header = key[5..-1].tr('_', '-').split('-').map(&:capitalize).join('-')
      headers[header] = value unless skip_headers.include?(header.downcase)
    end

    headers
  end
  def copy_headers_from_response(response_headers)
    skip_headers = %w[connection proxy-connection transfer-encoding content-length]

    response_headers.each do |name, value|
      headers[name] = value unless skip_headers.include?(name.downcase)
    end
  end
end

run Sinatra::Application