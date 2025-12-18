require 'vips'
require 'sequel'
require 'set'
require_relative 'ext/terrain_downsample_extension'

class TileReconstructor
  KERNELS = %i[nearest linear cubic mitchell lanczos2 lanczos3].freeze # Vips interpolation kernels
  TERRAIN_ENCODINGS = %w[mapbox terrarium].freeze # Supported terrain RGB encodings
  TERRAIN_METHODS = %w[average nearest maximum].freeze # Terrain downsampling methods

  BATCH_SIZE = 200

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

    regenerated_tiles = Set.new
    start_zoom.downto(minzoom) do |z|
      break unless @running

      begin
        result = process_zoom_level(z, db, downsample_opts, regenerated_tiles)
        regenerated_tiles = result if result
      rescue => e
        LOGGER.error("TileReconstructor: failed to process zoom #{z} for #{@source_name}: #{e.message}")
        LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
      end
    end

    LOGGER.info("TileReconstructor: gap filling completed for #{@source_name}")
  end

  otl_def :run_reconstruction

  def process_zoom_level(z, db, downsample_opts, regenerated_children)
    parent_z = z - 1
    minzoom = downsample_opts[:minzoom]
    return if parent_z < minzoom

    LOGGER.info("TileReconstructor: processing zoom #{z} -> #{parent_z}")

    begin
      # First, regenerate tiles marked as -1 (from previous pass)
      regenerate_invalid_tiles(z, db, downsample_opts)

      children_coords = load_children_coords(db, z)
      return if children_coords.empty?

      parents_info = load_parents_info(db, parent_z)
      possible_parents = calculate_possible_parents(children_coords)
      candidates = build_generation_candidates(possible_parents, parents_info, children_coords, regenerated_children)
      return if candidates.empty?

      parents_children_map = group_parents_by_children(candidates, children_coords)
      regenerated_tiles = generate_tiles_batches(parents_children_map, z, parent_z, db, downsample_opts)

      return unless regenerated_tiles

      LOGGER.debug("TileReconstructor: zoom #{z} -> #{parent_z} completed, #{regenerated_tiles.size} tiles regenerated")
      regenerated_tiles
    rescue => e
      LOGGER.error("TileReconstructor: error processing zoom #{z} -> #{parent_z}: #{e.message}")
      LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
      raise
    end
  end

  # Regenerates tiles marked as -1 if they have valid children
  def regenerate_invalid_tiles(z, db, downsample_opts)
    begin
      # Find all tiles marked as -1 at zoom z
      invalid_tiles = []
      db[:tiles].where(zoom_level: z, generated: -1)
                .select(:tile_column, :tile_row).each do |tile|
        invalid_tiles << [tile[:tile_column], tile[:tile_row]]
      end

      return if invalid_tiles.empty?

      LOGGER.info("TileReconstructor: found #{invalid_tiles.size} invalid tiles (generated = -1) at zoom #{z}, checking for regeneration")

      children_z = z + 1
      maxzoom = @route[:maxzoom]
      return if children_z > maxzoom

      children_coords = load_children_coords(db, children_z)
      return if children_coords.empty?

      invalid_tiles_set = Set.new(invalid_tiles)
      tiles_children_map = group_parents_by_children(invalid_tiles_set, children_coords)
      return if tiles_children_map.empty?

      LOGGER.info("TileReconstructor: regenerating #{tiles_children_map.size} invalid tiles at zoom #{z} from zoom #{children_z}")
      generate_tiles_batches(tiles_children_map, children_z, z, db, downsample_opts)

      LOGGER.info("TileReconstructor: completed regeneration of invalid tiles at zoom #{z}")
    rescue => e
      LOGGER.error("TileReconstructor: error regenerating invalid tiles at zoom #{z}: #{e.message}")
      LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
    end
  end

  otl_def :process_zoom_level

  def load_children_coords(db, z)
    coords = Set.new
    begin
      db[:tiles].where(zoom_level: z).select(:tile_column, :tile_row).each do |tile|
        coords.add([tile[:tile_column], tile[:tile_row]])
      end
      LOGGER.info("TileReconstructor: loaded #{coords.size} child tiles for zoom #{z}")
    rescue => e
      LOGGER.error("TileReconstructor: failed to load children coords for zoom #{z}: #{e.message}")
      raise
    end
    coords
  end

  def load_parents_info(db, parent_z)
    info = {}
    begin
      db[:tiles].where(zoom_level: parent_z).select(:tile_column, :tile_row, :generated).each do |tile|
        coords = [tile[:tile_column], tile[:tile_row]]
        info[coords] = tile[:generated]
      end
      LOGGER.info("TileReconstructor: loaded info for #{info.size} parent tiles for zoom #{parent_z}")
    rescue => e
      LOGGER.error("TileReconstructor: failed to load parents info for zoom #{parent_z}: #{e.message}")
      raise
    end
    info
  end

  def calculate_possible_parents(children_coords)
    possible_parents = Set.new
    children_coords.each do |cx, cy|
      parent_x = cx / 2
      parent_y = cy / 2
      possible_parents.add([parent_x, parent_y])
    end
    possible_parents
  end

  def build_generation_candidates(possible_parents, parents_info, children_coords, regenerated_children)
    candidates = Set.new
    valid_originals = Set.new

    parents_info.each do |coords, generated|
      # Only exclude valid original tiles (generated == 0 and not transparent/invalid)
      valid_originals.add(coords) if generated == 0
    end

    non_original_parents = possible_parents - valid_originals

    non_original_parents.each do |parent_coords|
      existing_generated = parents_info[parent_coords]
      if existing_generated.nil?
        candidates.add(parent_coords)
      elsif existing_generated > 0
        children_count = count_available_children(parent_coords, children_coords)
        # Regenerate if count changed OR if any child was regenerated
        has_regenerated_child = has_regenerated_children?(parent_coords, regenerated_children)
        candidates.add(parent_coords) if children_count != existing_generated || has_regenerated_child
      elsif existing_generated == -1
        # Transparent/invalid original tile - needs regeneration
        candidates.add(parent_coords)
      end
    end

    LOGGER.info("TileReconstructor: built #{candidates.size} generation candidates")
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

  def has_regenerated_children?(parent_coords, regenerated_children)
    return false if regenerated_children.empty?

    px, py = parent_coords
    child_coords = [
      [2 * px, 2 * py],
      [2 * px + 1, 2 * py],
      [2 * px, 2 * py + 1],
      [2 * px + 1, 2 * py + 1]
    ]
    child_coords.any? { |c| regenerated_children.include?(c) }
  end

  def group_parents_by_children(candidates, children_coords)
    parents_children_map = {}
    candidates.each do |parent_coords|
      px, py = parent_coords
      child_coords = [
        [2 * px, 2 * py],
        [2 * px + 1, 2 * py],
        [2 * px, 2 * py + 1],
        [2 * px + 1, 2 * py + 1]
      ]
      available_children = child_coords.select { |c| children_coords.include?(c) }
      parents_children_map[parent_coords] = child_coords if available_children.any?
    end
    parents_children_map
  end

  # Generates tiles from children data in batches
  # source_z: zoom level to load children data from
  # target_z: zoom level to generate tiles for
  # Returns: Set of coordinates of regenerated tiles, or nil if nothing was generated
  def generate_tiles_batches(tiles_children_map, source_z, target_z, db, downsample_opts)
    tiles_list = tiles_children_map.keys
    return if tiles_list.empty?

    regenerated_coords = Set.new

    tiles_list.each_slice(BATCH_SIZE) do |batch|
      break unless @running

      children_data_map = load_children_data_batch(db, source_z, batch, tiles_children_map)
      next if children_data_map.empty?

      generated_tiles = []
      batch.each do |tile_coords|
        children_data = children_data_map[tile_coords]
        next unless children_data

        begin
          new_data = send(downsample_opts[:method], children_data, **downsample_opts[:args])
          next unless new_data

          used_count = children_data.count { |d| !d.nil? }
          generated_tiles << {
            zoom_level: target_z,
            tile_column: tile_coords[0],
            tile_row: tile_coords[1],
            tile_data: Sequel.blob(new_data),
            generated: used_count
          }
          regenerated_coords.add(tile_coords)
        rescue => e
          LOGGER.warn("TileReconstructor: failed to generate tile #{target_z}/#{tile_coords[0]}/#{tile_coords[1]}: #{e.message}")
        end
      end

      insert_generated_tiles(db, generated_tiles) if generated_tiles.any?
    end

    regenerated_coords
  end

  def load_children_data_batch(db, source_z, tiles_batch, tiles_children_map)
    all_children_coords = Set.new
    coord_to_tile = {}

    tiles_batch.each do |tile_coords|
      children_coords = tiles_children_map[tile_coords]
      next unless children_coords

      children_coords.each_with_index do |child_coords, idx|
        all_children_coords << child_coords
        coord_to_tile[child_coords] = [tile_coords, idx]
      end
    end

    return {} if all_children_coords.empty?

    loaded_data = {}
    transparent_tiles_to_mark = []

    conditions = all_children_coords.to_a.map { |cx, cy|
      Sequel.&(Sequel[:tile_column] => cx, Sequel[:tile_row] => cy)
    }
    db[:tiles].where(zoom_level: source_z).where { Sequel.|(*conditions) }
              .select(:tile_column, :tile_row, :tile_data, :generated).each do |tile|
      coord_key = [tile[:tile_column], tile[:tile_row]]
      tile_info = coord_to_tile[coord_key]
      next unless tile_info

      tile_coords, idx = tile_info

      if is_fully_transparent?(tile[:tile_data])
        # Mark transparent/invalid tile as -1 in database for next pass
        # Only mark if it's not already marked and not a generated tile
        if tile[:generated] != -1 && (tile[:generated].nil? || tile[:generated] == 0)
          transparent_tiles_to_mark << coord_key
        end
        next
      end

      loaded_data[tile_coords] ||= [nil, nil, nil, nil]
      loaded_data[tile_coords][idx] = tile[:tile_data]
    end

    # Batch update transparent tiles to -1
    mark_transparent_tiles(db, source_z, transparent_tiles_to_mark) if transparent_tiles_to_mark.any?

    loaded_data
  end

  # Marks transparent/invalid tiles as generated = -1 in database
  def mark_transparent_tiles(db, z, transparent_coords)
    return if transparent_coords.empty?

    begin
      transparent_coords.each_slice(BATCH_SIZE) do |batch|
        conditions = batch.map { |cx, cy|
          Sequel.&(Sequel[:tile_column] => cx, Sequel[:tile_row] => cy)
        }
        db[:tiles].where(zoom_level: z).where { Sequel.|(*conditions) }
                  .where(generated: [nil, 0])
                  .update(generated: -1)
      end
      LOGGER.debug("TileReconstructor: marked #{transparent_coords.size} transparent tiles at zoom #{z} as -1")
    rescue => e
      LOGGER.error("TileReconstructor: failed to mark transparent tiles at zoom #{z}: #{e.message}")
    end
  end

  def insert_generated_tiles(db, tiles)
    return if tiles.empty?

    begin
      db[:tiles].insert_conflict(
        target: [:zoom_level, :tile_column, :tile_row],
        update: {
          tile_data: Sequel[:excluded][:tile_data],
          generated: Sequel[:excluded][:generated]
        }
      ).multi_insert(tiles)
    rescue => e
      LOGGER.error("TileReconstructor: failed to insert batch of #{tiles.size} tiles: #{e.message}")
      raise
    end
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

  # Checks if tile is fully transparent (all alpha channel values are 0)
  # Returns false if tile has no alpha channel (considered as having data)
  # Returns true only if tile has alpha channel and all pixels are fully transparent
  def is_fully_transparent?(tile_data)
    return false unless tile_data

    img = Vips::Image.new_from_buffer(tile_data, '')
    return false unless img.bands == 4

    alpha = img[3]
    alpha.max == 0
  rescue Vips::Error
    true
  end
end
