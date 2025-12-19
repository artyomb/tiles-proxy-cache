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

  # Processes single zoom level (4 phases)
  def process_zoom_level(z, db, downsample_opts, minzoom, maxzoom)
    parent_z = z - 1
    return if parent_z < minzoom

    LOGGER.info("TileReconstructor: processing zoom #{z} -> #{parent_z}")

    children_data = prepare_generation_data(z, db, parent_z)
    return if children_data[:candidates].empty?

    _updated_tiles, invalid_tiles_set = generate_parent_tiles(
      children_data[:candidates], z, parent_z, db, downsample_opts, collect_invalid_tiles: true
    )

    successful_generations_set = regenerate_invalid_tiles_from_children(z, db, downsample_opts, invalid_tiles_set, maxzoom)

    regenerate_parents_of_successful_tiles(successful_generations_set, z, parent_z, db, downsample_opts, minzoom, children_data)

    LOGGER.debug("TileReconstructor: zoom #{z} -> #{parent_z} completed")
  end

  otl_def :process_zoom_level

  # Prepares generation data without loading blob data
  # Returns: { children_coords: Hash, parents_info: Hash, candidates: Set }
  def prepare_generation_data(z, db, parent_z)
    children_coords = {}
    db[:tiles].where(zoom_level: z).select(:tile_column, :tile_row, :generated).each do |tile|
      coords = [tile[:tile_column], tile[:tile_row]]
      children_coords[coords] = tile[:generated]
    end

    return { children_coords: {}, parents_info: {}, candidates: Set.new } if children_coords.empty?

    LOGGER.info("TileReconstructor: loaded #{children_coords.size} child tiles for zoom #{z}")

    # Calculate possible parents
    possible_parents = Set.new
    children_coords.each_key do |cx, cy|
      possible_parents.add([cx / 2, cy / 2])
    end

    # Load parents info
    parents_info = {}
    if possible_parents.any?
      possible_parents.to_a.each_slice(500) do |batch|
        conditions = batch.map { |px, py|
          Sequel.&(Sequel[:tile_column] => px, Sequel[:tile_row] => py)
        }
        db[:tiles].where(zoom_level: parent_z).where { Sequel.|(*conditions) }
                  .select(:tile_column, :tile_row, :generated).each do |tile|
          coords = [tile[:tile_column], tile[:tile_row]]
          parents_info[coords] = tile[:generated]
        end
      end
    end

    LOGGER.info("TileReconstructor: loaded info for #{parents_info.size} parent tiles for zoom #{parent_z}")

    candidates = build_generation_candidates(possible_parents, parents_info, children_coords.keys.to_set)

    LOGGER.info("TileReconstructor: built #{candidates.size} generation candidates")

    { children_coords: children_coords, parents_info: parents_info, candidates: candidates }
  end

  # Generates parent tiles from candidates
  # Returns: [updated_tiles, invalid_tiles_set]
  def generate_parent_tiles(candidates, z, parent_z, db, downsample_opts, collect_invalid_tiles: false)
    invalid_tiles_set = Set.new
    updated_tiles = Set.new

    candidates.each do |parent_coords|
      break unless @running

      px, py = parent_coords
      child_coords = [
        [2 * px, 2 * py],
        [2 * px + 1, 2 * py],
        [2 * px, 2 * py + 1],
        [2 * px + 1, 2 * py + 1]
      ]

      # Load 4 child tiles in one query
      conditions = child_coords.map { |cx, cy|
        Sequel.&(Sequel[:tile_column] => cx, Sequel[:tile_row] => cy)
      }
      children_tiles = db[:tiles].where(zoom_level: z).where { Sequel.|(*conditions) }
                                 .select(:tile_column, :tile_row, :tile_data, :generated).to_a

      # Validate and prepare children data
      children_data_array = [nil, nil, nil, nil]
      used_count = 0

      children_tiles.each do |tile|
        coord_key = [tile[:tile_column], tile[:tile_row]]
        idx = child_coords.index(coord_key)
        next unless idx

        next if tile[:generated] == -1

        validation = validate_tile(tile[:tile_data])
        case validation
        when :valid
          children_data_array[idx] = tile[:tile_data]
          used_count += 1
        when :transparent, :corrupted
          invalid_tiles_set.add(coord_key) if collect_invalid_tiles
        end
      end

      # Generate parent if at least 1 valid child
      next if used_count == 0

      begin
        new_data = send(downsample_opts[:method], children_data_array, **downsample_opts[:args])
        next unless new_data

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
        end

        updated_tiles.add([parent_z, px, py])
      rescue => e
        LOGGER.warn("TileReconstructor: failed to generate tile #{parent_z}/#{px}/#{py}: #{e.message}")
      end
    end

    batch_mark_parents_for_regeneration(updated_tiles, parent_z, downsample_opts[:minzoom], db) if updated_tiles.any?

    [updated_tiles, invalid_tiles_set]
  end

  # Regenerates invalid tiles from their children on higher zoom level
  # Returns: Set of successfully regenerated tile coordinates on zoom Z
  def regenerate_invalid_tiles_from_children(z, db, downsample_opts, invalid_tiles_set, maxzoom)
    return Set.new if invalid_tiles_set.empty?

    children_z = z + 1
    return Set.new if children_z > maxzoom

    successful_generations_set = Set.new

    invalid_tiles_set.each do |tile_coords|
      break unless @running

      tx, ty = tile_coords
      child_coords = [
        [2 * tx, 2 * ty],
        [2 * tx + 1, 2 * ty],
        [2 * tx, 2 * ty + 1],
        [2 * tx + 1, 2 * ty + 1]
      ]

      conditions = child_coords.map { |cx, cy|
        Sequel.&(Sequel[:tile_column] => cx, Sequel[:tile_row] => cy)
      }
      children_tiles = db[:tiles].where(zoom_level: children_z).where { Sequel.|(*conditions) }
                                 .select(:tile_column, :tile_row, :tile_data, :generated).to_a

      children_data_array = [nil, nil, nil, nil]
      used_count = 0

      children_tiles.each do |tile|
        coord_key = [tile[:tile_column], tile[:tile_row]]
        idx = child_coords.index(coord_key)
        next unless idx

        next if tile[:generated] == -1

        validation = validate_tile(tile[:tile_data])
        case validation
        when :valid
          children_data_array[idx] = tile[:tile_data]
          used_count += 1
        when :transparent, :corrupted
          # Skip invalid children
        end
      end

      # Generate replacement tile if at least 1 valid child
      next if used_count == 0

      begin
        new_data = send(downsample_opts[:method], children_data_array, **downsample_opts[:args])
        next unless new_data

        # Microtransaction: update invalid tile
        db.transaction do
          db[:tiles].insert_conflict(
            target: [:zoom_level, :tile_column, :tile_row],
            update: {
              tile_data: Sequel[:excluded][:tile_data],
              generated: Sequel[:excluded][:generated]
            }
          ).insert(
            zoom_level: z,
            tile_column: tx,
            tile_row: ty,
            tile_data: Sequel.blob(new_data),
            generated: used_count
          )
        end

        successful_generations_set.add(tile_coords)
      rescue => e
        LOGGER.warn("TileReconstructor: failed to regenerate invalid tile #{z}/#{tx}/#{ty}: #{e.message}")
      end
    end

    successful_generations_set
  end

  # Regenerates parent tiles for successfully regenerated tiles
  # Uses same logic as generate_parents_and_collect_invalid but only for specific parents
  def regenerate_parents_of_successful_tiles(successful_generations_set, z, parent_z, db, downsample_opts, minzoom, children_data)
    return if successful_generations_set.empty? || parent_z < minzoom

    parent_coords_set = Set.new
    successful_generations_set.each do |tx, ty|
      parent_coords_set.add([tx / 2, ty / 2])
    end

    children_coords = children_data[:children_coords].keys.to_set

    parents_info = {}
    if parent_coords_set.any?
      parent_coords_set.to_a.each_slice(500) do |batch|
        conditions = batch.map { |px, py|
          Sequel.&(Sequel[:tile_column] => px, Sequel[:tile_row] => py)
        }
        db[:tiles].where(zoom_level: parent_z).where { Sequel.|(*conditions) }
                  .select(:tile_column, :tile_row, :generated).each do |tile|
          coords = [tile[:tile_column], tile[:tile_row]]
          parents_info[coords] = tile[:generated]
        end
      end
    end

    candidates = build_generation_candidates(parent_coords_set, parents_info, children_coords)

    return if candidates.empty?

    generate_parent_tiles(
      candidates, z, parent_z, db, downsample_opts, collect_invalid_tiles: false
    )
  end

  # Builds generation candidates from possible parents and existing parents info
  def build_generation_candidates(possible_parents, parents_info, children_coords)
    candidates = Set.new
    valid_originals = Set.new

    parents_info.each do |coords, generated|
      valid_originals.add(coords) if generated == 0
    end

    non_original_parents = possible_parents - valid_originals

    non_original_parents.each do |parent_coords|
      existing_generated = parents_info[parent_coords]

      case existing_generated
      when nil, -1, -5
        candidates.add(parent_coords)
      when 1..4
        children_count = count_available_children(parent_coords, children_coords)
        candidates.add(parent_coords) if children_count != existing_generated
      end
    end

    candidates
  end

  def count_available_children(parent_coords, children_coords)
    px, py = parent_coords
    child_coords = [
      [2 * px, 2 * py],
      [2 * px + 1, 2 * py],
      [2 * px, 2 * py + 1],
      [2 * px + 1, 2 * py + 1]
    ]
    child_coords.count { |c| children_coords.include?(c) }
  end

  # Batch marks parents for quality regeneration (generated=-5)
  def batch_mark_parents_for_regeneration(updated_tiles, current_z, minzoom, db)
    return if updated_tiles.empty? || current_z < minzoom

    all_parents = Set.new
    updated_tiles.each do |_z, x, y|
      current_z_level = current_z - 1
      current_x = x / 2
      current_y = y / 2
      while current_z_level >= minzoom
        all_parents.add([current_z_level, current_x, current_y])
        current_z_level -= 1
        current_x /= 2
        current_y /= 2
      end
    end

    return if all_parents.empty?

    # Batch update: mark as generated=-5 (only for generated tiles 1-4)
    all_parents.each_slice(500) do |batch|
      conditions = batch.map { |z_level, px, py|
        Sequel.&(
          Sequel[:zoom_level] => z_level,
          Sequel[:tile_column] => px,
          Sequel[:tile_row] => py
        )
      }
      db[:tiles].where { Sequel.|(*conditions) }
                .where(generated: 1..4)
                .update(generated: -5)
    end

    LOGGER.debug("TileReconstructor: marked #{all_parents.size} parent tiles for quality regeneration")
  end

  # Validates tile data, returns :valid, :transparent, or :corrupted
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

  # Builds downsample options from route config
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
