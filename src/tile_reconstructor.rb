require 'vips'
require 'sequel'
require 'set'
require_relative 'ext/terrain_downsample_extension'

class TileReconstructor
  KERNELS = %i[nearest linear cubic mitchell lanczos2 lanczos3].freeze  # Vips interpolation kernels
  TERRAIN_ENCODINGS = %w[mapbox terrarium].freeze  # Supported terrain RGB encodings
  TERRAIN_METHODS = %w[average nearest maximum].freeze  # Terrain downsampling methods

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

    start_zoom.downto(minzoom) do |z|
      break unless @running

      begin
        process_zoom_level(z, db, downsample_opts)
      rescue => e
        LOGGER.error("TileReconstructor: failed to process zoom #{z} for #{@source_name}: #{e.message}")
        LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
      end
    end

    LOGGER.info("TileReconstructor: gap filling completed for #{@source_name}")
  end

  otl_def :run_reconstruction

  def process_zoom_level(z, db, downsample_opts)
    parent_z = z - 1
    minzoom = downsample_opts[:minzoom]
    return if parent_z < minzoom

    LOGGER.info("TileReconstructor: processing zoom #{z} -> #{parent_z}")

    begin
      children_coords = load_children_coords(db, z)
      return if children_coords.empty?

      parents_info = load_parents_info(db, parent_z)
      possible_parents = calculate_possible_parents(children_coords)
      candidates = build_generation_candidates(possible_parents, parents_info, children_coords)
      return if candidates.empty?

      parents_children_map = group_parents_by_children(candidates, children_coords)
      process_parents_batches(parents_children_map, z, parent_z, db, downsample_opts)

      LOGGER.debug("TileReconstructor: zoom #{z} -> #{parent_z} completed")
    rescue => e
      LOGGER.error("TileReconstructor: error processing zoom #{z} -> #{parent_z}: #{e.message}")
      LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
      raise
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
        info[[tile[:tile_column], tile[:tile_row]]] = tile[:generated]
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

  def build_generation_candidates(possible_parents, parents_info, children_coords)
    candidates = Set.new
    originals = Set.new

    parents_info.each do |coords, generated|
      originals.add(coords) if generated == 0
    end

    non_original_parents = possible_parents - originals

    non_original_parents.each do |parent_coords|
      existing_generated = parents_info[parent_coords]
      if existing_generated.nil?
        candidates.add(parent_coords)
      elsif existing_generated > 0
        children_count = count_available_children(parent_coords, children_coords)
        candidates.add(parent_coords) if children_count != existing_generated
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

  def process_parents_batches(parents_children_map, z, parent_z, db, downsample_opts)
    parents_list = parents_children_map.keys
    return if parents_list.empty?

    parents_list.each_slice(BATCH_SIZE) do |batch|
      break unless @running

      children_data_map = load_children_data_batch(db, z, batch, parents_children_map)
      next if children_data_map.empty?

      generated_tiles = []
      batch.each do |parent_coords|
        children_data = children_data_map[parent_coords]
        next unless children_data

        begin
          new_data = send(downsample_opts[:method], children_data, **downsample_opts[:args])
          next unless new_data

          used_count = children_data.count { |d| !d.nil? }
          generated_tiles << {
            zoom_level: parent_z,
            tile_column: parent_coords[0],
            tile_row: parent_coords[1],
            tile_data: Sequel.blob(new_data),
            generated: used_count
          }
        rescue => e
          LOGGER.warn("TileReconstructor: failed to generate tile #{parent_z}/#{parent_coords[0]}/#{parent_coords[1]}: #{e.message}")
        end
      end

      insert_generated_tiles(db, generated_tiles) if generated_tiles.any?
    end
  end

  def load_children_data_batch(db, z, parent_batch, parents_children_map)
    all_children_coords = Set.new
    coord_to_parent = {}

    parent_batch.each do |parent_coords|
      children_coords = parents_children_map[parent_coords]
      next unless children_coords

      children_coords.each_with_index do |child_coords, idx|
        all_children_coords << child_coords
        coord_to_parent[child_coords] = [parent_coords, idx]
      end
    end

    return {} if all_children_coords.empty?

    loaded_data = {}
    conditions = all_children_coords.to_a.map { |cx, cy|
      Sequel.&(Sequel[:tile_column] => cx, Sequel[:tile_row] => cy)
    }
    db[:tiles].where(zoom_level: z).where { Sequel.|(*conditions) }
              .select(:tile_column, :tile_row, :tile_data).each do |tile|
      coord_key = [tile[:tile_column], tile[:tile_row]]
      parent_info = coord_to_parent[coord_key]
      next unless parent_info

      next if is_fully_transparent?(tile[:tile_data])

      parent_coords, idx = parent_info
      loaded_data[parent_coords] ||= [nil, nil, nil, nil]
      loaded_data[parent_coords][idx] = tile[:tile_data]
    end

    loaded_data
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
    bottom_row.join(top_row, :vertical)  # TMS: bottom first (Y increases southward)
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
    false
  end
end
