require 'vips'
require 'sequel'
require 'set'
require_relative 'ext/terrain_downsample_extension'

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
          LOGGER.error("TileReconstructor scheduler error for #{@source_name}: #{e.message}")
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

  def start_reconstruction
    return false if running?

    @running = true
    @reconstruction_thread = Thread.new do
      begin
        run_reconstruction
        @last_run = Time.now.utc
      rescue => e
        LOGGER.error("TileReconstructor error for #{@source_name}: #{e.message}")
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
    db = @route[:db]
    minzoom = @route[:minzoom]
    maxzoom = @route[:maxzoom]

    start_zoom = maxzoom - 1
    return if start_zoom < minzoom

    downsample_opts = build_downsample_opts(@route)

    LOGGER.info("TileReconstructor: starting gap filling for #{@source_name} from zoom #{start_zoom} to #{minzoom}")

    start_zoom.downto(minzoom) do |z|
      break unless @running

      begin
        process_zoom_level(z, db, downsample_opts, minzoom, maxzoom)
      rescue => e
        LOGGER.error("TileReconstructor: failed to process zoom #{z} for #{@source_name}: #{e.message}")
        LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
      end
    end

    LOGGER.info("TileReconstructor: gap filling completed for #{@source_name}")
  end

  otl_def :run_reconstruction

  def process_zoom_level(z, db, downsample_opts, minzoom, maxzoom)
    parent_z = z - 1
    return if parent_z < minzoom

    LOGGER.info("TileReconstructor: processing zoom #{z} -> #{parent_z}")

    all_tiles_z = load_tiles_for_zoom(z, db)
    return if all_tiles_z.empty?

    LOGGER.info("TileReconstructor: loaded #{all_tiles_z.size} tiles for zoom #{z}")

    parent_coords_set = calculate_parent_coords(all_tiles_z)
    LOGGER.info("TileReconstructor: calculated #{parent_coords_set.size} unique parents for zoom #{parent_z}")

    processed_count = 0
    generated_count = 0

    parent_coords_set.each do |parent_coords|
      break unless @running

      begin
        generated_count += 1 if process_parent(parent_coords, z, parent_z, db, downsample_opts, minzoom)
        processed_count += 1
      rescue => e
        LOGGER.warn("TileReconstructor: failed to process parent #{parent_z}/#{parent_coords[0]}/#{parent_coords[1]}: #{e.message}")
      end
    end

    LOGGER.info("TileReconstructor: zoom #{z} -> #{parent_z} completed: processed #{processed_count}, generated #{generated_count}")
  end

  otl_def :process_zoom_level

  # Processes single parent tile: loads parent + children, validates, decides, generates
  # Returns: true if tile was generated/updated, false otherwise
  def process_parent(parent_coords, z, parent_z, db, downsample_opts, minzoom)
    px, py = parent_coords
    child_coords = calculate_child_coords(px, py)

    parent_tile, children_tiles, grandparent_tile = load_parent_and_children(px, py, z, parent_z, child_coords, db, minzoom)
    parent_valid = validate_parent_tile(parent_tile)

    children_data_array, used_count = validate_children_tiles(children_tiles, child_coords)

    return false unless should_generate_parent?(parent_tile, parent_valid, used_count)

    generate_and_save_parent(px, py, parent_z, children_data_array, used_count, downsample_opts, db, minzoom, grandparent_tile)
  end

  # Loads all tiles for a zoom level (coordinates only, no blob)
  def load_tiles_for_zoom(z, db)
    db[:tiles].where(zoom_level: z)
              .select(:tile_column, :tile_row, :generated)
              .to_a
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

  # Loads parent, children, and grandparent tiles from database in single query
  # Grandparent is loaded without blob (only generated) for quality regeneration marking
  # Returns: [parent_tile, children_tiles, grandparent_tile]
  def load_parent_and_children(px, py, z, parent_z, child_coords, db, minzoom)
    grandparent_z = parent_z - 1
    gpx = px / 2
    gpy = py / 2

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

    conditions = [parent_condition, *child_conditions]

    if grandparent_z >= minzoom
      grandparent_condition = Sequel.&(
        Sequel[:zoom_level] => grandparent_z,
        Sequel[:tile_column] => gpx,
        Sequel[:tile_row] => gpy
      )
      conditions << grandparent_condition
    end

    all_tiles = db[:tiles].where { Sequel.|(*conditions) }
                          .select(:zoom_level, :tile_column, :tile_row, :tile_data, :generated)
                          .to_a

    parent_tile = all_tiles.find { |t| t[:zoom_level] == parent_z && t[:tile_column] == px && t[:tile_row] == py }
    children_tiles = all_tiles.select { |t| t[:zoom_level] == z }
    grandparent_tile = grandparent_z >= minzoom ? all_tiles.find { |t| t[:zoom_level] == grandparent_z && t[:tile_column] == gpx && t[:tile_row] == gpy } : nil

    [parent_tile, children_tiles, grandparent_tile]
  end

  def validate_parent_tile(parent_tile)
    return false unless parent_tile

    case parent_tile[:generated]
    when 0
      validation = validate_tile(parent_tile[:tile_data])
      validation == :valid
    when 1..4
      true
    when -1
      false
    else
      true
    end
  end

  def validate_children_tiles(children_tiles, child_coords)
    children_data_array = [nil, nil, nil, nil]
    used_count = 0

    children_tiles.each do |tile|
      coord_key = [tile[:tile_column], tile[:tile_row]]
      idx = child_coords.index(coord_key)
      next unless idx
      next if tile[:generated] == -1

      validation = validate_tile(tile[:tile_data])
      if validation == :valid
        children_data_array[idx] = tile[:tile_data]
        used_count += 1
      end
    end

    [children_data_array, used_count]
  end

  def should_generate_parent?(parent_tile, parent_valid, used_count)
    return false if used_count == 0

    if parent_tile.nil?
      true
    elsif parent_tile[:generated] == 0
      !parent_valid
    elsif parent_tile[:generated] == -1
      true
    elsif parent_tile[:generated] == -5
      true
    elsif (1..4).include?(parent_tile[:generated])
      used_count != parent_tile[:generated]
    else
      false
    end
  end

  def generate_and_save_parent(px, py, parent_z, children_data_array, used_count, downsample_opts, db, minzoom, grandparent_tile)
    new_data = send(downsample_opts[:method], children_data_array, **downsample_opts[:args])
    return false unless new_data

    db.transaction do
      db[:tiles].insert_conflict(
        target: [:zoom_level, :tile_column, :tile_row],
        update: {
          tile_data: Sequel[:excluded][:tile_data],
          generated: Sequel[:excluded][:generated]
        }
      ).insert(
        zoom_level: parent_z,
        tile_column: px,
        tile_row: py,
        tile_data: Sequel.blob(new_data),
        generated: used_count
      )

      mark_grandparent_for_regeneration(grandparent_tile, db) if grandparent_tile && grandparent_tile[:generated] != 0
    end

    true
  rescue => e
    LOGGER.warn("TileReconstructor: failed to generate tile #{parent_z}/#{px}/#{py}: #{e.message}")
    false
  end

  def mark_grandparent_for_regeneration(grandparent_tile, db)
    db[:tiles].where(
      zoom_level: grandparent_tile[:zoom_level],
      tile_column: grandparent_tile[:tile_column],
      tile_row: grandparent_tile[:tile_row]
    ).update(generated: -5)
  end

  def validate_tile(tile_data)
    return :corrupted unless tile_data
    return :corrupted if tile_data.nil?

    img = Vips::Image.new_from_buffer(tile_data, '')
    return :valid unless img.bands == 4

    # Check if all alpha channel values are 0 (fully transparent)
    alpha = img[3]
    alpha.max == 0 ? :transparent : :valid
  rescue Vips::Error
    :corrupted
  end

  def build_downsample_opts(route)
    encoding = route.dig(:metadata, :encoding)
    gap_filling = route[:gap_filling]
    minzoom = route[:minzoom]

    if TERRAIN_ENCODINGS.include?(encoding)
      method = gap_filling[:terrain_method]
      output_format_config = gap_filling[:output_format]
      format = output_format_config[:type]

      args = { encoding: encoding, method: method, format: format }
      args[:effort] = output_format_config[:effort] || 4 if format == 'webp'

      { method: :downsample_terrain_tiles, args: args, minzoom: minzoom }
    else
      output_format_config = gap_filling[:output_format]
      format = output_format_config[:type]
      kernel = gap_filling[:raster_method].to_sym

      vips_options = output_format_config.reject { |k, _| k == :type || k == 'type' }

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
    LOGGER.warn("TileReconstructor: failed to create transparent tile: #{e.message}")
    nil
  end
end
