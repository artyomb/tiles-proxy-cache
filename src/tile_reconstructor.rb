require 'vips'

module TileReconstructor
  extend self

  # Supported interpolation kernels for downsampling
  KERNELS = %i[nearest linear cubic mitchell lanczos2 lanczos3].freeze

  # Combines 4 raster tiles into one (2x downsampling)
  # @param children_data [Array<String>] 4 tile blobs: [TL, TR, BL, BR]
  # @param format [String] output format: png, webp, jpeg
  # @param kernel [Symbol] interpolation kernel (see KERNELS)
  # @param output_options [Hash] format options: jpeg: Q:1-100, webp: Q:0-100 or lossless:true+effort:0-6, png: compression:0-9
  # @return [String] resulting tile blob
  def downsample_raster_tiles(children_data, format: 'png', kernel: :linear, **output_options)
    raise ArgumentError, "Expected 4 tiles, got #{children_data.size}" unless children_data.size == 4
    raise ArgumentError, "All tiles must be non-empty" if children_data.any?(&:nil?) || children_data.any?(&:empty?)
    raise ArgumentError, "Unknown kernel: #{kernel}" unless KERNELS.include?(kernel)

    images = children_data.map { |d| Vips::Image.new_from_buffer(d, '') }

    top = images[0].join(images[1], :horizontal)
    bottom = images[2].join(images[3], :horizontal)
    combined = top.join(bottom, :vertical)

    combined.resize(0.5, kernel: kernel).write_to_buffer(".#{format}", **output_options)
  end
end
