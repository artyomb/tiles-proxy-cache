require 'ffi'
require 'chunky_png'

module LercFFI
  extend FFI::Library
  
  # Load compiled LERC C library via FFI
  ffi_lib File.join(__dir__, 'libLerc.so.4')
  
  # LERC API constants
  DT_FLOAT = 6
  LERC_OK = 0
  
  # Register C functions for Ruby calls - FFI bridges Ruby to C
  attach_function :lerc_getBlobInfo, [:pointer, :uint, :pointer, :pointer, :int, :int], :uint
  attach_function :lerc_decode, [:pointer, :uint, :int, :pointer, :int, :int, :int, :int, :uint, :pointer], :uint

  def self.get_blob_info(lerc_data)
    return nil if lerc_data.nil? || lerc_data.empty?
    
    # FFI memory pointers - allocate C memory for function parameters
    info_array = FFI::MemoryPointer.new(:uint, 11)
    data_range_array = FFI::MemoryPointer.new(:double, 3)
    input_buffer = FFI::MemoryPointer.from_string(lerc_data)
    
    # Call C function - FFI handles Ruby -> C conversion automatically
    status = lerc_getBlobInfo(input_buffer, lerc_data.bytesize, info_array, data_range_array, 11, 3)
    
    return nil unless status == LERC_OK
    
    # Read C memory back to Ruby arrays
    info = info_array.read_array_of_uint(11)
    ranges = data_range_array.read_array_of_double(3)
    
    {
      version: info[0], data_type: info[1], n_depth: info[2], n_cols: info[3], n_rows: info[4],
      n_bands: info[5], n_valid_pixels: info[6], blob_size: info[7], n_masks: info[8],
      n_depth2: info[9], n_uses_no_data: info[10], z_min: ranges[0], z_max: ranges[1], max_z_error: ranges[2]
    }
  rescue => e
    puts "LERC getBlobInfo failed: #{e.message}"
    nil
  end

  def self.decode_lerc_tile(lerc_data)
    # Get blob metadata first - LERC requires dimensions for decompression
    info = get_blob_info(lerc_data)
    return nil unless info
    
    # Allocate C memory buffers for input/output data
    input_buffer = FFI::MemoryPointer.from_string(lerc_data)
    output_buffer = FFI::MemoryPointer.new(:float, info[:n_cols] * info[:n_rows] * info[:n_bands])
    
    # Call LERC decompression - parameters from blob metadata ensure correct decoding
    status = lerc_decode(input_buffer, lerc_data.bytesize, 0, nil, 1, 
                        info[:n_cols], info[:n_rows], info[:n_bands], info[:data_type], output_buffer)
    
    # Convert C float array back to Ruby array
    status == LERC_OK ? output_buffer.read_array_of_float(info[:n_cols] * info[:n_rows] * info[:n_bands]) : nil
  rescue => e
    puts "LERC FFI decode failed: #{e.message}"
    nil
  end

  def self.lerc_to_mapbox_png(lerc_data)
    # Decompress LERC to elevation float array
    elevation_data = decode_lerc_tile(lerc_data)
    return nil unless elevation_data
    
    # Get tile dimensions for PNG creation
    info = get_blob_info(lerc_data)
    return nil unless info
    
    # Convert elevations to Mapbox Terrain-RGB format and create PNG
    elevation_to_mapbox(elevation_data)
      .then { |mapbox_data| create_mapbox_png(mapbox_data, info[:n_cols], info[:n_rows]) }
  rescue => e
    puts "Mapbox PNG creation failed: #{e.message}"
    nil
  end

  private

  def self.elevation_to_mapbox(elevation_data)
    # Mapbox Terrain-RGB formula: height = -10000 + ((R * 256 * 256 + G * 256 + B) * 0.1)
    # Encoding: code = (height + 10000) / 0.1
    elevation_data.map do |elevation|
      # Convert elevation to 24-bit integer using Mapbox formula
      code = ((elevation + 10000) / 0.1).to_i.clamp(0, 16777215)
      
      # Split into RGB components for PNG encoding
      [(code / 65536).floor, ((code / 256).floor) % 256, code % 256]
    end
  end

  def self.create_mapbox_png(mapbox_data, width, height)
    # ArcGIS 257x257 → MapLibre 256x256 (remove overlap pixels)
    target_size = (width == 257 && height == 257) ? 256 : width
    target_data = (width == 257 && height == 257) ? 
      mapbox_data.select.with_index { |_, i| (i % width < 256) && (i / width < 256) } : 
      mapbox_data
    
    ChunkyPNG::Image.new(target_size, target_size).tap do |image|
      target_data.each_with_index { |(r, g, b), i| image[i % target_size, i / target_size] = ChunkyPNG::Color.rgb(r, g, b) }
    end.to_blob
  end
end
