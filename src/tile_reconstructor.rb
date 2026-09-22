require 'vips'
require 'sequel'
require 'set'
require 'time'
require_relative 'ext/terrain_downsample_extension'
require_relative 'vips_tile_validator'
require_relative 'tile_persistence'

class TileReconstructor
  KERNELS = %i[nearest linear cubic mitchell lanczos2 lanczos3].freeze # Vips interpolation kernels
  TERRAIN_ENCODINGS = %w[mapbox terrarium].freeze # Supported terrain RGB encodings
  TERRAIN_METHODS = %w[average nearest maximum].freeze # Terrain downsampling methods

  def initialize(route, source_name)
    @route = route
    @source_name = source_name
    @running = false
    @reconstruction_thread = nil
    @scheduler_thread = nil
    @last_run = nil
    @schedule_time = parse_schedule_time
    @transparent_tile_data = nil
  end

  def start_scheduler
    return unless @schedule_time

    @scheduler_thread = Thread.new do
      loop do
        sleep 60

        begin
          check_and_run_scheduled if should_run_now?
        rescue => e
          LOGGER.error("event=reconstruction_scheduler_error source=#{@source_name} error=#{e.message}")
        end
      end
    end

    LOGGER.info("TileReconstructor: scheduler started for #{@source_name}, scheduled at #{@schedule_time[:hour].to_s.rjust(2, '0')}:#{@schedule_time[:minute].to_s.rjust(2, '0')} UTC")
  end

  def stop_scheduler
    return unless @scheduler_thread

    @scheduler_thread.kill
    @scheduler_thread = nil
    LOGGER.info("TileReconstructor: scheduler stopped for #{@source_name}")
  end

  def start_reconstruction(mode)
    return false if running?

    @reconstruction_mode = mode
    @running = true
    @reconstruction_thread = Thread.new do
      begin
        @last_run = Time.now.utc if run_reconstruction
      rescue => e
        LOGGER.error("event=reconstruction_error source=#{@source_name} mode=#{@reconstruction_mode} error=#{e.message}")
        LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
      ensure
        @running = false
      end
    end

    true
  end

  def running?
    @running && @reconstruction_thread&.alive?
  end

  def status
    {
      running: running?,
      last_run: @last_run,
      schedule_time: @schedule_time
    }
  end

  private

  def save_last_run_timestamp(db, timestamp)
    db[:metadata].insert_conflict(
      target: :name,
      update: { value: Sequel[:excluded][:value] }
    ).insert(
      name: 'reconstruction_last_run',
      value: timestamp.iso8601(6)
    )
    true
  rescue => e
    LOGGER.warn("event=reconstruction_timestamp_save_error source=#{@source_name} error=#{e.message}")
    false
  end

  def get_last_run_timestamp(db)
    timestamp_str = db[:metadata].where(name: 'reconstruction_last_run').get(:value)
    return nil unless timestamp_str

    Time.parse(timestamp_str)
  rescue => e
    LOGGER.warn("event=reconstruction_timestamp_load_error source=#{@source_name} error=#{e.message}")
    nil
  end

  # Parses schedule time from config, returns {hour:, minute:} or nil
  def parse_schedule_time
    time_str = @route.dig(:gap_filling, :schedule, :time) || @route.dig(:gap_filling, :schedule, 'time')
    return nil unless time_str

    hour, minute = time_str.split(':').map(&:to_i)
    { hour: hour, minute: minute }
  end

  def should_run_now?
    return false unless @schedule_time
    now = Time.now.utc
    now.hour == @schedule_time[:hour] && now.min == @schedule_time[:minute]
  end

  def check_and_run_scheduled
    return if @last_run && @last_run.to_date >= Time.now.utc.to_date

    LOGGER.info("Starting scheduled reconstruction for #{@source_name}")
    start_reconstruction
  end

  # Main reconstruction loop: processes all zoom levels from maxzoom-1 to minzoom
  def run_reconstruction
    otl_span('reconstruction.run', { source: @source_name, mode: @reconstruction_mode }) do |span|
      db = @route[:db]
      minzoom = @route[:minzoom]
      maxzoom = @route[:maxzoom]

      start_zoom = maxzoom - 1
      return if start_zoom < minzoom

      span&.add_attributes(minzoom: minzoom, maxzoom: maxzoom, start_zoom: start_zoom)
      downsample_opts = build_downsample_opts(@route)

      last_run_time = @reconstruction_mode == :full ? nil : get_last_run_timestamp(db)
      run_cutoff = Time.now.utc - 1
      mode_name = @reconstruction_mode == :full ? "full rebuild" : (last_run_time ? "incremental (last run: #{last_run_time.iso8601})" : "full")
      LOGGER.info("TileReconstructor: starting #{mode_name} gap filling for #{@source_name} from zoom #{start_zoom} to #{minzoom}")

      successful = true
      @run_dirty_tiles_by_zoom = Hash.new { |hash, zoom| hash[zoom] = Set.new }
      start_zoom.downto(minzoom) do |z|
        unless @running
          successful = false
          break
        end

        begin
          zoom_successful = process_zoom_level(z, db, downsample_opts, minzoom, maxzoom, last_run_time, run_cutoff)
          successful &&= zoom_successful
        rescue => e
          successful = false
          LOGGER.error("event=reconstruction_zoom_error source=#{@source_name} zoom=#{z} error=#{e.message}")
          LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
        end
      end

      successful &&= save_last_run_timestamp(db, run_cutoff)

      if successful
        LOGGER.info("TileReconstructor: gap filling completed for #{@source_name}")
      else
        LOGGER.warn("event=reconstruction_incomplete source=#{@source_name} mode=#{@reconstruction_mode}")
      end

      successful
    ensure
      @run_dirty_tiles_by_zoom = nil
    end
  end

  def process_zoom_level(z, db, downsample_opts, minzoom, maxzoom, last_run_time = nil, run_cutoff = nil)
    otl_span('reconstruction.zoom', { source: @source_name, zoom: z }) do |span|
      parent_z = z - 1
      return true if parent_z < minzoom

      LOGGER.info("TileReconstructor: processing zoom #{z} -> #{parent_z}")

      all_tiles_z = load_tiles_for_zoom(z, db, last_run_time, run_cutoff)
      pending_parents = load_pending_parent_coords(parent_z, db)
      return true if all_tiles_z.empty? && pending_parents.empty?

      log_msg = last_run_time ? "loaded #{all_tiles_z.size} tiles for zoom #{z} (filtered by timestamp)" : "loaded #{all_tiles_z.size} tiles for zoom #{z}"
      LOGGER.info("TileReconstructor: #{log_msg}")

      parent_coords_set = calculate_parent_coords(all_tiles_z)
      parent_coords_set.merge(pending_parents)
      LOGGER.info("TileReconstructor: calculated #{parent_coords_set.size} unique parents for zoom #{parent_z}")

      processed_count = 0
      generated_count = 0
      invalid_tiles_coords = []
      error_count = 0

      parent_coords_set.each do |parent_coords|
        break unless @running

        begin
          generated, invalid_coords = process_parent(parent_coords, z, parent_z, db, downsample_opts)
          generated_count += 1 if generated
          invalid_tiles_coords.concat(invalid_coords) if invalid_coords.any?
          processed_count += 1
        rescue => e
          error_count += 1
          LOGGER.warn(
            "event=reconstruction_parent_error source=#{@source_name} zoom=#{parent_z} " \
            "x=#{parent_coords[0]} y=#{parent_coords[1]} error=#{e.message}"
          )
        end
      end

      cleanup_successful = invalid_tiles_coords.empty? || cleanup_invalid_tiles(invalid_tiles_coords, db)

      span&.add_attributes(
        parent_zoom: parent_z,
        loaded_tiles: all_tiles_z.size,
        parents: parent_coords_set.size,
        processed: processed_count,
        generated: generated_count,
        invalid: invalid_tiles_coords.size,
        errors: error_count
      )
      LOGGER.info(
        "event=reconstruction_zoom_summary source=#{@source_name} zoom=#{z} " \
        "parent_zoom=#{parent_z} processed=#{processed_count} generated=#{generated_count} " \
        "invalid=#{invalid_tiles_coords.size} errors=#{error_count}"
      )

      error_count.zero? && cleanup_successful
    end
  end

  # Processes single parent tile: loads parent + children, validates, decides, generates
  # Returns: [generated, invalid_tiles_coords] where generated is true/false and invalid_tiles_coords is array of invalid child tiles
  def process_parent(parent_coords, z, parent_z, db, downsample_opts)
    px, py = parent_coords
    child_coords = calculate_child_coords(px, py)

    parent_tile, children_tiles = load_parent_and_children(px, py, z, parent_z, child_coords, db)
    parent_validation = validate_parent_tile(parent_tile)
    # parent_valid should be true only for :valid and :partial_transparent
    # false for :transparent, :invalid, :corrupted, or nil
    parent_valid = [:valid, :partial_transparent].include?(parent_validation)
    parent_partial_transparency = parent_validation == :partial_transparent

    children_data_array, used_count, invalid_tiles_coords = validate_children_tiles(children_tiles, child_coords)

    if parent_validation == :valid && parent_tile&.dig(:generated) == TilePersistence::PENDING_RECONSTRUCTION && used_count > 0
      clear_pending_generation_state(parent_tile, used_count, db)
    end

    return [false, invalid_tiles_coords] unless should_generate_parent?(parent_tile, parent_valid, used_count, parent_partial_transparency)

    generated = generate_and_save_parent(px, py, parent_z, children_data_array, used_count, downsample_opts, db, parent_tile, parent_validation)
    [generated, invalid_tiles_coords]
  end

  def load_tiles_for_zoom(z, db, last_run_time = nil, run_cutoff = nil)
    query = db[:tiles].where(zoom_level: z)

    if last_run_time
      last_run_utc = last_run_time.utc
      conditions = [
        Sequel.&(
          Sequel[:updated_at] > last_run_utc,
          run_cutoff ? Sequel[:updated_at] <= run_cutoff.utc : Sequel.lit('1 = 1')
        ),
        Sequel[:generated] => TilePersistence::PENDING_RECONSTRUCTION
      ]
      query = query.where { Sequel.|(*conditions) }
    end

    tiles = query.select(:tile_column, :tile_row, :generated).to_a
    known_coords = tiles.to_h { |tile| [[tile[:tile_column], tile[:tile_row]], true] }

    @run_dirty_tiles_by_zoom&.fetch(z, Set.new)&.each do |x, y|
      tiles << { tile_column: x, tile_row: y } unless known_coords[[x, y]]
    end

    tiles
  end

  def load_pending_parent_coords(parent_z, db)
    db[:tiles]
      .where(zoom_level: parent_z, generated: TilePersistence::PENDING_RECONSTRUCTION)
      .select_map([:tile_column, :tile_row])
  end

  def calculate_parent_coords(all_tiles_z)
    parent_coords_set = Set.new
    all_tiles_z.each do |tile|
      parent_coords_set.add([tile[:tile_column] / 2, tile[:tile_row] / 2])
    end
    parent_coords_set
  end

  def calculate_child_coords(px, py)
    [
      [2 * px, 2 * py],
      [2 * px + 1, 2 * py],
      [2 * px, 2 * py + 1],
      [2 * px + 1, 2 * py + 1]
    ]
  end

  # Loads parent and children from database in a single query
  def load_parent_and_children(px, py, z, parent_z, child_coords, db)
    parent_condition = Sequel.&(
      Sequel[:zoom_level] => parent_z,
      Sequel[:tile_column] => px,
      Sequel[:tile_row] => py
    )

    child_conditions = child_coords.map do |cx, cy|
      Sequel.&(
        Sequel[:zoom_level] => z,
        Sequel[:tile_column] => cx,
        Sequel[:tile_row] => cy
      )
    end

    all_tiles = db[:tiles].where { Sequel.|(parent_condition, *child_conditions) }
                          .select(:zoom_level, :tile_column, :tile_row, :tile_data, :generated)
                          .to_a

    parent_tile = all_tiles.find { |t| t[:zoom_level] == parent_z && t[:tile_column] == px && t[:tile_row] == py }
    children_tiles = all_tiles.select { |t| t[:zoom_level] == z }

    [parent_tile, children_tiles]
  end

  def validate_parent_tile(parent_tile)
    return nil unless parent_tile
    return :invalid if parent_tile[:generated] == -1

    VipsTileValidator.validate(parent_tile[:tile_data], check_transparency: true)
  end

  def validate_children_tiles(children_tiles, child_coords)
    children_data_array = [nil, nil, nil, nil]
    used_count = 0
    invalid_tiles_coords = []

    children_tiles.each do |tile|
      coord_key = [tile[:tile_column], tile[:tile_row]]
      idx = child_coords.index(coord_key)
      next unless idx
      next if tile[:generated] == -1

      validation = VipsTileValidator.validate(tile[:tile_data], check_transparency: true)
      if [:valid, :partial_transparent].include?(validation)
        children_data_array[idx] = tile[:tile_data]
        used_count += 1
      elsif [:transparent, :corrupted].include?(validation)
        invalid_tiles_coords << [tile[:zoom_level], tile[:tile_column], tile[:tile_row], validation]
      end
    end

    [children_data_array, used_count, invalid_tiles_coords]
  end

  def should_generate_parent?(parent_tile, parent_valid, used_count, parent_partial_transparency = false)
    return false if used_count == 0

    parent_tile.nil? || !parent_valid || parent_partial_transparency
  end

  def generate_and_save_parent(px, py, parent_z, children_data_array, used_count, downsample_opts, db, parent_tile, parent_validation)
    child_data = send(downsample_opts[:method], children_data_array, **downsample_opts[:args])
    raise 'Downsampling returned no tile data' unless child_data

    new_data = if parent_validation == :partial_transparent && parent_tile
                 composite_parent_over_child(parent_tile[:tile_data], child_data, **composite_output_options(downsample_opts[:args]))
               else
                 child_data
               end

    raise 'Compositing returned no tile data' unless new_data

    existing_data = parent_tile && blob_to_string(parent_tile[:tile_data])
    if existing_data == new_data
      clear_pending_generation_state(parent_tile, used_count, db)
      return false
    end

    db.transaction do
      db[:tiles].insert_conflict(
        target: [:zoom_level, :tile_column, :tile_row],
        update: {
          tile_data: Sequel[:excluded][:tile_data],
          generated: Sequel[:excluded][:generated],
          updated_at: Sequel.lit("datetime('now', 'utc')")
        }
      ).insert(
        zoom_level: parent_z,
        tile_column: px,
        tile_row: py,
        tile_data: Sequel.blob(new_data),
        generated: used_count,
        updated_at: Sequel.lit("datetime('now', 'utc')")
      )
    end
    @run_dirty_tiles_by_zoom&.[](parent_z)&.add([px, py])

    true
  rescue => e
    raise "Failed to generate tile #{parent_z}/#{px}/#{py}: #{e.message}"
  end

  def blob_to_string(blob)
    return blob if blob.is_a?(String)

    blob.respond_to?(:read) ? blob.read : blob.to_s
  end

  def clear_pending_generation_state(parent_tile, used_count, db)
    return if parent_tile[:generated] == used_count

    db[:tiles].where(
      zoom_level: parent_tile[:zoom_level],
      tile_column: parent_tile[:tile_column],
      tile_row: parent_tile[:tile_row]
    ).update(generated: used_count)
  end

  def composite_output_options(downsample_args)
    downsample_args.except(:kernel, :encoding, :method)
  end

  def cleanup_invalid_tiles(invalid_tiles_coords, db)
    return true if invalid_tiles_coords.empty?

    processed_count = 0
    error_count = 0

    invalid_tiles_coords.each do |z, x, y, validation_status|
      begin
        db.transaction do
          db[:tiles].where(
            zoom_level: z,
            tile_column: x,
            tile_row: y
          ).delete

          # Create record in misses
          reason = validation_status.to_s
          db[:misses].insert_conflict(
            target: [:zoom_level, :tile_column, :tile_row],
            update: {
              ts: Sequel[:excluded][:ts],
              reason: Sequel[:excluded][:reason],
              details: Sequel[:excluded][:details],
              status: Sequel[:excluded][:status]
            }
          ).insert(
            zoom_level: z,
            tile_column: x,
            tile_row: y,
            ts: Time.now.to_i,
            reason: reason,
            details: "Tile is #{validation_status}",
            status: 200,
            response_body: nil
          )
        end
        processed_count += 1
      rescue => e
        error_count += 1
        LOGGER.warn("event=reconstruction_cleanup_invalid_error source=#{@source_name} zoom=#{z} x=#{x} y=#{y} error=#{e.message}")
      end
    end

    LOGGER.info("event=reconstruction_cleanup_invalid_summary source=#{@source_name} processed=#{processed_count} errors=#{error_count}")
    error_count.zero?
  end


  def composite_parent_over_child(parent_data, child_data, format:, **output_options)
    parent_img = Vips::Image.new_from_buffer(parent_data, '')
    child_img = Vips::Image.new_from_buffer(child_data, '')

    parent_img = parent_img.bandjoin(255) if parent_img.bands < 4
    child_img = child_img.bandjoin(255) if child_img.bands < 4

    result = child_img.composite2(parent_img, :over)
    result.write_to_buffer(".#{format}", **output_options)
  end

  def build_downsample_opts(route)
    encoding = route.dig(:metadata, :encoding)
    gap_filling = route[:gap_filling]
    minzoom = route[:minzoom]
    output_format_config = gap_filling[:output_format].transform_keys(&:to_sym)
    format = output_format_config[:type]

    if TERRAIN_ENCODINGS.include?(encoding)
      method = gap_filling[:terrain_method]
      args = { encoding: encoding, method: method, format: format }
      args[:effort] = output_format_config[:effort] || 4 if format == 'webp'

      { method: :downsample_terrain_tiles, args: args, minzoom: minzoom }
    else
      kernel = gap_filling[:raster_method].to_sym
      vips_options = output_format_config.except(:type)
      vips_options[:Q] = vips_options.delete(:quality) if format == 'webp' && vips_options.key?(:quality)

      { method: :downsample_raster_tiles, args: { format: format, kernel: kernel, **vips_options }, minzoom: minzoom }
    end
  end

  # Downsamples 4 raster tiles into one using Vips
  # Missing tiles are replaced with transparent placeholders
  def downsample_raster_tiles(children_data, format: 'png', kernel: :linear, **output_options)
    raise ArgumentError, "Expected 4 tiles, got #{children_data.size}" unless children_data.size == 4
    raise ArgumentError, "Unknown kernel: #{kernel}" unless KERNELS.include?(kernel)

    # Fill missing tiles with transparent placeholders
    filled_children = fill_missing_tiles(children_data, format)
    return nil if filled_children.all?(&:nil?)

    combined = combine_4_tiles(filled_children)
    combined.resize(0.5, kernel: kernel).write_to_buffer(".#{format}", **output_options)
  end

  # Downsamples 4 terrain tiles with elevation-aware algorithms
  # Missing tiles are replaced with transparent placeholders
  def downsample_terrain_tiles(children_data, encoding: 'mapbox', method: 'average', format:, effort: nil)
    raise ArgumentError, "Expected 4 tiles, got #{children_data.size}" unless children_data.size == 4
    raise ArgumentError, "Unknown encoding: #{encoding}" unless TERRAIN_ENCODINGS.include?(encoding)
    raise ArgumentError, "Unknown method: #{method}" unless TERRAIN_METHODS.include?(method)
    raise ArgumentError, "Unknown format: #{format}" unless %w[png webp].include?(format)

    # Fill missing tiles with transparent placeholders
    filled_children = fill_missing_tiles(children_data, format)
    return nil if filled_children.all?(&:nil?)

    combined = combine_4_tiles(filled_children)
    combined_png = combined.write_to_buffer('.png')
    result_png = TerrainDownsampleFFI.downsample_png(combined_png, 256, encoding, method)

    return result_png if format == 'png'
    Vips::Image.new_from_buffer(result_png, '').write_to_buffer('.webp', lossless: true, effort: effort || 4)
  end

  def combine_4_tiles(children_data)
    images = children_data.map { |d| Vips::Image.new_from_buffer(d, '') }

    # If any tile has alpha channel, add alpha to all RGB tiles to preserve transparency
    has_alpha = images.any? { |img| img.bands == 4 }
    images.map! { |img| img.bands < 4 ? img.bandjoin(255) : img } if has_alpha

    top_row = images[0].join(images[1], :horizontal)
    bottom_row = images[2].join(images[3], :horizontal)
    bottom_row.join(top_row, :vertical) # TMS: bottom first (Y increases southward)
  rescue Vips::Error => e
    raise ArgumentError, "Failed to combine tiles: #{e.message}"
  end

  # Fills missing tiles (nil values) with transparent placeholders
  # Also replaces corrupted tiles that vips cannot load
  def fill_missing_tiles(children_data, format)
    # Find first valid tile as reference
    reference_img = nil
    children_data.compact.each do |tile_data|
      reference_img = Vips::Image.new_from_buffer(tile_data, '') rescue next
      break
    end

    return [nil, nil, nil, nil] unless reference_img

    children_data.map do |tile_data|
      if tile_data
        Vips::Image.new_from_buffer(tile_data, '')
        tile_data
      else
        create_transparent_tile(reference_img, format)
      end
    rescue Vips::Error
      create_transparent_tile(reference_img, format)
    end
  end

  # Creates transparent tile matching reference image properties
  def create_transparent_tile(reference_img, format)
    return @transparent_tile_data if @transparent_tile_data

    transparent = Vips::Image.black(reference_img.width, reference_img.height)

    # Add color channels if needed (RGB or single band)
    transparent = transparent.bandjoin([0, 0]) if reference_img.bands >= 3

    # Add transparent alpha channel
    transparent = transparent.bandjoin(0)

    @transparent_tile_data = transparent.write_to_buffer(".#{format}")
  rescue Vips::Error => e
    LOGGER.warn("event=reconstruction_transparent_tile_error source=#{@source_name} error=#{e.message}")
    nil
  end
end
