# frozen_string_literal: true

require 'vips'

module VipsTileValidator
  # Validates tile data using Vips library
  # @param tile_data [String, nil] Binary tile data
  # @param check_transparency [Boolean] If true, analyzes alpha channel for transparency detection
  # @return [Symbol] :valid, :corrupted, or (if check_transparency=true) :transparent, :partial_transparent
  def self.validate(tile_data, check_transparency:)
    return :corrupted if tile_data.nil? || tile_data.empty?

    img = nil
    alpha = nil

    begin
      img = Vips::Image.new_from_buffer(tile_data, '')
      return :valid unless check_transparency
      return :valid unless img.bands == 4

      alpha = img[3]
      alpha_max = alpha.max
      alpha_min = alpha.min

      return :transparent if alpha_max == 0
      return :partial_transparent if alpha_min == 0 && alpha_max > 0
      :valid
    rescue Vips::Error
      :corrupted
    ensure
      img = nil
      alpha = nil
    end
  end
end
