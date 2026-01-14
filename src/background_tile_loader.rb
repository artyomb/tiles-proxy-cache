require 'vips'
require 'zlib'
require 'stringio'
require 'concurrent-ruby'
require_relative 'ext/terrain_downsample_extension'

class BackgroundTileLoader
  MAX_RETRY_ATTEMPTS = 15
  RETRY_JITTER = 0.2  # ±20%
  RETRY_BACKOFF_FACTOR = 2.5

  TRANSIENT_STATUS_CODES = [429, 500, 502, 503, 504].freeze
  CRITICAL_STATUS_CODES = [401, 403].freeze
  PERMANENT_STATUS_CODES = [204, 400, 404].freeze

  def initialize(route, source_name)
    @route = route
    @source_name = source_name
    @config = route[:autoscan] || {}
    @tiles_today = 0
    @tiles_processed = 0
    @current_progress = {}
    @cancel_token = nil
    @scan_future = nil
    @wal_task = nil

    setup_progress_table
    load_todays_progress
  end

  def start
    return unless @config[:enabled]
    return if running?

    LOGGER.info("Starting autoscan for #{@source_name}")
    initialize_zoom_progress

    @cancel_token = Concurrent::Promises.resolvable_event
    @scan_future = Concurrent::Promises.future_on(:io, @cancel_token) do |token|
      begin
        start_zoom = @route[:minzoom] || 1
        end_zoom = @config[:max_scan_zoom] || 20

        source_real_minzoom = @route.dig(:gap_filling, :source_real_minzoom)
        start_zoom = [start_zoom, source_real_minzoom].compact.max if source_real_minzoom

        (start_zoom..end_zoom).each { |z| scan_zoom_level(z, token) }
      rescue => e
        LOGGER.error("Autoscan error for #{@source_name}: #{e}")
        update_all_statuses('error')
      ensure
        update_active_status('stopped') unless e
      end
    end
  end

  def stop
    return unless running?

    update_active_status('stopped')
    @cancel_token&.resolve
    @scan_future&.wait(5)
    LOGGER.info("Stopped autoscan for #{@source_name}")
  end

  def enabled?
    @config[:enabled] == true
  end

  def running?
    @scan_future&.pending? == true
  end

  def stop_completely
    return false unless enabled?
    
    has_scan = running?
    has_wal = @wal_task&.running?
    return false unless has_scan || has_wal

    LOGGER.info("Stopping autoscan completely for #{@source_name} (including WAL checkpoint)")

    if has_scan
      update_active_status('stopped')
      @cancel_token&.resolve
      @scan_future&.wait(5)
      @scan_future = nil
    end

    if has_wal
      @wal_task.shutdown
      @wal_task.wait_for_termination(2)
      @wal_task = nil
    end

    LOGGER.info("Autoscan completely stopped for #{@source_name}")
    true
  end

  def restart
    return false unless enabled?
    
    if running?
      start_wal_checkpoint_thread unless @wal_task&.running?
      return true
    end

    LOGGER.info("Restarting autoscan for #{@source_name}")
    start
    start_wal_checkpoint_thread unless @wal_task&.running?
    true
  end

  def start_wal_checkpoint_thread
    return if @wal_task&.running?

    @wal_task = Concurrent::TimerTask.new(execution_interval: 15) do
      begin
        result = @route[:db].run "PRAGMA wal_checkpoint(PASSIVE)"
        if result&.is_a?(Array) && result[0] == 1
          @route[:db].run "PRAGMA wal_checkpoint(RESTART)"
        end
      rescue => e
        LOGGER.warn("WAL checkpoint error: #{e}")
      end
    end
    @wal_task.execute
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

  def scan_zoom_level(z, token)
    otl_span("scan_zoom_level", {source: @source_name, zoom: z}) do
      if zoom_complete?(z)
        LOGGER.info("Zoom #{z} already complete for #{@source_name}")
        update_status(z, 'completed')
        return
      end

      bounds = get_bounds_for_zoom(z)
      return unless bounds

      @current_progress[z] = load_progress(z)
      update_status(z, 'active')

      scan_zoom_grid(z, bounds, token)

      final_x = @current_progress[z]&.dig(:x) || 0
      final_y = @current_progress[z]&.dig(:y) || 0
      save_progress(final_x, final_y, z)
      
      if zoom_complete?(z)
        update_status(z, 'completed')
        LOGGER.info("Zoom #{z} marked as completed for #{@source_name}")
      else
        expected = expected_tiles_count(z)
        actual_tiles = @route[:db][:tiles].where(zoom_level: z).count
        errors = @route[:db][:misses].where(zoom_level: z).count
        remaining = expected - actual_tiles - errors
        LOGGER.error("Zoom #{z} grid scan finished but incomplete for #{@source_name}: actual=#{actual_tiles}, expected=#{expected}, errors=#{errors}, remaining=#{remaining}, running=#{running?}")
        update_status(z, 'error')
      end
    end
  end

  def scan_zoom_grid(z, bounds, token)
    _, min_y, max_x, max_y = bounds
    x, y = @current_progress[z].values_at(:x, :y)

    (x..max_x).each do |curr_x|
      start_y = curr_x == x ? y : min_y

      (start_y..max_y).each do |curr_y|
        return if token.resolved?

        @current_progress[z][:x] = curr_x
        @current_progress[z][:y] = curr_y

        result = fetch_tile(curr_x, curr_y, z, token)

        case result
        when :success
          @tiles_today += 1
          @tiles_processed += 1
          save_progress(curr_x, curr_y, z) if @tiles_processed % 10 == 0
          sleep calculate_delay

        when :permanent_error
          @tiles_processed += 1
          save_progress(curr_x, curr_y, z) if @tiles_processed % 10 == 0

        when :source_unavailable, :critical_stop
          LOGGER.error("Stopping scan for #{@source_name} at tile #{z}/#{curr_x}/#{curr_y}")
          return

        when :cancelled
          return
        end
      end
    end

    final_x = @current_progress[z]&.dig(:x)
    final_y = @current_progress[z]&.dig(:y)
    save_progress(final_x, final_y, z) if @tiles_processed % 10 != 0

    LOGGER.info("Completed zoom level #{z} for #{@source_name}")
  end

  def fetch_tile(x, y, z, token = nil)
    return :permanent_error if tile_exists?(x, y, z)

    attempts = 0

    while attempts < MAX_RETRY_ATTEMPTS
      attempts += 1
      return :cancelled if token&.resolved?

      result = perform_tile_fetch(x, y, z)

      if result[:success]
        save_tile_to_db(z, x, y, result[:data])
        return :success
      end

      error_class = classify_error(result[:status], result[:reason])

      case error_class
      when :critical
        handle_critical_error(result)
        return :critical_stop

      when :permanent
        record_permanent_miss(x, y, z, result)
        return :permanent_error

      when :transient
        if attempts >= MAX_RETRY_ATTEMPTS
          handle_source_unavailable(x, y, z, attempts)
          return :source_unavailable
        end

        delay = calculate_retry_delay(attempts + 1)

        if result[:status] == 429
          LOGGER.warn("Rate limit (429) hit for #{@source_name} at tile #{z}/#{x}/#{y}, retry #{attempts + 1}/#{MAX_RETRY_ATTEMPTS} after #{delay.round(1)}s - consider adjusting daily_limit in config")
        else
          LOGGER.warn("Tile #{z}/#{x}/#{y} failed: #{result[:reason]}, retry #{attempts + 1}/#{MAX_RETRY_ATTEMPTS} after #{delay.round(1)}s")
        end

        sleep(delay)
      end
    end

    :source_unavailable
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
    rows = @route[:db][:tile_scan_progress]
             .where(source: @source_name, last_scan_date: today)
             .select(:tiles_today)
             .all
    @tiles_today = rows.sum { |row| row[:tiles_today].to_i }
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
    @route[:db][:tile_scan_progress]
      .where(source: @source_name, status: 'active')
      .update(status: status)
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
    
    source_real_minzoom = @route.dig(:gap_filling, :source_real_minzoom)
    start_zoom = [start_zoom, source_real_minzoom].compact.max if source_real_minzoom

    (start_zoom..end_zoom).each do |z|
      existing = @route[:db][:tile_scan_progress].where(source: @source_name, zoom_level: z).first
      
      if existing && ['error', 'critical_error', 'source_unavailable'].include?(existing[:status])
        reset_zoom_progress(z)
        LOGGER.info("Reset #{existing[:status]} status for zoom #{z} of #{@source_name} on startup")
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
    errors = @route[:db][:misses].where(zoom_level: z).count
    processed = actual_tiles + errors

    row = @route[:db][:tile_scan_progress].where(source: @source_name, zoom_level: z).first
    current_status = row&.dig(:status)

    if processed >= expected
      true
    elsif current_status == 'completed' && processed < expected
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

  def perform_tile_fetch(x, y, z)
    target_url = @route[:target].gsub('{z}', z.to_s).gsub('{x}', x.to_s).gsub('{y}', y.to_s)
    target_url += "?#{URI.encode_www_form(@route[:query_params])}" if @route[:query_params]
    headers = get_headers

    begin
      response = @route[:client].get(target_url, nil, headers)

      if response.status == 204
        return {
          success: false,
          status: 204,
          reason: 'http_204',
          details: 'HTTP 204 No Content (tile does not exist)',
          body: nil
        }
      end

      unless response.success?
        return {
          success: false,
          status: response.status,
          reason: 'http_error',
          details: "HTTP #{response.status}",
          body: response.body
        }
      end

      data = response.body

      if response.headers['content-encoding']&.include?('gzip')
        data = Zlib::GzipReader.new(StringIO.new(data)).read rescue data
      end

      if @route[:source_format] == 'lerc'
        if response.headers['content-type']&.include?('text/html')
          return {
            success: false,
            status: 404,
            reason: 'arcgis_html_error',
            details: 'ArcGIS returned HTML error page',
            body: data
          }
        end

        begin
          decoded = LercFFI.lerc_to_mapbox_png(data)
          if decoded.nil?
            return {
              success: false,
              status: 404,
              reason: 'arcgis_nodata',
              details: 'LERC tile has no valid pixels (empty tile)',
              body: data
            }
          end
          data = decoded
        rescue => e
          return {
            success: false,
            status: 500,
            reason: 'lerc_decode_error',
            details: "LERC decode error: #{e.message}",
            body: data
          }
        end
      else
        content_type = response.headers['content-type']
        unless content_type&.include?('image/')
          return {
            success: false,
            status: 200,
            reason: 'invalid_content_type',
            details: "Content-Type: #{content_type}",
            body: data
          }
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
          return {
            success: false,
            status: 500,
            reason: 'image_processing_error',
            details: "Image processing error: #{e.message}",
            body: data
          }
        end
      elsif @route[:webp_config] && @route[:source_format] == 'png'
        begin
          data = convert_to_webp(data)
        rescue => e
          return {
            success: false,
            status: 500,
            reason: 'webp_conversion_error',
            details: "WebP conversion error: #{e.message}",
            body: data
          }
        end
      end

      { success: true, data: data }
    rescue => e
      {
        success: false,
        status: 500,
        reason: 'fetch_error',
        details: "Background fetch error: #{e.message}",
        body: nil
      }
    end
  end

  def save_tile_to_db(z, x, y, data)
    @route[:db][:tiles].insert_conflict(
      target: [:zoom_level, :tile_column, :tile_row],
      update: {
        tile_data: Sequel[:excluded][:tile_data],
        updated_at: Sequel.lit("datetime('now', 'utc')")
      }
    ).insert(
      zoom_level: z,
      tile_column: x,
      tile_row: tms_y(z, y),
      tile_data: Sequel.blob(data),
      updated_at: Sequel.lit("datetime('now', 'utc')")
    )

    if @route.dig(:gap_filling, :enabled)
      @route[:reconstructor]&.mark_parent_for_new_child(@route[:db], z, x, tms_y(z, y), @route[:minzoom])
    end
  end

  def record_permanent_miss(x, y, z, result)
    reason = "permanent:#{result[:reason]}"
    DatabaseManager.record_miss(@route, z, x, y, reason, result[:details], result[:status], result[:body])
  end

  def handle_critical_error(result)
    LOGGER.error("Critical error #{result[:status]} for #{@source_name}: #{result[:details]} - check credentials/access")
    update_all_statuses('critical_error')
  end

  def handle_source_unavailable(x, y, z, attempts)
    LOGGER.error("Source unavailable after #{attempts} retry attempts for tile #{z}/#{x}/#{y} of #{@source_name}")
    update_all_statuses('source_unavailable')
  end

  def classify_error(status, reason)
    return :critical if CRITICAL_STATUS_CODES.include?(status)
    return :permanent if PERMANENT_STATUS_CODES.include?(status)
    return :permanent if reason&.start_with?('permanent:')
    return :transient if TRANSIENT_STATUS_CODES.include?(status)
    return :transient if reason&.include?('network') || reason&.include?('timeout') || reason&.include?('refused')

    :permanent
  end

  def calculate_retry_delay(attempt)
    return 0 if attempt == 1
    
    base = [RETRY_BACKOFF_FACTOR ** (attempt - 2), 14400].min.to_i  # cap at 4 hours
    jitter = base * RETRY_JITTER * (rand * 2 - 1)
    base + jitter
  end
end
