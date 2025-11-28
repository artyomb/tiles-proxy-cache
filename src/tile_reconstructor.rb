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
      [child_z, 2 * parent_x, 2 * parent_y],      # TL
      [child_z, 2 * parent_x + 1, 2 * parent_y], # TR
      [child_z, 2 * parent_x, 2 * parent_y + 1],  # BL
      [child_z, 2 * parent_x + 1, 2 * parent_y + 1] # BR
    ]

    children_data = children_coords.map do |cz, cx, cy|
      db[:tiles].where(zoom_level: cz, tile_column: cx, tile_row: cy).get(:tile_data)
    end

    children_data.any?(&:nil?) ? nil : children_data
  end

  private

  def combine_4_tiles(children_data)
    images = children_data.map { |d| Vips::Image.new_from_buffer(d, '') }

    top = images[0].join(images[1], :horizontal)
    bottom = images[2].join(images[3], :horizontal)
    top.join(bottom, :vertical)
  end
end
