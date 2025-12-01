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

  shared_context 'with database' do
    let(:db) { Sequel.connect('sqlite:/') }

    before do
      db.create_table?(:tiles) do
        Integer :zoom_level, null: false
        Integer :tile_column, null: false
        Integer :tile_row, null: false
        File :tile_data, null: false
        Integer :generated, default: 0
        unique [:zoom_level, :tile_column, :tile_row], name: :tile_index
      end

      db.create_table?(:misses) do
        Integer :zoom_level, null: false
        Integer :tile_column, null: false
        Integer :tile_row, null: false
        Integer :ts, null: false
        String :reason
        String :details
        Integer :status
        File :response_body
        primary_key [:zoom_level, :tile_column, :tile_row], name: :misses_pk
      end
    end

    after do
      db.disconnect
    end
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
    include_context 'with database'

    let(:tile1) { create_colored_png(255, 0, 0) } # red
    let(:tile2) { create_colored_png(0, 255, 0) } # green
    let(:tile3) { create_colored_png(0, 0, 255) } # blue
    let(:tile4) { create_colored_png(255, 255, 0) } # yellow

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

  describe '.mark_parent_candidate' do
    include_context 'with database'

    let(:tile_data) { create_test_png }

    it 'marks generated parent (generated=1) as candidate (generated=2)' do
      child_z = 6
      child_x = 20
      child_y = 40
      parent_z = 5
      parent_x = 10
      parent_y = 20

      db[:tiles].insert(
        zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y,
        tile_data: Sequel.blob(tile_data), generated: 1
      )

      described_class.mark_parent_candidate(db, child_z, child_x, child_y)

      parent = db[:tiles].where(zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y).first
      expect(parent[:generated]).to eq(2)
    end

    it 'does not mark original parent (generated=0 or nil)' do
      child_z = 6
      child_x = 20
      child_y = 40
      parent_z = 5
      parent_x = 10
      parent_y = 20

      [0, nil].each do |generated_value|
        db[:tiles].where(zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y).delete
        db[:tiles].insert(
          zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y,
          tile_data: Sequel.blob(tile_data), generated: generated_value
        )

        described_class.mark_parent_candidate(db, child_z, child_x, child_y)

        parent = db[:tiles].where(zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y).first
        expect(parent[:generated]).to eq(generated_value)
      end
    end

    it 'does not change already marked candidate (generated=2)' do
      child_z = 6
      child_x = 20
      child_y = 40
      parent_z = 5
      parent_x = 10
      parent_y = 20

      db[:tiles].insert(
        zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y,
        tile_data: Sequel.blob(tile_data), generated: 2
      )

      described_class.mark_parent_candidate(db, child_z, child_x, child_y)

      parent = db[:tiles].where(zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y).first
      expect(parent[:generated]).to eq(2)
    end

    it 'skips when parent does not exist in tiles' do
      child_z = 6
      child_x = 20
      child_y = 40

      expect do
        described_class.mark_parent_candidate(db, child_z, child_x, child_y)
      end.not_to raise_error

      parent_z = 5
      parent_x = 10
      parent_y = 20
      parent = db[:tiles].where(zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y).first
      expect(parent).to be_nil
    end
  end

  describe '.build_downsample_opts' do
    it 'returns raster opts structure' do
      route = { minzoom: 1, gap_filling: { output_format: { type: 'png' }, raster_method: 'linear' } }
      opts = described_class.build_downsample_opts(route)

      expect(opts[:method]).to eq(:downsample_raster_tiles)
      expect(opts[:args][:format]).to eq('png')
      expect(opts[:minzoom]).to eq(1)
    end

    it 'returns terrain opts structure' do
      route = { minzoom: 0, metadata: { encoding: 'mapbox' }, gap_filling: { terrain_method: 'average' } }
      opts = described_class.build_downsample_opts(route)

      expect(opts[:method]).to eq(:downsample_terrain_tiles)
      expect(opts[:args][:encoding]).to eq('mapbox')
      expect(opts[:minzoom]).to eq(0)
    end
  end

  describe '.process_regeneration_candidates' do
    include_context 'with database'

    let(:opts) { { method: :downsample_raster_tiles, args: { format: 'png', kernel: :linear }, minzoom: 1 } }

    it 'regenerates candidate when all children exist' do
      z = 5
      x = 10
      y = 20

      db[:tiles].insert(zoom_level: z, tile_column: x, tile_row: y, tile_data: Sequel.blob(create_test_png), generated: 2)

      child_z = z + 1
      child_tile = create_test_png
      db[:tiles].insert(zoom_level: child_z, tile_column: 2 * x, tile_row: 2 * y, tile_data: Sequel.blob(child_tile))
      db[:tiles].insert(zoom_level: child_z, tile_column: 2 * x + 1, tile_row: 2 * y, tile_data: Sequel.blob(child_tile))
      db[:tiles].insert(zoom_level: child_z, tile_column: 2 * x, tile_row: 2 * y + 1, tile_data: Sequel.blob(child_tile))
      db[:tiles].insert(zoom_level: child_z, tile_column: 2 * x + 1, tile_row: 2 * y + 1, tile_data: Sequel.blob(child_tile))

      described_class.process_regeneration_candidates(z, db, opts)

      tile = db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).first
      expect(tile[:generated]).to eq(1)
    end

    it 'skips candidate when not all children exist' do
      z = 5
      x = 10
      y = 20

      db[:tiles].insert(zoom_level: z, tile_column: x, tile_row: y, tile_data: Sequel.blob(create_test_png), generated: 2)

      child_z = z + 1
      db[:tiles].insert(zoom_level: child_z, tile_column: 2 * x, tile_row: 2 * y, tile_data: Sequel.blob(create_test_png))
      db[:tiles].insert(zoom_level: child_z, tile_column: 2 * x + 1, tile_row: 2 * y, tile_data: Sequel.blob(create_test_png))

      described_class.process_regeneration_candidates(z, db, opts)

      tile = db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).first
      expect(tile[:generated]).to eq(2)
    end
  end

  describe '.process_miss_records' do
    include_context 'with database'

    let(:opts) { { method: :downsample_raster_tiles, args: { format: 'png', kernel: :linear }, minzoom: 1 } }

    it 'generates tile and removes miss when all children exist' do
      z = 5
      x = 10
      y = 20

      db[:misses].insert(zoom_level: z, tile_column: x, tile_row: y, ts: Time.now.to_i, status: 404)
      child_tile = create_test_png
      (0..3).each do |i|
        db[:tiles].insert(zoom_level: z + 1, tile_column: 2 * x + (i % 2), tile_row: 2 * y + (i / 2), tile_data: Sequel.blob(child_tile))
      end

      described_class.process_miss_records(z, db, opts)

      expect(db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).get(:generated)).to eq(1)
      expect(db[:misses].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(0)
    end

    it 'skips miss when not all children exist' do
      z = 5
      x = 10
      y = 20

      db[:misses].insert(zoom_level: z, tile_column: x, tile_row: y, ts: Time.now.to_i, status: 404)
      db[:tiles].insert(zoom_level: z + 1, tile_column: 2 * x, tile_row: 2 * y, tile_data: Sequel.blob(create_test_png))

      described_class.process_miss_records(z, db, opts)

      expect(db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(0)
      expect(db[:misses].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(1)
    end

    it 'skips miss when tile already exists in tiles' do
      z = 5
      x = 10
      y = 20

      db[:tiles].insert(zoom_level: z, tile_column: x, tile_row: y, tile_data: Sequel.blob(create_test_png), generated: 0)
      db[:misses].insert(zoom_level: z, tile_column: x, tile_row: y, ts: Time.now.to_i, status: 404)

      described_class.process_miss_records(z, db, opts)

      expect(db[:misses].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(1)
    end

    it 'only processes misses with status 404' do
      z = 5
      x = 10
      y = 20

      db[:misses].insert(zoom_level: z, tile_column: x, tile_row: y, ts: Time.now.to_i, status: 500)
      db[:misses].insert(zoom_level: z, tile_column: x + 1, tile_row: y, ts: Time.now.to_i, status: 404)

      child_tile = create_test_png
      # Create children for miss at x (status 500 - should be skipped)
      (0..3).each do |i|
        db[:tiles].insert(zoom_level: z + 1, tile_column: 2 * x + (i % 2), tile_row: 2 * y + (i / 2), tile_data: Sequel.blob(child_tile))
      end
      # Create children for miss at x+1 (status 404 - should be processed)
      (0..3).each do |i|
        db[:tiles].insert(zoom_level: z + 1, tile_column: 2 * (x + 1) + (i % 2), tile_row: 2 * y + (i / 2), tile_data: Sequel.blob(child_tile))
      end

      described_class.process_miss_records(z, db, opts)

      expect(db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(0)
      expect(db[:tiles].where(zoom_level: z, tile_column: x + 1, tile_row: y).count).to eq(1)
      expect(db[:misses].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(1)
      expect(db[:misses].where(zoom_level: z, tile_column: x + 1, tile_row: y).count).to eq(0)
    end
  end

  describe '.process_zoom' do
    include_context 'with database'

    let(:opts) { { method: :downsample_raster_tiles, args: { format: 'png', kernel: :linear }, minzoom: 1 } }

    it 'processes both candidates and misses for given zoom' do
      z = 5
      child_tile = create_test_png

      # Setup: candidate at (10, 20) and miss at (11, 20)
      db[:tiles].insert(zoom_level: z, tile_column: 10, tile_row: 20, tile_data: Sequel.blob(create_test_png), generated: 2)
      db[:misses].insert(zoom_level: z, tile_column: 11, tile_row: 20, ts: Time.now.to_i, status: 404)

      # Children for candidate (10, 20)
      [[20, 40], [21, 40], [20, 41], [21, 41]].each do |cx, cy|
        db[:tiles].insert(zoom_level: z + 1, tile_column: cx, tile_row: cy, tile_data: Sequel.blob(child_tile))
      end

      # Children for miss (11, 20)
      [[22, 40], [23, 40], [22, 41], [23, 41]].each do |cx, cy|
        db[:tiles].insert(zoom_level: z + 1, tile_column: cx, tile_row: cy, tile_data: Sequel.blob(child_tile))
      end

      described_class.process_zoom(z, db, opts)

      # Candidate should be regenerated
      expect(db[:tiles].where(zoom_level: z, tile_column: 10, tile_row: 20).get(:generated)).to eq(1)
      # Miss should be converted to tile
      expect(db[:tiles].where(zoom_level: z, tile_column: 11, tile_row: 20).get(:generated)).to eq(1)
      expect(db[:misses].where(zoom_level: z, tile_column: 11, tile_row: 20).count).to eq(0)
    end

    it 'works when no candidates or misses exist' do
      expect { described_class.process_zoom(5, db, opts) }.not_to raise_error
    end
  end
end
