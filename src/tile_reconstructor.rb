require 'vips'

module TileReconstructor
  extend self

  # Combines 4 raster tiles into one (2x downsampling)
  # @param children_data [Array<String>] 4 blobs: [TL, TR, BL, BR]
  # @param format [String] output format: png, webp, jpeg
  # @return [String] resulting tile blob
  def downsample_raster_tiles(children_data, format: 'png')
    raise ArgumentError, "Expected 4 tiles, got #{children_data.size}" unless children_data.size == 4
    raise ArgumentError, "All tiles must be non-empty" if children_data.any?(&:nil?) || children_data.any?(&:empty?)

    images = children_data.map { |d| Vips::Image.new_from_buffer(d, '') }

    top = images[0].join(images[1], :horizontal)
    bottom = images[2].join(images[3], :horizontal)
    combined = top.join(bottom, :vertical)

    combined.resize(0.5, kernel: :linear).write_to_buffer(".#{format}")
  end
end
