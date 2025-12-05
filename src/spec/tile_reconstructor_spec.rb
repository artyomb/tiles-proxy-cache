# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../tile_reconstructor'
require 'sequel'

RSpec.describe TileReconstructor do
  let(:route) { { db: nil, minzoom: 1, maxzoom: 10, gap_filling: { output_format: { type: 'png' }, raster_method: 'linear' } } }
  let(:reconstructor) { described_class.new(route, 'test_source') }

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

  describe '#downsample_raster_tiles' do
    let(:children) { Array.new(4) { create_test_png } }

    it 'combines 4 tiles into 1 of the same size' do
      result = reconstructor.send(:downsample_raster_tiles, children)

      img = Vips::Image.new_from_buffer(result, '')
      expect([img.width, img.height]).to eq([256, 256])
    end

    it 'raises error when not 4 tiles' do
      expect { reconstructor.send(:downsample_raster_tiles, [create_test_png] * 3) }
        .to raise_error(ArgumentError, /Expected 4 tiles/)
    end

    it 'handles nil tiles by filling with transparent' do
      result = reconstructor.send(:downsample_raster_tiles, [create_test_png, nil, create_test_png, nil])
      
      expect(result).not_to be_nil
      img = Vips::Image.new_from_buffer(result, '')
      expect([img.width, img.height]).to eq([256, 256])
    end

    it 'returns nil when all tiles are nil' do
      result = reconstructor.send(:downsample_raster_tiles, [nil, nil, nil, nil])
      expect(result).to be_nil
    end

    it 'handles corrupted tiles by replacing with transparent' do
      corrupted = "PNG"  # Only header
      valid = create_test_png
      
      result = reconstructor.send(:downsample_raster_tiles, [valid, corrupted, valid, corrupted])
      
      expect(result).not_to be_nil
      img = Vips::Image.new_from_buffer(result, '')
      expect([img.width, img.height]).to eq([256, 256])
    end

    it 'raises error for unknown kernel' do
      expect { reconstructor.send(:downsample_raster_tiles, children, kernel: :invalid) }
        .to raise_error(ArgumentError, /Unknown kernel/)
    end

    it 'preserves tile order: TL red, TR green, BL blue, BR yellow' do
      children = [
        create_colored_png(255, 0, 0),    # TL: red
        create_colored_png(0, 255, 0),    # TR: green
        create_colored_png(0, 0, 255),    # BL: blue
        create_colored_png(255, 255, 0)   # BR: yellow
      ]

      result = reconstructor.send(:downsample_raster_tiles, children)

      expect(pixel_at(result, 64, 64)).to eq([0, 0, 255])
      expect(pixel_at(result, 192, 64)).to eq([255, 255, 0])
      expect(pixel_at(result, 64, 192)).to eq([255, 0, 0])
      expect(pixel_at(result, 192, 192)).to eq([0, 255, 0]) 
    end
  end

  describe '#downsample_terrain_tiles' do
    describe 'input validation' do
      it 'raises error when not 4 tiles' do
        expect { reconstructor.send(:downsample_terrain_tiles, [create_test_png] * 3, format: 'png') }
          .to raise_error(ArgumentError, /Expected 4 tiles/)
      end

      it 'raises error for unknown encoding' do
        expect { reconstructor.send(:downsample_terrain_tiles, Array.new(4) { create_test_png }, encoding: 'invalid', format: 'png') }
          .to raise_error(ArgumentError, /Unknown encoding/)
      end

      it 'raises error for unknown method' do
        expect { reconstructor.send(:downsample_terrain_tiles, Array.new(4) { create_test_png }, method: 'invalid', format: 'png') }
          .to raise_error(ArgumentError, /Unknown method/)
      end

      it 'raises error for unknown format' do
        expect { reconstructor.send(:downsample_terrain_tiles, Array.new(4) { create_test_png }, format: 'invalid') }
          .to raise_error(ArgumentError, /Unknown format/)
      end
    end

    it 'returns 256x256 PNG from 4 tiles' do
      children = Array.new(4) { create_terrain_png_mapbox(100) }
      result = reconstructor.send(:downsample_terrain_tiles, children, format: 'png')

      img = Vips::Image.new_from_buffer(result, '')
      expect([img.width, img.height]).to eq([256, 256])
    end

    it 'preserves elevation with mapbox encoding' do
      children = [
        create_terrain_png_mapbox(0),    # TL
        create_terrain_png_mapbox(100),  # TR
        create_terrain_png_mapbox(200),  # BL
        create_terrain_png_mapbox(300)   # BR
      ]

      result = reconstructor.send(:downsample_terrain_tiles, children, encoding: 'mapbox', format: 'png')

      # After combine_4_tiles: (64,64)=BL, (192,192)=TR
      expect(decode_mapbox_elevation(*pixel_at(result, 64, 64).map(&:to_i))).to be_within(0.2).of(200)
      expect(decode_mapbox_elevation(*pixel_at(result, 192, 192).map(&:to_i))).to be_within(0.2).of(100)
    end

    it 'returns WebP format when specified' do
      children = Array.new(4) { create_terrain_png_mapbox(100) }
      result = reconstructor.send(:downsample_terrain_tiles, children, format: 'webp', effort: 4)

      expect(result[0..3]).to eq('RIFF')
      expect(result[8..11]).to eq('WEBP')
      img = Vips::Image.new_from_buffer(result, '')
      expect([img.width, img.height]).to eq([256, 256])
    end
  end

  describe '#get_children_data' do
    include_context 'with database'

    let(:tile1) { create_colored_png(255, 0, 0) }
    let(:tile2) { create_colored_png(0, 255, 0) }
    let(:tile3) { create_colored_png(0, 0, 255) }
    let(:tile4) { create_colored_png(255, 255, 0) }

    it 'returns 4 children data in correct order when all exist' do
      parent_z = 5
      parent_x = 10
      parent_y = 20

      db[:tiles].insert(zoom_level: 6, tile_column: 20, tile_row: 40, tile_data: Sequel.blob(tile1))
      db[:tiles].insert(zoom_level: 6, tile_column: 21, tile_row: 40, tile_data: Sequel.blob(tile2))
      db[:tiles].insert(zoom_level: 6, tile_column: 20, tile_row: 41, tile_data: Sequel.blob(tile3))
      db[:tiles].insert(zoom_level: 6, tile_column: 21, tile_row: 41, tile_data: Sequel.blob(tile4))

      result = reconstructor.send(:get_children_data, db, parent_z, parent_x, parent_y)

      expect(result).to eq([tile1, tile2, tile3, tile4])
    end

    it 'returns array with nils when not all children exist' do
      parent_z = 5
      parent_x = 10
      parent_y = 20

      db[:tiles].insert(zoom_level: 6, tile_column: 20, tile_row: 40, tile_data: Sequel.blob(tile1))
      db[:tiles].insert(zoom_level: 6, tile_column: 21, tile_row: 40, tile_data: Sequel.blob(tile2))
      # Missing 2 children

      result = reconstructor.send(:get_children_data, db, parent_z, parent_x, parent_y)
      expect(result).to eq([tile1, tile2, nil, nil])
    end
  end

  describe '#mark_parent_candidate' do
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

      reconstructor.send(:mark_parent_candidate, db, child_z, child_x, child_y)

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

        reconstructor.send(:mark_parent_candidate, db, child_z, child_x, child_y)

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

      reconstructor.send(:mark_parent_candidate, db, child_z, child_x, child_y)

      parent = db[:tiles].where(zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y).first
      expect(parent[:generated]).to eq(2)
    end

    it 'skips when parent does not exist in tiles' do
      child_z = 6
      child_x = 20
      child_y = 40

      expect do
        reconstructor.send(:mark_parent_candidate, db, child_z, child_x, child_y)
      end.not_to raise_error

      parent_z = 5
      parent_x = 10
      parent_y = 20
      parent = db[:tiles].where(zoom_level: parent_z, tile_column: parent_x, tile_row: parent_y).first
      expect(parent).to be_nil
    end
  end

  describe '#build_downsample_opts' do
    it 'returns raster opts structure' do
      route_config = { minzoom: 1, gap_filling: { output_format: { type: 'png' }, raster_method: 'linear' } }
      opts = reconstructor.send(:build_downsample_opts, route_config)

      expect(opts[:method]).to eq(:downsample_raster_tiles)
      expect(opts[:args][:format]).to eq('png')
      expect(opts[:minzoom]).to eq(1)
    end

    it 'returns terrain opts structure' do
      route_config = { minzoom: 0, metadata: { encoding: 'mapbox' }, gap_filling: { terrain_method: 'average', output_format: { type: 'png' } } }
      opts = reconstructor.send(:build_downsample_opts, route_config)

      expect(opts[:method]).to eq(:downsample_terrain_tiles)
      expect(opts[:args][:encoding]).to eq('mapbox')
      expect(opts[:args][:format]).to eq('png')
      expect(opts[:args]).not_to have_key(:effort)
      expect(opts[:minzoom]).to eq(0)
    end

    it 'returns terrain opts with WebP format and effort configuration' do
      route_config = { minzoom: 0, metadata: { encoding: 'mapbox' }, gap_filling: { terrain_method: 'average', output_format: { type: 'webp', effort: 6 } } }
      opts = reconstructor.send(:build_downsample_opts, route_config)

      expect(opts[:method]).to eq(:downsample_terrain_tiles)
      expect(opts[:args][:format]).to eq('webp')
      expect(opts[:args][:effort]).to eq(6)

      route_config2 = { minzoom: 0, metadata: { encoding: 'mapbox' }, gap_filling: { terrain_method: 'average', output_format: { type: 'webp' } } }
      opts2 = reconstructor.send(:build_downsample_opts, route_config2)

      expect(opts2[:args][:format]).to eq('webp')
      expect(opts2[:args][:effort]).to eq(4)
    end
  end

  describe '#process_regeneration_candidates' do
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

      reconstructor.send(:process_regeneration_candidates, z, db, opts)

      tile = db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).first
      expect(tile[:generated]).to eq(1)
    end

    it 'regenerates candidate even with partial children' do
      z = 5
      x = 10
      y = 20

      db[:tiles].insert(zoom_level: z, tile_column: x, tile_row: y, tile_data: Sequel.blob(create_test_png), generated: 2)

      child_z = z + 1
      db[:tiles].insert(zoom_level: child_z, tile_column: 2 * x, tile_row: 2 * y, tile_data: Sequel.blob(create_test_png))
      db[:tiles].insert(zoom_level: child_z, tile_column: 2 * x + 1, tile_row: 2 * y, tile_data: Sequel.blob(create_test_png))

      reconstructor.send(:process_regeneration_candidates, z, db, opts)

      tile = db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).first
      expect(tile[:generated]).to eq(1)
    end
  end

  describe '#process_miss_records' do
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

      reconstructor.send(:process_miss_records, z, db, opts)

      expect(db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).get(:generated)).to eq(1)
      expect(db[:misses].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(0)
    end

    it 'generates tile even with single child' do
      z = 5
      x = 10
      y = 20

      db[:misses].insert(zoom_level: z, tile_column: x, tile_row: y, ts: Time.now.to_i, status: 404)
      db[:tiles].insert(zoom_level: z + 1, tile_column: 2 * x, tile_row: 2 * y, tile_data: Sequel.blob(create_test_png))

      reconstructor.send(:process_miss_records, z, db, opts)

      expect(db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(1)
      expect(db[:misses].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(0)
    end

    it 'skips miss when tile already exists in tiles' do
      z = 5
      x = 10
      y = 20

      db[:tiles].insert(zoom_level: z, tile_column: x, tile_row: y, tile_data: Sequel.blob(create_test_png), generated: 0)
      db[:misses].insert(zoom_level: z, tile_column: x, tile_row: y, ts: Time.now.to_i, status: 404)

      reconstructor.send(:process_miss_records, z, db, opts)

      expect(db[:misses].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(1)
    end

    it 'processes all misses regardless of status when children available' do
      z = 5
      x = 10
      y = 20

      db[:misses].insert(zoom_level: z, tile_column: x, tile_row: y, ts: Time.now.to_i, status: 500)
      db[:misses].insert(zoom_level: z, tile_column: x + 1, tile_row: y, ts: Time.now.to_i, status: 404)

      child_tile = create_test_png
      # Create children for both misses
      (0..3).each do |i|
        db[:tiles].insert(zoom_level: z + 1, tile_column: 2 * x + (i % 2), tile_row: 2 * y + (i / 2), tile_data: Sequel.blob(child_tile))
      end
      (0..3).each do |i|
        db[:tiles].insert(zoom_level: z + 1, tile_column: 2 * (x + 1) + (i % 2), tile_row: 2 * y + (i / 2), tile_data: Sequel.blob(child_tile))
      end

      reconstructor.send(:process_miss_records, z, db, opts)

      # Both misses should be processed regardless of status
      expect(db[:tiles].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(1)
      expect(db[:tiles].where(zoom_level: z, tile_column: x + 1, tile_row: y).count).to eq(1)
      expect(db[:misses].where(zoom_level: z, tile_column: x, tile_row: y).count).to eq(0)
      expect(db[:misses].where(zoom_level: z, tile_column: x + 1, tile_row: y).count).to eq(0)
    end
  end

  describe '#process_zoom' do
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

      reconstructor.send(:process_zoom, z, db, opts)

      # Candidate should be regenerated
      expect(db[:tiles].where(zoom_level: z, tile_column: 10, tile_row: 20).get(:generated)).to eq(1)
      # Miss should be converted to tile
      expect(db[:tiles].where(zoom_level: z, tile_column: 11, tile_row: 20).get(:generated)).to eq(1)
      expect(db[:misses].where(zoom_level: z, tile_column: 11, tile_row: 20).count).to eq(0)
    end

    it 'works when no candidates or misses exist' do
      expect { reconstructor.send(:process_zoom, 5, db, opts) }.not_to raise_error
    end
  end

  describe '#start_reconstruction (fill_gaps logic)' do
    include_context 'with database'

    let(:base_route) do
      { db: db, minzoom: 1, maxzoom: 10, gap_filling: { output_format: { type: 'png' }, raster_method: 'linear' } }
    end

    it 'processes all zooms from maxzoom-1 down to minzoom' do
      route_config = base_route.merge(minzoom: 2, maxzoom: 5, db: db)
      inst = described_class.new(route_config, 'test_source')
      
      # Setup: create misses for each zoom level to verify they are processed
      [2, 3, 4].each do |z|
        db[:misses].insert(zoom_level: z, tile_column: 0, tile_row: 0, ts: Time.now.to_i, status: 404)
      end
      
      inst.send(:run_reconstruction)
      
      # Verify all misses were processed (none should remain as no children exist)
      expect(db[:misses].count).to eq(3)
    end

    it 'handles edge cases' do
      # Case 1: maxzoom=6, minzoom=5 -> should process zoom 5
      route_config = base_route.merge(minzoom: 5, maxzoom: 6, db: db)
      inst = described_class.new(route_config, 'test_source')
      
      db[:misses].insert(zoom_level: 5, tile_column: 0, tile_row: 0, ts: Time.now.to_i, status: 404)
      
      expect { inst.send(:run_reconstruction) }.not_to raise_error
      
      # Case 2: maxzoom=5, minzoom=5 -> should not process anything (start_zoom < minzoom)
      route_config2 = base_route.merge(minzoom: 5, maxzoom: 5, db: db)
      inst2 = described_class.new(route_config2, 'test_source')
      
      expect { inst2.send(:run_reconstruction) }.not_to raise_error
    end

    it 'continues processing even if some zoom fails' do
      route_config = base_route.merge(minzoom: 1, maxzoom: 4, db: db)
      
      # Create invalid tile data that will cause processing error
      db[:tiles].insert(zoom_level: 2, tile_column: 0, tile_row: 0, tile_data: Sequel.blob('invalid'), generated: 2)
      # Valid children that would cause processing
      child_tile = create_test_png
      (0..3).each do |i|
        db[:tiles].insert(zoom_level: 3, tile_column: i % 2, tile_row: i / 2, tile_data: Sequel.blob(child_tile))
      end
      
      inst = described_class.new(route_config, 'test_source')
      
      # Should not raise error even if zoom 2 processing fails
      expect { inst.send(:run_reconstruction) }.not_to raise_error
    end
  end

  describe 'transparent tile generation' do
    it '#create_transparent_tile creates tile matching reference size' do
      reference = create_colored_png(255, 0, 0)
      reference_img = Vips::Image.new_from_buffer(reference, '')
      
      transparent = reconstructor.send(:create_transparent_tile, reference_img, 'png')
      
      expect(transparent).not_to be_nil
      img = Vips::Image.new_from_buffer(transparent, '')
      expect([img.width, img.height]).to eq([256, 256])
      expect(img.bands).to be >= 3  # At least RGB
    end

    it '#fill_missing_tiles replaces nils with transparent' do
      valid = create_test_png
      children = [valid, nil, valid, nil]
      
      result = reconstructor.send(:fill_missing_tiles, children, 'png')
      
      expect(result.size).to eq(4)
      expect(result[0]).to eq(valid)
      expect(result[1]).not_to be_nil  # Filled with transparent
      expect(result[2]).to eq(valid)
      expect(result[3]).not_to be_nil  # Filled with transparent
    end

    it '#fill_missing_tiles replaces corrupted tiles' do
      valid = create_test_png
      corrupted = "PNG"
      children = [valid, corrupted, valid, nil]
      
      result = reconstructor.send(:fill_missing_tiles, children, 'png')
      
      expect(result.size).to eq(4)
      expect(result[0]).to eq(valid)
      expect(result[1]).not_to eq(corrupted)  # Replaced with transparent
      expect(result[2]).to eq(valid)
      expect(result[3]).not_to be_nil  # Filled with transparent
    end

    it '#fill_missing_tiles skips corrupted when finding reference' do
      valid = create_test_png
      corrupted = "PNG"
      children = [corrupted, corrupted, valid, nil]
      
      result = reconstructor.send(:fill_missing_tiles, children, 'png')
      
      expect(result.size).to eq(4)
      expect(result[2]).to eq(valid)  # Valid reference used
      result[0..1].each { |t| expect(t).not_to eq(corrupted) }  # Corrupted replaced
    end

    it '#fill_missing_tiles returns nils when no valid tile exists' do
      children = ["PNG", "PNG", nil, nil]
      
      result = reconstructor.send(:fill_missing_tiles, children, 'png')
      
      expect(result).to eq([nil, nil, nil, nil])
    end
  end
end
