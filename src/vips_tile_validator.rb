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

  # Starts cleanup process for invalid tiles
  # @param route [Hash] Route configuration
  # @param source_name [String] Source name
  # @return [Boolean] true if started successfully
  def self.start_cleanup(route, source_name)
    unless route.dig(:validation, :enabled)
      raise "Validation is not enabled for source #{source_name}"
    end

    state = route[:validator_cleanup_state]
    if state&.dig(:running)
      raise "Cleanup is already running for source #{source_name}"
    end

    loader = route[:autoscan_loader]
    was_autoscan_running = loader&.enabled? && loader.running? ? loader.stop_completely : false

    db = route[:db]
    check_transparency = route.dig(:validation, :check_transparency)
    raise "validation.check_transparency must be specified when validation.enabled is true" if check_transparency.nil?

    total_count = db[:tiles].where(generated: 0).count

    cleanup_state = {
      running: true,
      thread: nil,
      stats: { processed: 0, invalid: 0, valid: 0, total: total_count },
      start_time: Time.now,
      was_autoscan_running: was_autoscan_running,
      loader: loader
    }

    route[:validator_cleanup_state] = cleanup_state

    cleanup_thread = Thread.new do
      begin
        cleanup_database(route, source_name, check_transparency, cleanup_state)
      rescue => e
        LOGGER.error("VipsTileValidator: cleanup error for #{source_name}: #{e.message}")
        LOGGER.debug("VipsTileValidator: backtrace: #{e.backtrace.join("\n")}")
      ensure
        cleanup_state[:running] = false
      end
    end

    if was_autoscan_running && loader&.enabled?
      Thread.new do
        begin
          loop do
            sleep 5
            break unless cleanup_thread.alive?
          end

          loader.restart if loader&.enabled?
        rescue => e
          LOGGER.error("VipsTileValidator: error resuming autoscan for #{source_name}: #{e.message}")
        end
      end
    end

    cleanup_state[:thread] = cleanup_thread

    LOGGER.info("VipsTileValidator: cleanup started for #{source_name}, total tiles: #{total_count}")
    true
  end

  # Main cleanup process
  # @param route [Hash] Route configuration
  # @param source_name [String] Source name
  # @param check_transparency [Boolean] Transparency check flag
  # @param state [Hash] Cleanup state
  def self.cleanup_database(route, source_name, check_transparency, state)
    db = route[:db]
    stats = state[:stats]

    tiles_coords = db[:tiles].where(generated: 0).select(:zoom_level, :tile_column, :tile_row).all
    idx = 0

    while idx < tiles_coords.size
      break unless state[:running]

      tile_coord = tiles_coords[idx]
      z = tile_coord[:zoom_level]
      x = tile_coord[:tile_column]
      tile_row = tile_coord[:tile_row]

      begin
        tile_data = db[:tiles].where(
          zoom_level: z,
          tile_column: x,
          tile_row: tile_row
        ).get(:tile_data)

        validation_result = validate(tile_data, check_transparency: check_transparency)

        if [:transparent, :corrupted].include?(validation_result)
          db.transaction do
            db[:tiles].where(
              zoom_level: z,
              tile_column: x,
              tile_row: tile_row
            ).delete

            reason = validation_result.to_s
            db[:misses].insert_conflict(
              target: [:zoom_level, :tile_column, :tile_row],
              update: {
                ts: Sequel[:excluded][:ts],
                reason: Sequel[:excluded][:reason],
                details: Sequel[:excluded][:details],
                status: Sequel[:excluded][:status]
              }
            ).insert(
              zoom_level: z,
              tile_column: x,
              tile_row: tile_row,
              ts: Time.now.to_i,
              reason: reason,
              details: "Tile is #{validation_result}",
              status: 200,
              response_body: nil
            )
          end
          stats[:invalid] += 1
        else
          stats[:valid] += 1
        end

        stats[:processed] += 1

        if stats[:processed] % 1000 == 0
          LOGGER.info("VipsTileValidator: cleanup progress for #{source_name}: processed #{stats[:processed]}/#{stats[:total]}, invalid: #{stats[:invalid]}, valid: #{stats[:valid]}")
        end
      rescue => e
        LOGGER.warn("VipsTileValidator: failed to process tile #{z}/#{x}/#{tile_row} for #{source_name}: #{e.message}")
        stats[:processed] += 1
      end

      idx += 1
    end

    LOGGER.info("VipsTileValidator: cleanup completed for #{source_name}: processed #{stats[:processed]}, invalid: #{stats[:invalid]}, valid: #{stats[:valid]}")
  end

  # Returns cleanup status
  # @param route [Hash] Route configuration
  # @return [Hash] Status information
  def self.cleanup_status(route)
    state = route[:validator_cleanup_state]
    return { running: false, processed: 0, invalid: 0, valid: 0, total: 0 } unless state

    {
      running: state[:running] || false,
      processed: state[:stats][:processed] || 0,
      invalid: state[:stats][:invalid] || 0,
      valid: state[:stats][:valid] || 0,
      total: state[:stats][:total] || 0,
      start_time: state[:start_time]
    }
  end

  # Stops cleanup process
  # @param route [Hash] Route configuration
  # @return [Boolean] true if stopped successfully
  def self.stop_cleanup(route)
    state = route[:validator_cleanup_state]
    unless state&.dig(:running)
      raise "Cleanup is not running"
    end

    state[:running] = false

    thread = state[:thread]
    if thread&.alive?
      thread.join(10)
      thread.kill if thread.alive?
    end

    true
  end
end
