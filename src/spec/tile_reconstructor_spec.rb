# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../tile_reconstructor'

RSpec.describe TileReconstructor do
  def create_test_png(size = 256)
    Vips::Image.black(size, size).write_to_buffer('.png')
  end

  def create_colored_png(r, g, b, size = 256)
    Vips::Image.black(size, size).add([r, g, b]).cast(:uchar).write_to_buffer('.png')
  end

  def pixel_at(blob, x, y)
    Vips::Image.new_from_buffer(blob, '').getpoint(x, y)
  end

  describe '.downsample_raster_tiles' do
    let(:children) { Array.new(4) { create_test_png } }

    it 'combines 4 tiles into 1 of the same size' do
      result = described_class.downsample_raster_tiles(children)

      img = Vips::Image.new_from_buffer(result, '')
      expect([img.width, img.height]).to eq([256, 256])
    end

    it 'raises error when not 4 tiles' do
      expect { described_class.downsample_raster_tiles([create_test_png] * 3) }
        .to raise_error(ArgumentError, /Expected 4 tiles/)
    end

    it 'raises error when tile is nil or empty' do
      expect { described_class.downsample_raster_tiles([create_test_png, nil, create_test_png, create_test_png]) }
        .to raise_error(ArgumentError, /non-empty/)
    end

    it 'preserves tile order: TL red, TR green, BL blue, BR yellow' do
      children = [
        create_colored_png(255, 0, 0),    # TL: red
        create_colored_png(0, 255, 0),    # TR: green
        create_colored_png(0, 0, 255),    # BL: blue
        create_colored_png(255, 255, 0)   # BR: yellow
      ]

      result = described_class.downsample_raster_tiles(children)

      expect(pixel_at(result, 64, 64)).to eq([255, 0, 0])      # TL: red
      expect(pixel_at(result, 192, 64)).to eq([0, 255, 0])     # TR: green
      expect(pixel_at(result, 64, 192)).to eq([0, 0, 255])     # BL: blue
      expect(pixel_at(result, 192, 192)).to eq([255, 255, 0])  # BR: yellow
    end
  end
end
