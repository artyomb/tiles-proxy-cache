# frozen_string_literal: true

require 'sequel'

module TilePersistence
  PENDING_RECONSTRUCTION = -5

  def self.save_upstream_tile(db:, zoom_level:, tile_column:, tile_row:, tile_data:, validation_result: nil)
    generated = validation_result == :partial_transparent ? PENDING_RECONSTRUCTION : 0

    db[:tiles].insert_conflict(
      target: [:zoom_level, :tile_column, :tile_row],
      update: {
        tile_data: Sequel[:excluded][:tile_data],
        generated: Sequel[:excluded][:generated],
        updated_at: Sequel.lit("datetime('now', 'utc')")
      }
    ).insert(
      zoom_level: zoom_level,
      tile_column: tile_column,
      tile_row: tile_row,
      tile_data: Sequel.blob(tile_data),
      generated: generated,
      updated_at: Sequel.lit("datetime('now', 'utc')")
    )

    generated
  end
end
