# frozen_string_literal: true

require 'logger'
require 'sequel'
require 'tmpdir'
require 'vips'

LOGGER = Logger.new(File::NULL) unless defined?(LOGGER)

def otl_span(*)
  yield nil
end

require_relative '../tile_persistence'
require_relative '../tile_reconstructor'

RSpec.describe TileReconstructor do
  def create_image(color, width: 256, height: 256)
    Vips::Image.black(width, height).new_from_image(color).cast(:uchar)
  end

  def opaque_png(color)
    create_image([*color, 255]).write_to_buffer('.png')
  end

  def partial_png(color)
    opaque_left = create_image([*color, 255], width: 128)
    transparent_right = create_image([0, 0, 0, 0], width: 128)
    opaque_left.join(transparent_right, :horizontal).write_to_buffer('.png')
  end

  def opaque_webp(color)
    create_image([*color, 255]).write_to_buffer('.webp', Q: 50, lossless: false)
  end

  def partial_webp(color)
    opaque_left = create_image([*color, 255], width: 128)
    transparent_right = create_image([0, 0, 0, 0], width: 128)
    opaque_left.join(transparent_right, :horizontal).write_to_buffer('.webp', Q: 50, lossless: false)
  end

  def terrain_png(elevation)
    code = ((elevation + 10_000) / 0.1).round.clamp(0, 16_777_215)
    color = [(code >> 16) & 0xff, (code >> 8) & 0xff, code & 0xff]
    create_image(color).write_to_buffer('.png')
  end

  def decode_mapbox_elevation(pixel)
    red, green, blue = pixel.first(3)
    -10_000.0 + (red * 256 * 256 + green * 256 + blue) * 0.1
  end

  def pixel_at(blob, x, y)
    Vips::Image.new_from_buffer(blob, '').getpoint(x, y).map(&:to_i)
  end

  def insert_tile(db, z:, x:, y:, data:, generated: 0, updated_at: Time.now.utc - 120)
    db[:tiles].insert(
      zoom_level: z,
      tile_column: x,
      tile_row: y,
      tile_data: Sequel.blob(data),
      generated: generated,
      updated_at: updated_at
    )
  end

  def insert_children(db, parent_z:, x:, y:, data:, updated_at: Time.now.utc - 120)
    [[2 * x, 2 * y], [2 * x + 1, 2 * y], [2 * x, 2 * y + 1], [2 * x + 1, 2 * y + 1]].each do |cx, cy|
      insert_tile(db, z: parent_z + 1, x: cx, y: cy, data: data, updated_at: updated_at)
    end
  end

  def run_zoom(reconstructor, z:, db:, route:, last_run: nil, cutoff: nil)
    reconstructor.instance_variable_set(:@running, true)
    opts = reconstructor.send(:build_downsample_opts, route)
    reconstructor.send(:process_zoom_level, z, db, opts, route[:minzoom], route[:maxzoom], last_run, cutoff)
  ensure
    reconstructor.instance_variable_set(:@running, false)
  end

  around do |example|
    Dir.mktmpdir('tile-reconstructor-spec') do |dir|
      @db = Sequel.connect("sqlite://#{File.join(dir, 'test.mbtiles')}")
      @db.create_table(:metadata) do
        String :name, null: false
        String :value
        unique :name
      end
      @db.create_table(:tiles) do
        Integer :zoom_level, null: false
        Integer :tile_column, null: false
        Integer :tile_row, null: false
        File :tile_data, null: false
        Integer :generated, default: 0
        DateTime :updated_at, default: Sequel.lit("datetime('now', 'utc')")
        unique [:zoom_level, :tile_column, :tile_row]
      end
      @db.create_table(:misses) do
        Integer :zoom_level, null: false
        Integer :tile_column, null: false
        Integer :tile_row, null: false
        Integer :ts, null: false
        String :reason
        String :details
        Integer :status
        File :response_body
        primary_key [:zoom_level, :tile_column, :tile_row]
      end

      example.run
    ensure
      @db&.disconnect
    end
  end

  let(:db) { @db }
  let(:route) do
    {
      db: db,
      minzoom: 2,
      maxzoom: 5,
      metadata: {},
      gap_filling: {
        output_format: { type: 'png' },
        raster_method: 'nearest'
      }
    }
  end
  let(:reconstructor) { described_class.new(route, 'test_source') }

  describe '#downsample_raster_tiles' do
    let(:children) { Array.new(4) { opaque_png([0, 0, 0]) } }

    it 'combines four tiles into one tile of the original dimensions' do
      result = reconstructor.send(:downsample_raster_tiles, children)
      image = Vips::Image.new_from_buffer(result, '')

      expect([image.width, image.height]).to eq([256, 256])
    end

    it 'fills missing children with transparent placeholders' do
      result = reconstructor.send(:downsample_raster_tiles, [children[0], nil, children[2], nil])
      image = Vips::Image.new_from_buffer(result, '')

      expect([image.width, image.height]).to eq([256, 256])
      expect(image.bands).to eq(4)
    end

    it 'returns nil when every child is missing' do
      expect(reconstructor.send(:downsample_raster_tiles, [nil, nil, nil, nil])).to be_nil
    end

    it 'uses transparent placeholders for corrupted children' do
      result = reconstructor.send(:downsample_raster_tiles, [children[0], 'PNG', children[2], 'PNG'])

      expect(Vips::Image.new_from_buffer(result, '').bands).to eq(4)
    end

    it 'rejects an incorrect child count' do
      expect { reconstructor.send(:downsample_raster_tiles, children.first(3)) }
        .to raise_error(ArgumentError, /Expected 4 tiles/)
    end

    it 'rejects an unknown interpolation kernel' do
      expect { reconstructor.send(:downsample_raster_tiles, children, kernel: :invalid) }
        .to raise_error(ArgumentError, /Unknown kernel/)
    end
  end

  describe '#downsample_terrain_tiles' do
    it 'validates child count, encoding, method, and format' do
      children = Array.new(4) { terrain_png(100) }

      expect { reconstructor.send(:downsample_terrain_tiles, children.first(3), format: 'png') }
        .to raise_error(ArgumentError, /Expected 4 tiles/)
      expect { reconstructor.send(:downsample_terrain_tiles, children, encoding: 'invalid', format: 'png') }
        .to raise_error(ArgumentError, /Unknown encoding/)
      expect { reconstructor.send(:downsample_terrain_tiles, children, method: 'invalid', format: 'png') }
        .to raise_error(ArgumentError, /Unknown method/)
      expect { reconstructor.send(:downsample_terrain_tiles, children, format: 'invalid') }
        .to raise_error(ArgumentError, /Unknown format/)
    end

    it 'returns a 256x256 PNG' do
      result = reconstructor.send(:downsample_terrain_tiles, Array.new(4) { terrain_png(100) }, format: 'png')
      image = Vips::Image.new_from_buffer(result, '')

      expect([image.width, image.height]).to eq([256, 256])
    end

    it 'preserves Mapbox elevation and TMS child placement' do
      children = [terrain_png(0), terrain_png(100), terrain_png(200), terrain_png(300)]
      result = reconstructor.send(
        :downsample_terrain_tiles,
        children,
        encoding: 'mapbox',
        method: 'nearest',
        format: 'png'
      )

      expect(decode_mapbox_elevation(pixel_at(result, 64, 64))).to be_within(0.2).of(200)
      expect(decode_mapbox_elevation(pixel_at(result, 192, 192))).to be_within(0.2).of(100)
    end

    it 'encodes WebP output' do
      result = reconstructor.send(
        :downsample_terrain_tiles,
        Array.new(4) { terrain_png(100) },
        format: 'webp',
        effort: 4
      )
      image = Vips::Image.new_from_buffer(result, '')

      expect(result.byteslice(0, 4)).to eq('RIFF')
      expect(result.byteslice(8, 4)).to eq('WEBP')
      expect([image.width, image.height]).to eq([256, 256])
    end
  end

  describe 'transparent placeholders' do
    it 'creates a transparent tile matching the reference dimensions' do
      reference = Vips::Image.new_from_buffer(opaque_png([255, 0, 0]), '')
      transparent = reconstructor.send(:create_transparent_tile, reference, 'png')
      image = Vips::Image.new_from_buffer(transparent, '')

      expect([image.width, image.height]).to eq([256, 256])
      expect(VipsTileValidator.validate(transparent, check_transparency: true)).to eq(:transparent)
    end

    it 'replaces nil and corrupted values while preserving valid children' do
      valid = opaque_png([255, 0, 0])
      result = reconstructor.send(:fill_missing_tiles, [valid, nil, 'PNG', valid], 'png')

      expect(result.values_at(0, 3)).to eq([valid, valid])
      expect(result[1]).not_to be_nil
      expect(result[2]).not_to eq('PNG')
      expect(result.values_at(1, 2)).to all(
        satisfy { |blob| VipsTileValidator.validate(blob, check_transparency: true) == :transparent }
      )
    end

    it 'returns nil placeholders when no reference child can be decoded' do
      expect(reconstructor.send(:fill_missing_tiles, ['PNG', 'PNG', nil, nil], 'png'))
        .to eq([nil, nil, nil, nil])
    end
  end

  describe 'upstream tile persistence' do
    it 'replaces a stale positive marker for an accepted partial tile and resets an opaque tile to original' do
      insert_tile(db, z: 3, x: 2, y: 3, data: opaque_png([0, 0, 255]), generated: 4)

      TilePersistence.save_upstream_tile(
        db: db,
        zoom_level: 3,
        tile_column: 2,
        tile_row: 3,
        tile_data: partial_png([255, 0, 0]),
        validation_result: :partial_transparent
      )
      expect(db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).get(:generated)).to eq(-5)

      TilePersistence.save_upstream_tile(
        db: db,
        zoom_level: 3,
        tile_column: 2,
        tile_row: 3,
        tile_data: opaque_png([0, 0, 255]),
        validation_result: :valid
      )
      expect(db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).get(:generated)).to eq(0)
    end

    it 'keeps validation-disabled writes in the original state' do
      TilePersistence.save_upstream_tile(
        db: db,
        zoom_level: 3,
        tile_column: 2,
        tile_row: 3,
        tile_data: partial_png([255, 0, 0])
      )

      expect(db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).get(:generated)).to eq(0)
    end
  end

  describe 'monotonic gap filling' do
    it 'rebuilds partial generated=4 with the same child count and composites parent pixels over children' do
      insert_tile(db, z: 3, x: 2, y: 3, data: partial_png([255, 0, 0]), generated: 4)
      insert_children(db, parent_z: 3, x: 2, y: 3, data: opaque_png([0, 255, 0]))

      expect(run_zoom(reconstructor, z: 4, db: db, route: route)).to be(true)

      tile = db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).first
      expect(tile[:generated]).to eq(4)
      expect(pixel_at(tile[:tile_data], 32, 128).first(3)).to eq([255, 0, 0])
      expect(pixel_at(tile[:tile_data], 224, 128).first(3)).to eq([0, 255, 0])
      expect(VipsTileValidator.validate(tile[:tile_data], check_transparency: true)).to eq(:valid)
    end

    it 'rebuilds the production WebP shape with configured encoder options' do
      webp_route = route.merge(
        gap_filling: {
          output_format: { type: 'webp', quality: 50, lossless: false },
          raster_method: 'nearest'
        }
      )
      webp_reconstructor = described_class.new(webp_route, 'test_source')
      insert_tile(db, z: 3, x: 2, y: 3, data: partial_webp([255, 0, 0]), generated: 4)
      insert_children(db, parent_z: 3, x: 2, y: 3, data: opaque_webp([0, 255, 0]))

      expect(run_zoom(webp_reconstructor, z: 4, db: db, route: webp_route)).to be(true)

      tile = db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).first
      expect(tile[:tile_data].byteslice(0, 4)).to eq('RIFF')
      expect(pixel_at(tile[:tile_data], 32, 128).first(3)).to all(be_between(0, 255))
      expect(pixel_at(tile[:tile_data], 32, 128).first).to be > 200
      expect(pixel_at(tile[:tile_data], 224, 128)[1]).to be > 200
      expect(VipsTileValidator.validate(tile[:tile_data], check_transparency: true)).to eq(:valid)
    end

    it 'uses a partial -5 target as its own incremental candidate and cascades current-run output below the cutoff' do
      last_run = Time.now.utc - 60
      old_children_time = last_run - 60
      db[:metadata].insert(name: 'reconstruction_last_run', value: last_run.iso8601(6))
      insert_tile(
        db,
        z: 3,
        x: 2,
        y: 3,
        data: partial_png([255, 0, 0]),
        generated: -5,
        updated_at: old_children_time
      )
      insert_children(
        db,
        parent_z: 3,
        x: 2,
        y: 3,
        data: opaque_png([0, 255, 0]),
        updated_at: old_children_time
      )

      reconstructor.instance_variable_set(:@running, true)
      reconstructor.instance_variable_set(:@reconstruction_mode, :incremental)
      expect(reconstructor.send(:run_reconstruction)).to be(true)

      target = db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).first
      expect(VipsTileValidator.validate(target[:tile_data], check_transparency: true)).to eq(:valid)
      expect(db[:tiles].where(zoom_level: 2, tile_column: 1, tile_row: 1).count).to eq(1)
    ensure
      reconstructor.instance_variable_set(:@running, false)
    end

    it 'retains an opaque target without rewriting it or dirtying its parent' do
      parent_data = opaque_png([0, 0, 255])
      parent_updated_at = Time.now.utc - 300
      insert_tile(db, z: 2, x: 1, y: 1, data: partial_png([255, 0, 0]), generated: 2)
      insert_tile(db, z: 3, x: 2, y: 3, data: parent_data, generated: 4, updated_at: parent_updated_at)
      insert_children(db, parent_z: 3, x: 2, y: 3, data: opaque_png([0, 255, 0]))
      stored_updated_at = db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).get(:updated_at)

      expect(run_zoom(reconstructor, z: 4, db: db, route: route)).to be(true)

      parent = db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).first
      expect(parent[:tile_data]).to eq(parent_data)
      expect(parent[:updated_at]).to eq(stored_updated_at)
      expect(db[:tiles].where(zoom_level: 2, tile_column: 1, tile_row: 1).get(:generated)).to eq(2)
    end

    it 'clears an opaque legacy -5 target when children are available' do
      insert_tile(db, z: 3, x: 2, y: 3, data: opaque_png([0, 0, 255]), generated: -5)
      insert_children(db, parent_z: 3, x: 2, y: 3, data: opaque_png([0, 255, 0]))

      expect(run_zoom(reconstructor, z: 4, db: db, route: route)).to be(true)
      expect(db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).get(:generated)).to eq(4)
    end

    it 'preserves TMS child ordering while downsampling' do
      children = [
        opaque_png([255, 0, 0]),
        opaque_png([0, 255, 0]),
        opaque_png([0, 0, 255]),
        opaque_png([255, 255, 0])
      ]

      result = reconstructor.send(:downsample_raster_tiles, children, format: 'png', kernel: :nearest)

      expect(pixel_at(result, 64, 64).first(3)).to eq([0, 0, 255])
      expect(pixel_at(result, 192, 64).first(3)).to eq([255, 255, 0])
      expect(pixel_at(result, 64, 192).first(3)).to eq([255, 0, 0])
      expect(pixel_at(result, 192, 192).first(3)).to eq([0, 255, 0])
    end
  end

  describe 'incremental watermark' do
    it 'does not advance after a zoom-level failure' do
      old_watermark = Time.now.utc - 3600
      db[:metadata].insert(name: 'reconstruction_last_run', value: old_watermark.iso8601(6))
      allow(reconstructor).to receive(:process_zoom_level).and_return(false)
      reconstructor.instance_variable_set(:@running, true)
      reconstructor.instance_variable_set(:@reconstruction_mode, :incremental)

      expect(reconstructor.send(:run_reconstruction)).to be(false)
      expect(db[:metadata].where(name: 'reconstruction_last_run').get(:value)).to eq(old_watermark.iso8601(6))
    ensure
      reconstructor.instance_variable_set(:@running, false)
    end

    it 'leaves writes newer than the run cutoff eligible for the next run' do
      old_watermark = Time.now.utc - 3600
      future_write = Time.now.utc + 60
      db[:metadata].insert(name: 'reconstruction_last_run', value: old_watermark.iso8601(6))
      insert_tile(db, z: 4, x: 4, y: 6, data: opaque_png([0, 255, 0]), updated_at: future_write)
      reconstructor.instance_variable_set(:@running, true)
      reconstructor.instance_variable_set(:@reconstruction_mode, :incremental)

      expect(reconstructor.send(:run_reconstruction)).to be(true)
      expect(db[:tiles].where(zoom_level: 3, tile_column: 2, tile_row: 3).count).to eq(0)

      saved_watermark = Time.parse(db[:metadata].where(name: 'reconstruction_last_run').get(:value))
      next_run_tiles = reconstructor.send(:load_tiles_for_zoom, 4, db, saved_watermark, future_write + 60)
      expect(next_run_tiles.map { |tile| [tile[:tile_column], tile[:tile_row]] }).to include([4, 6])
    ensure
      reconstructor.instance_variable_set(:@running, false)
    end
  end
end
