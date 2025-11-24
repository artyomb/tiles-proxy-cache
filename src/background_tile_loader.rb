require 'vips'
require 'zlib'
require 'stringio'
require_relative 'ext/terrain_downsample_extension'

class BackgroundTileLoader
  def initialize(route, source_name)
    @route = route
    @source_name = source_name
    @config = route[:autoscan] || {}
    @running = false
    @tiles_today = 0
    @current_progress = {}

    setup_progress_table
    load_todays_progress
  end

  def start_scanning
    return unless @config[:enabled]
    return if @running

    @running = true
    LOGGER.info("Starting autoscan for #{@source_name}")
    initialize_zoom_progress

    @scan_thread = Thread.new do
      begin
        start_zoom = @route[:minzoom] || 1
        end_zoom = @config[:max_scan_zoom] || 20

        (start_zoom..end_zoom).each { |z| scan_zoom_level(z) }
      rescue => e
        LOGGER.error("Autoscan error for #{@source_name}: #{e}")
        update_all_statuses('error')
      ensure
        @running = false
        update_active_status('stopped') unless e
      end
    end
  end

  def stop_scanning
    return unless @running

    @running = false
    update_active_status('stopped')
    @scan_thread&.join(5)
    LOGGER.info("Stopped autoscan for #{@source_name}")
  end

  def start_wal_checkpoint_thread
    Thread.new do
      loop do
        sleep 15
        begin
          result = @route[:db].run "PRAGMA wal_checkpoint(PASSIVE)"
          if result&.is_a?(Array) && result[0] == 1
            @route[:db].run "PRAGMA wal_checkpoint(RESTART)"
          end
        rescue => e
          LOGGER.warn("WAL checkpoint error: #{e}")
        end
      end
    end
  end

  private

  def setup_progress_table
    @route[:db].create_table?(:tile_scan_progress) do
      String :source, null: false
      Integer :zoom_level, null: false
      Integer :last_x, default: 0
      Integer :last_y, default: 0
      Integer :tiles_today, default: 0
      String :last_scan_date
      String :status, default: 'waiting'
      primary_key [:source, :zoom_level]
    end
  end

  def scan_zoom_level(z)
    if zoom_complete?(z)
      LOGGER.info("Zoom #{z} already complete for #{@source_name}")
      update_status(z, 'completed')
      return
    end

    bounds = get_bounds_for_zoom(z)
    return unless bounds

    @current_progress[z] = load_progress(z)
    update_status(z, 'active')

    scan_zoom_grid(z, bounds)

    cleanup_zoom_misses(z)
    final_x = @current_progress[z]&.dig(:x) || 0
    final_y = @current_progress[z]&.dig(:y) || 0
    save_progress(final_x, final_y, z)
    update_status(z, 'completed')
  end

  def scan_zoom_grid(z, bounds)
    _, min_y, max_x, max_y = bounds
    x, y = @current_progress[z].values_at(:x, :y)

    (x..max_x).each do |curr_x|
      start_y = curr_x == x ? y : min_y

      (start_y..max_y).each do |curr_y|
        return unless @running

        @current_progress[z][:x] = curr_x
        @current_progress[z][:y] = curr_y

        if fetch_tile(curr_x, curr_y, z)
          @tiles_today += 1
          save_progress(curr_x, curr_y, z) if @tiles_today % 10 == 0
          sleep calculate_delay
        end
      end
    end
    LOGGER.info("Completed zoom level #{z} for #{@source_name}")
  end

  def fetch_tile(x, y, z)
    target_url = @route[:target].gsub('{z}', z.to_s).gsub('{x}', x.to_s).gsub('{y}', y.to_s)
    target_url += "?#{URI.encode_www_form(@route[:query_params])}" if @route[:query_params]
    headers = get_headers

    return false if tile_exists?(x, y, z)

    begin
      response = @route[:client].get(target_url, nil, headers)
      
      unless response.success?
        DatabaseManager.record_miss(@route, z, x, y, 'http_error', "HTTP #{response.status}", response.status, response.body)
        return false
      end

      data = response.body
      
      if response.headers['content-encoding']&.include?('gzip')
        data = Zlib::GzipReader.new(StringIO.new(data)).read rescue data
      end
      
      if @route[:source_format] == 'lerc'
        if response.headers['content-type']&.include?('text/html')
          DatabaseManager.record_miss(@route, z, x, y, 'arcgis_html_error', 'ArcGIS returned HTML error page', 404, data)
          return false
        end
        
        begin
          decoded = LercFFI.lerc_to_mapbox_png(data)
          if decoded.nil?
            DatabaseManager.record_miss(@route, z, x, y, 'arcgis_nodata', 'LERC tile has no valid pixels (empty tile)', 404, data)
            LOGGER.debug("Skipping empty LERC tile #{z}/#{x}/#{y} (no valid pixels)")
            return false
          end
          data = decoded
        rescue => e
          DatabaseManager.record_miss(@route, z, x, y, 'lerc_decode_error', "LERC decode error: #{e.message}", 500, data)
          LOGGER.warn("LERC decode error for #{z}/#{x}/#{y}: #{e}")
          return false
        end
      else
        content_type = response.headers['content-type']
        unless content_type&.include?('image/')
          DatabaseManager.record_miss(@route, z, x, y, 'invalid_content_type', "Content-Type: #{content_type}", 200, data)
          LOGGER.warn("Invalid content-type for #{z}/#{x}/#{y}: #{content_type}")
          return false
        end
      end

      if @route[:downsample_config]&.dig(:enabled) && data && !data.empty?
        begin
          encoding = @route[:metadata][:encoding]
          target_size = @route[:downsample_config][:target_size]
          method = @route[:downsample_config][:method]
          source_format = @route[:metadata][:format]
          output_format = @route[:metadata][:format]
          
          if source_format == 'webp'
            img = Vips::Image.new_from_buffer(data, '')
            data = img.write_to_buffer('.png')
          end
          
          data = TerrainDownsampleFFI.downsample_png(data, target_size, encoding, method)
          
          if output_format == 'webp'
            data = convert_to_webp(data)
          end
        rescue => e
          DatabaseManager.record_miss(@route, z, x, y, 'image_processing_error', "Image processing error: #{e.message}", 500, data)
          LOGGER.warn("Image processing error for #{z}/#{x}/#{y}: #{e}")
          return false
        end
      elsif @route[:webp_config] && @route[:source_format] == 'png'
        begin
          data = convert_to_webp(data)
        rescue => e
          DatabaseManager.record_miss(@route, z, x, y, 'webp_conversion_error', "WebP conversion error: #{e.message}", 500, data)
          return false
        end
      end

      @route[:db][:tiles].insert_conflict(
        target: [:zoom_level, :tile_column, :tile_row],
        update: { tile_data: Sequel[:excluded][:tile_data] }
      ).insert(
        zoom_level: z,
        tile_column: x,
        tile_row: tms_y(z, y),
        tile_data: Sequel.blob(data)
      )
      true
    rescue => e
      DatabaseManager.record_miss(@route, z, x, y, 'fetch_error', "Background fetch error: #{e.message}", 500, nil)
      LOGGER.warn("Background fetch error for #{z}/#{x}/#{y}: #{e}")
      false
    end
  end

  def get_headers
    config_headers = @route[:headers]&.dig(:request) || {}

    browser_headers = {
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

    browser_headers.merge(config_headers)
  end

  def tile_exists?(x, y, z)
    @route[:db][:tiles].where(zoom_level: z, tile_column: x, tile_row: tms_y(z, y)).get(1)
  end

  def calculate_delay
    base_delay = 86400.0 / (@config[:daily_limit] || 1000)
    base_delay * (0.8 + rand * 0.4)
  end

  def get_bounds_for_zoom(z)
    bounds_str = @config[:bounds] || @route.dig(:metadata, :bounds) || "-180,-85.0511,180,85.0511"
    west, south, east, north = bounds_str.split(',').map(&:to_f)

    [
      [(west + 180) / 360 * (1 << z), 0].max.floor,
      [(1 - Math.log(Math.tan(north * Math::PI / 180) + 1 / Math.cos(north * Math::PI / 180)) / Math::PI) / 2 * (1 << z), 0].max.floor,
      [(east + 180) / 360 * (1 << z), (1 << z) - 1].min.floor,
      [(1 - Math.log(Math.tan(south * Math::PI / 180) + 1 / Math.cos(south * Math::PI / 180)) / Math::PI) / 2 * (1 << z), (1 << z) - 1].min.floor
    ]
  end

  def load_progress(z)
    row = @route[:db][:tile_scan_progress].where(source: @source_name, zoom_level: z).first

    if row && row[:last_scan_date] == Date.today.to_s
      @tiles_today = [@tiles_today, row[:tiles_today]].max
      { x: row[:last_x], y: row[:last_y] }
    else
      { x: 0, y: 0 }
    end
  end

  def save_progress(x, y, z)
    @route[:db][:tile_scan_progress].insert_conflict(
      target: [:source, :zoom_level],
      update: {
        last_x: Sequel[:excluded][:last_x],
        last_y: Sequel[:excluded][:last_y],
        tiles_today: Sequel[:excluded][:tiles_today],
        last_scan_date: Sequel[:excluded][:last_scan_date]
      }
    ).insert(
      source: @source_name,
      zoom_level: z,
      last_x: x,
      last_y: y,
      tiles_today: @tiles_today,
      last_scan_date: Date.today.to_s
    )
  rescue => e
    LOGGER.warn("Failed to save progress: #{e}")
  end

  def load_todays_progress
    today = Date.today.to_s
    total = @route[:db][:tile_scan_progress]
              .where(source: @source_name, last_scan_date: today)
              .sum(:tiles_today) || 0
    @tiles_today = total
  end

  def tms_y(z, y)
    (1 << z) - 1 - y
  end

  def convert_to_webp(data)
    webp_config = @route[:webp_config]
    lossless = webp_config[:lossless].nil? ? true : webp_config[:lossless]
    params = lossless ? { lossless: true, effort: webp_config[:effort]} : { lossless: false, Q: webp_config[:quality]}
    
    Vips::Image.new_from_buffer(data, '').write_to_buffer('.webp', **params)
  end

  def update_status(zoom_level, status)
    @route[:db][:tile_scan_progress].where(source: @source_name, zoom_level: zoom_level).update(status: status)
  rescue => e
    LOGGER.warn("Failed to update status for zoom #{zoom_level}: #{e}")
  end

  def update_all_statuses(status)
    @route[:db][:tile_scan_progress].where(source: @source_name).update(status: status)
  rescue => e
    LOGGER.warn("Failed to update all statuses: #{e}")
  end

  def update_active_status(status)
    @route[:db][:tile_scan_progress].where(source: @source_name, status: 'active').update(status: status)
  rescue => e
    LOGGER.warn("Failed to update active status: #{e}")
  end

  def initialize_zoom_progress
    start_zoom = @route[:minzoom] || 1
    end_zoom = @config[:max_scan_zoom] || 20

    (start_zoom..end_zoom).each do |z|
      existing = @route[:db][:tile_scan_progress].where(source: @source_name, zoom_level: z).first
      
      if existing && existing[:status] == 'error'
        reset_zoom_progress(z)
        LOGGER.info("Reset error status for zoom #{z} of #{@source_name} on startup")
      else
        @route[:db][:tile_scan_progress].insert_conflict(
          target: [:source, :zoom_level]
        ).insert(
          source: @source_name,
          zoom_level: z,
          last_x: 0,
          last_y: 0,
          tiles_today: 0,
          last_scan_date: nil,
          status: 'waiting'
        )
      end
    end
  rescue => e
    LOGGER.warn("Failed to initialize zoom progress: #{e}")
  end

  def zoom_complete?(z)
    expected = expected_tiles_count(z)
    actual_tiles = @route[:db][:tiles].where(zoom_level: z).count

    row = @route[:db][:tile_scan_progress].where(source: @source_name, zoom_level: z).first
    current_status = row&.dig(:status)

    if actual_tiles >= expected
      true
    elsif current_status == 'completed' && actual_tiles < expected
      reset_zoom_progress(z)
      false
    elsif ['active', 'stopped'].include?(current_status)
      false
    else
      reset_zoom_progress(z)
      false
    end
  end

  def expected_tiles_count(z)
    bounds = get_bounds_for_zoom(z)
    return 0 unless bounds

    min_x, min_y, max_x, max_y = bounds
    (max_x - min_x + 1) * (max_y - min_y + 1)
  end

  def cleanup_zoom_misses(z)
    cutoff_time = Time.now.to_i - (@route[:miss_timeout] || 300)
    @route[:db][:misses].where(zoom_level: z, ts: 0..cutoff_time).delete
  end

  def reset_zoom_progress(z)
    @route[:db][:tile_scan_progress].where(source: @source_name, zoom_level: z).update(
      last_x: 0,
      last_y: 0,
      status: 'waiting'
    )
    LOGGER.info("Reset progress for zoom #{z} of #{@source_name}")
  rescue => e
    LOGGER.warn("Failed to reset progress for zoom #{z}: #{e}")
  end
end
