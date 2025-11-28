# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../tile_reconstructor'
require 'sequel'

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

  # Creates terrain PNG with uniform elevation (Mapbox encoding)
  # Formula: elevation = -10000 + (R*256² + G*256 + B) * 0.1
  # Inverse: code = (elevation + 10000) / 0.1
  def create_terrain_png_mapbox(elevation, size = 256)
    code = ((elevation + 10000) / 0.1).round.clamp(0, 16777215)
    r = (code >> 16) & 0xFF
    g = (code >> 8) & 0xFF
    b = code & 0xFF
    Vips::Image.black(size, size).add([r, g, b]).cast(:uchar).write_to_buffer('.png')
  end

  def decode_mapbox_elevation(r, g, b)
    -10000.0 + (r * 256 * 256 + g * 256 + b) * 0.1
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

    it 'raises error for unknown kernel' do
      expect { described_class.downsample_raster_tiles(children, kernel: :invalid) }
        .to raise_error(ArgumentError, /Unknown kernel/)
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

  describe '.downsample_terrain_tiles' do
    describe 'input validation' do
      it 'raises error when not 4 tiles' do
        expect { described_class.downsample_terrain_tiles([create_test_png] * 3) }
          .to raise_error(ArgumentError, /Expected 4 tiles/)
      end

      it 'raises error when tile is nil or empty' do
        expect { described_class.downsample_terrain_tiles([create_test_png, nil, create_test_png, create_test_png]) }
          .to raise_error(ArgumentError, /non-empty/)
        expect { described_class.downsample_terrain_tiles([create_test_png, '', create_test_png, create_test_png]) }
          .to raise_error(ArgumentError, /non-empty/)
      end

      it 'raises error for unknown encoding' do
        expect { described_class.downsample_terrain_tiles(Array.new(4) { create_test_png }, encoding: 'invalid') }
          .to raise_error(ArgumentError, /Unknown encoding/)
      end

      it 'raises error for unknown method' do
        expect { described_class.downsample_terrain_tiles(Array.new(4) { create_test_png }, method: 'invalid') }
          .to raise_error(ArgumentError, /Unknown method/)
      end
    end

    it 'returns 256x256 PNG from 4 tiles' do
      children = Array.new(4) { create_terrain_png_mapbox(100) }
      result = described_class.downsample_terrain_tiles(children)

      img = Vips::Image.new_from_buffer(result, '')
      expect([img.width, img.height]).to eq([256, 256])
    end

    it 'preserves elevation with mapbox encoding' do
      children = [
        create_terrain_png_mapbox(0),
        create_terrain_png_mapbox(100),
        create_terrain_png_mapbox(200),
        create_terrain_png_mapbox(300)
      ]

      result = described_class.downsample_terrain_tiles(children, encoding: 'mapbox')

      expect(decode_mapbox_elevation(*pixel_at(result, 64, 64).map(&:to_i))).to be_within(0.2).of(0)
      expect(decode_mapbox_elevation(*pixel_at(result, 192, 192).map(&:to_i))).to be_within(0.2).of(300)
    end
  end

  describe '.get_children_data' do
    let(:db) { Sequel.connect('sqlite:/') }
    let(:tile1) { create_colored_png(255, 0, 0) }    # red
    let(:tile2) { create_colored_png(0, 255, 0) }  # green
    let(:tile3) { create_colored_png(0, 0, 255) }  # blue
    let(:tile4) { create_colored_png(255, 255, 0) } # yellow

    before do
      db.create_table?(:tiles) do
        Integer :zoom_level, null: false
        Integer :tile_column, null: false
        Integer :tile_row, null: false
        File :tile_data, null: false
        Integer :generated, default: 0
        unique [:zoom_level, :tile_column, :tile_row], name: :tile_index
      end
    end

    after do
      db.disconnect
    end

    it 'returns 4 children data in correct order when all exist' do
      parent_z = 5
      parent_x = 10
      parent_y = 20

      db[:tiles].insert(zoom_level: 6, tile_column: 20, tile_row: 40, tile_data: Sequel.blob(tile1))
      db[:tiles].insert(zoom_level: 6, tile_column: 21, tile_row: 40, tile_data: Sequel.blob(tile2))
      db[:tiles].insert(zoom_level: 6, tile_column: 20, tile_row: 41, tile_data: Sequel.blob(tile3))
      db[:tiles].insert(zoom_level: 6, tile_column: 21, tile_row: 41, tile_data: Sequel.blob(tile4))

      result = described_class.get_children_data(db, parent_z, parent_x, parent_y)

      expect(result).to eq([tile1, tile2, tile3, tile4])
    end

    it 'returns nil when not all children exist' do
      parent_z = 5
      parent_x = 10
      parent_y = 20

      db[:tiles].insert(zoom_level: 6, tile_column: 20, tile_row: 40, tile_data: Sequel.blob(tile1))
      db[:tiles].insert(zoom_level: 6, tile_column: 21, tile_row: 40, tile_data: Sequel.blob(tile2))
      # Missing 2 children

      expect(described_class.get_children_data(db, parent_z, parent_x, parent_y)).to be_nil
    end
  end
end
