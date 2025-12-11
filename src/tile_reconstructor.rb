require 'vips'
require 'sequel'
require_relative 'ext/terrain_downsample_extension'

class TileReconstructor
  KERNELS = %i[nearest linear cubic mitchell lanczos2 lanczos3].freeze  # Vips interpolation kernels
  TERRAIN_ENCODINGS = %w[mapbox terrarium].freeze  # Supported terrain RGB encodings
  TERRAIN_METHODS = %w[average nearest maximum].freeze  # Terrain downsampling methods

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

  # Marks parent tile for regeneration when new child tile appears
  # Creates placeholder if parent doesn't exist, marks existing generated parent (generated=1 -> generated=2)
  def mark_parent_for_new_child(db, child_z, child_x, child_y, minzoom)
    parent_z = child_z - 1
    return if parent_z < minzoom

    parent_x = child_x / 2
    parent_y = child_y / 2

    parent = db[:tiles].where(
      zoom_level: parent_z,
      tile_column: parent_x,
      tile_row: parent_y
    ).first

    if parent.nil?
      db[:tiles].insert_conflict(
        target: [:zoom_level, :tile_column, :tile_row],
        update: { generated: Sequel[:excluded][:generated] }
      ).insert(
        zoom_level: parent_z,
        tile_column: parent_x,
        tile_row: parent_y,
        tile_data: Sequel.blob(''),
        generated: 2
      )
    elsif parent[:generated] == 1
      db[:tiles].where(
        zoom_level: parent_z,
        tile_column: parent_x,
        tile_row: parent_y
      ).update(generated: 2)
    end
  rescue => e
    LOGGER.warn("TileReconstructor: failed to mark parent for #{child_z}/#{child_x}/#{child_y}: #{e.message}")
  end

  private

  # Parses schedule time from config, returns {hour:, minute:} or nil
  def parse_schedule_time
    time_str = @route.dig(:gap_filling, :schedule, :time) || @route.dig(:gap_filling, :schedule, 'time')
    return nil unless time_str
    
    hour, minute = time_str.split(':').map(&:to_i)
    { hour: hour, minute: minute }
  end

  # Checks if current UTC time matches schedule
  def should_run_now?
    return false unless @schedule_time
    now = Time.now.utc
    now.hour == @schedule_time[:hour] && now.min == @schedule_time[:minute]
  end

  # Runs scheduled reconstruction if not already run today
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
        process_zoom(z, db, downsample_opts)
      rescue => e
        LOGGER.error("TileReconstructor: failed to process zoom #{z} for #{@source_name}: #{e.message}")
        LOGGER.debug("TileReconstructor: backtrace: #{e.backtrace.join("\n")}")
      end
    end
    
    LOGGER.info("TileReconstructor: gap filling completed for #{@source_name}")
  end
  
  otl_def :run_reconstruction

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

  # Gets 4 child tiles data [TL, TR, BL, BR]
  # Returns array with nil for missing tiles (allows partial generation)
  def get_children_data(db, z, parent_x, parent_y)
    child_z = z + 1
    children_coords = [
      [child_z, 2 * parent_x, 2 * parent_y], # TL
      [child_z, 2 * parent_x + 1, 2 * parent_y], # TR
      [child_z, 2 * parent_x, 2 * parent_y + 1], # BL
      [child_z, 2 * parent_x + 1, 2 * parent_y + 1] # BR
    ]

    children_coords.map do |cz, cx, cy|
      db[:tiles].where(zoom_level: cz, tile_column: cx, tile_row: cy).get(:tile_data)
    end
  end

  # Builds downsample options from route config (method, args, minzoom)
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

  # Marks parent tile as regeneration candidate (generated=1 -> generated=2)
  def mark_parent_candidate(db, child_z, child_x, child_y)
    parent_z = child_z - 1
    parent_x = child_x / 2
    parent_y = child_y / 2

    parent_dataset = db[:tiles].where(
      zoom_level: parent_z,
      tile_column: parent_x,
      tile_row: parent_y
    )

    parent = parent_dataset.first
    return unless parent

    generated = parent[:generated]
    return unless generated == 1

    parent_dataset.update(generated: 2)
  end

  # Processes regeneration candidates (generated=2) for given zoom
  def process_regeneration_candidates(z, db, downsample_opts)
    minzoom = downsample_opts[:minzoom]

    db[:tiles]
      .where(zoom_level: z, generated: 2)
      .select(:zoom_level, :tile_column, :tile_row)
      .each do |tile|
      children_data = get_children_data(db, z, tile[:tile_column], tile[:tile_row])
      next if children_data.all?(&:nil?)

      begin
        new_data = send(downsample_opts[:method], children_data, **downsample_opts[:args])
        next unless new_data

        db[:tiles].where(
          zoom_level: z,
          tile_column: tile[:tile_column],
          tile_row: tile[:tile_row]
        ).update(tile_data: Sequel.blob(new_data), generated: 1)

        mark_parent_candidate(db, z, tile[:tile_column], tile[:tile_row]) if z > minzoom
      rescue => e
        LOGGER.warn("TileReconstructor: failed to regenerate tile #{z}/#{tile[:tile_column]}/#{tile[:tile_row]}: #{e.message}")
        next
      end
    end
  end

  otl_def :process_regeneration_candidates

  # Processes miss records for given zoom
  def process_miss_records(z, db, downsample_opts)
    minzoom = downsample_opts[:minzoom]

    db[:misses]
      .where(zoom_level: z)
      .where do
      Sequel.~(
        db[:tiles].where(
          zoom_level: Sequel[:misses][:zoom_level],
          tile_column: Sequel[:misses][:tile_column],
          tile_row: Sequel[:misses][:tile_row]
        ).exists
      )
    end
      .select(:zoom_level, :tile_column, :tile_row)
      .each do |miss|
      children_data = get_children_data(db, z, miss[:tile_column], miss[:tile_row])
      next if children_data.all?(&:nil?)

      begin
        new_data = send(downsample_opts[:method], children_data, **downsample_opts[:args])
        next unless new_data

        db[:tiles].insert(
          zoom_level: z,
          tile_column: miss[:tile_column],
          tile_row: miss[:tile_row],
          tile_data: Sequel.blob(new_data),
          generated: 1
        )

        db[:misses].where(
          zoom_level: z,
          tile_column: miss[:tile_column],
          tile_row: miss[:tile_row]
        ).delete

        mark_parent_candidate(db, z, miss[:tile_column], miss[:tile_row]) if z > minzoom
      rescue => e
        LOGGER.warn("TileReconstructor: failed to generate tile #{z}/#{miss[:tile_column]}/#{miss[:tile_row]}: #{e.message}")
        next
      end
    end
  end

  otl_def :process_miss_records

  # Creates parent candidate records (generated=2) for tiles that don't exist
  def create_parent_candidates_from_existing(z, db, minzoom)
    parent_z = z - 1
    return if parent_z < minzoom

    parent_coords = db[:tiles]
      .where(zoom_level: z)
      .select(
        Sequel.lit('tile_column / 2 AS parent_x'),
        Sequel.lit('tile_row / 2 AS parent_y')
      )
      .distinct
      .all

    return if parent_coords.empty?

    existing_parents = db[:tiles]
      .where(zoom_level: parent_z)
      .select(:tile_column, :tile_row)
      .all
      .map { |r| [r[:tile_column], r[:tile_row]] }
      .to_set

    new_candidates = parent_coords
      .map { |r| [r[:parent_x], r[:parent_y]] }
      .reject { |x, y| existing_parents.include?([x, y]) }

    return if new_candidates.empty?

    new_candidates.each_slice(1000) do |batch|
      db[:tiles].insert_conflict(
        target: [:zoom_level, :tile_column, :tile_row]
      ).multi_insert(
        batch.map do |x, y|
          {
            zoom_level: parent_z,
            tile_column: x,
            tile_row: y,
            tile_data: Sequel.blob(''),
            generated: 2
          }
        end
      )
    end

    LOGGER.info("TileReconstructor: created #{new_candidates.size} parent candidates for zoom #{parent_z}")
  end

  otl_def :create_parent_candidates_from_existing

  # Processes single zoom: regeneration candidates first, then misses, then parent candidates
  def process_zoom(z, db, downsample_opts)
    LOGGER.info("TileReconstructor: processing zoom #{z}")

    process_regeneration_candidates(z, db, downsample_opts)
    process_miss_records(z, db, downsample_opts)
    create_parent_candidates_from_existing(z, db, downsample_opts[:minzoom])

    LOGGER.debug("TileReconstructor: zoom #{z} completed")
  end
  
  otl_def :process_zoom

  # Combines 4 tile images into 2x2 grid (TMS coordinate system)
  def combine_4_tiles(children_data)
    images = children_data.map { |d| Vips::Image.new_from_buffer(d, '') }
    
    # If any tile has alpha channel, add alpha to all RGB tiles to preserve transparency
    has_alpha = images.any? { |img| img.bands == 4 }
    images.map! { |img| img.bands == 4 ? img : img.bandjoin(255) } if has_alpha
    
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
end
