require 'vips'
require 'sequel'
require_relative 'ext/terrain_downsample_extension'

module TileReconstructor
  extend self

  KERNELS = %i[nearest linear cubic mitchell lanczos2 lanczos3].freeze
  TERRAIN_ENCODINGS = %w[mapbox terrarium].freeze
  TERRAIN_METHODS = %w[average nearest maximum].freeze

  # Combines 4 raster tiles into one (2x downsampling)
  # @param children_data [Array<String>] 4 tile blobs: [TL, TR, BL, BR]
  # @param format [String] output format: png, webp, jpeg
  # @param kernel [Symbol] interpolation kernel (see KERNELS)
  # @param output_options [Hash] format options
  # @return [String] resulting tile blob
  def downsample_raster_tiles(children_data, format: 'png', kernel: :linear, **output_options)
    raise ArgumentError, "Expected 4 tiles, got #{children_data.size}" unless children_data.size == 4
    raise ArgumentError, "All tiles must be non-empty" if children_data.any?(&:nil?) || children_data.any?(&:empty?)
    raise ArgumentError, "Unknown kernel: #{kernel}" unless KERNELS.include?(kernel)

    combined = combine_4_tiles(children_data)
    combined.resize(0.5, kernel: kernel).write_to_buffer(".#{format}", **output_options)
  end

  # Combines 4 terrain tiles into one with elevation-aware downsampling
  # @param children_data [Array<String>] 4 tile blobs: [TL, TR, BL, BR]
  # @param encoding [String] terrain source encoding: 'mapbox' or 'terrarium'
  # @param method [String] downsampling method: 'average', 'nearest', 'maximum'
  # @return [String] resulting PNG blob
  def downsample_terrain_tiles(children_data, encoding: 'mapbox', method: 'average')
    raise ArgumentError, "Expected 4 tiles, got #{children_data.size}" unless children_data.size == 4
    raise ArgumentError, "All tiles must be non-empty" if children_data.any?(&:nil?) || children_data.any?(&:empty?)
    raise ArgumentError, "Unknown encoding: #{encoding}" unless TERRAIN_ENCODINGS.include?(encoding)
    raise ArgumentError, "Unknown method: #{method}" unless TERRAIN_METHODS.include?(method)

    combined = combine_4_tiles(children_data)
    combined_png = combined.write_to_buffer('.png')

    TerrainDownsampleFFI.downsample_png(combined_png, 256, encoding, method)
  end

  # Retrieves tile data for all 4 child tiles in order: TL, TR, BL, BR
  # Returns nil if not all children exist (usable in guard clauses)
  # @param db [Sequel::Database] database connection
  # @param z [Integer] parent zoom level
  # @param parent_x [Integer] parent tile column
  # @param parent_y [Integer] parent tile row (TMS)
  # @return [Array<String>, nil] 4 tile blobs: [TL, TR, BL, BR] or nil if not all exist
  def get_children_data(db, z, parent_x, parent_y)
    child_z = z + 1
    children_coords = [
      [child_z, 2 * parent_x, 2 * parent_y], # TL
      [child_z, 2 * parent_x + 1, 2 * parent_y], # TR
      [child_z, 2 * parent_x, 2 * parent_y + 1], # BL
      [child_z, 2 * parent_x + 1, 2 * parent_y + 1] # BR
    ]

    children_data = children_coords.map do |cz, cx, cy|
      db[:tiles].where(zoom_level: cz, tile_column: cx, tile_row: cy).get(:tile_data)
    end

    children_data.any?(&:nil?) ? nil : children_data
  end

  # Builds downsample options from route configuration
  # @param route [Hash] route with gap_filling, metadata, minzoom
  # @return [Hash] { method: Symbol, args: Hash, minzoom: Integer }
  def build_downsample_opts(route)
    encoding = route.dig(:metadata, :encoding)
    gap_filling = route[:gap_filling]
    minzoom = route[:minzoom]

    if TERRAIN_ENCODINGS.include?(encoding)
      method = gap_filling[:terrain_method]
      { method: :downsample_terrain_tiles, args: { encoding: encoding, method: method }, minzoom: minzoom }
    else
      output_format_config = gap_filling[:output_format]
      format = output_format_config[:type]
      kernel = gap_filling[:raster_method].to_sym

      { method: :downsample_raster_tiles, args: { format: format, kernel: kernel, **output_format_config }, minzoom: minzoom }
    end
  end

  # Marks parent tile as regeneration candidate if it's generated
  # Skips original tiles (generated=0/nil) and already marked candidates (generated=2)
  # @param db [Sequel::Database] database connection
  # @param child_z [Integer] child zoom level
  # @param child_x [Integer] child tile column
  # @param child_y [Integer] child tile row (TMS)
  # @return [void]
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

  # Processes regeneration candidates (generated=2) for zoom level z
  # Regenerates from children if all 4 exist, marks parent as candidate if z > minzoom
  # @param z [Integer] zoom level
  # @param db [Sequel::Database] database
  # @param downsample_opts [Hash] from build_downsample_opts
  def process_regeneration_candidates(z, db, downsample_opts)
    minzoom = downsample_opts[:minzoom]

    db[:tiles]
      .where(zoom_level: z, generated: 2)
      .select(:zoom_level, :tile_column, :tile_row)
      .each do |tile|
      children_data = get_children_data(db, z, tile[:tile_column], tile[:tile_row])
      next unless children_data

      new_data = send(downsample_opts[:method], children_data, **downsample_opts[:args])
      db[:tiles].where(
        zoom_level: z,
        tile_column: tile[:tile_column],
        tile_row: tile[:tile_row]
      ).update(tile_data: Sequel.blob(new_data), generated: 1)

      mark_parent_candidate(db, z, tile[:tile_column], tile[:tile_row]) if z > minzoom
    end
  end

  # Processes miss records for zoom level z
  # Generates tiles from children if all 4 exist, removes from misses, marks parent as candidate if z > minzoom
  # @param z [Integer] zoom level
  # @param db [Sequel::Database] database
  # @param downsample_opts [Hash] from build_downsample_opts
  def process_miss_records(z, db, downsample_opts)
    minzoom = downsample_opts[:minzoom]

    db[:misses]
      .where(zoom_level: z, status: 404)
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
      next unless children_data

      new_data = send(downsample_opts[:method], children_data, **downsample_opts[:args])
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
    end
  end

  # Processes single zoom level: regeneration candidates first, then misses
  # @param z [Integer] zoom level to process
  # @param db [Sequel::Database] database connection
  # @param downsample_opts [Hash] from build_downsample_opts
  def process_zoom(z, db, downsample_opts)
    LOGGER.info("TileReconstructor: processing zoom #{z}")

    process_regeneration_candidates(z, db, downsample_opts)
    process_miss_records(z, db, downsample_opts)

    LOGGER.debug("TileReconstructor: zoom #{z} completed")
  end

  private

  def combine_4_tiles(children_data)
    images = children_data.map { |d| Vips::Image.new_from_buffer(d, '') }

    top = images[0].join(images[1], :horizontal)
    bottom = images[2].join(images[3], :horizontal)
    top.join(bottom, :vertical)
  end
end
