# LERC Extension for Ruby

## Overview

`lerc_extension.cpp` is a Ruby C++ extension that provides conversion of LERC (Limited Error Raster Compression) data to Mapbox Terrain-RGB PNG format. The extension is integrated into the tile caching service and is used for processing elevation data received from ArcGIS services.

## Purpose

### Problem
ArcGIS services provide elevation data in LERC format — a specialized raster data compression format with controlled error bounds. For use in web applications, this data needs to be converted to a standard PNG format with height encoding in RGB channels.

### Solution
The extension performs LERC data decoding and converts it to Mapbox Terrain-RGB format, where:
- Height is encoded in a 24-bit RGB value
- Result is saved as a PNG image

#### Encoding and Decoding Formulas

**Decoding (RGB → height in meters):**
```
height = -10000 + ((R × 256²) + (G × 256) + B) × 0.1
```
where R, G, B are channel values in range 0…255

**Encoding (height h in m → R,G,B):**

1. Height h must fall within the range representable by a 24-bit number after offset (range corresponding to offset −10000 m and step 0.1 m; code value must be within 0…16777215)

2. Integer code is calculated:
```
code = round((h + 10000) / 0.1) = round((h + 10000) × 10)
```

3. Code is decomposed into bytes:
```
R = floor(code / 256²)
G = floor((code - R × 256²) / 256)
B = code - R × 256² - G × 256
```

**Constants:**
- `MAPBOX_OFFSET = 10000.0` - offset for negative heights
- `MAPBOX_SCALE = 0.1` - scaling coefficient (0.1 meter precision)
- `MAX_24BIT = 16777215` - maximum 24-bit value (2^24 - 1)

**Height range:** from -10,000 to +16,777,215 meters

## Technical Details

### Used Libraries

#### LERC (Esri)
[LERC](https://github.com/Esri/lerc) is an open-source library for raster data compression with controlled error bounds. Key characteristics:

- Supports various data types (int, float, double)
- Allows setting maximum error per pixel
- Provides high encoding/decoding speed
- Works with valid pixel masks
- Supports multi-channel data

The project uses LERC library version 4.0.0.

#### STB Image Write
`stb_image_write.h` is a header-only library for writing images in various formats (PNG, BMP, TGA, JPEG, HDR). The extension uses the `stbi_write_png_to_mem()` function to create PNG data in memory.

### Solution Architecture

#### Main Function
```cpp
extern "C" VALUE lerc_to_mapbox_png(VALUE /*self*/, VALUE lerc_data)
```

The function accepts a Ruby string with LERC data and returns a Ruby string with PNG data.

#### Algorithm

1. **Input Data Validation**
   - Type and size validation of input data
   - Validation through Ruby API `Check_Type()`

2. **LERC Metadata Extraction**
   - Image dimensions extraction (width, height, channels)
   - Data type validation (float expected)
   - Size validation through `lerc_getBlobInfo()`

3. **LERC Decoding**
   - Memory allocation for elevation data
   - Decoding through `lerc_decode()`
   - Decoding error handling

4. **RGB Conversion**
   - Application of Mapbox Terrain-RGB formula
   - Special case handling for 257×257 tiles (cropping to 256×256)
   - Using `std::clamp()` for value limiting

   **C++ implementation:**
   ```cpp
   // Calculate integer code: code = round((elevation + 10000) × 10)
   const int32_t code = std::clamp(
       static_cast<int32_t>((e + MAPBOX_OFFSET) / MAPBOX_SCALE), 0, MAX_24BIT);
   
   // Decompose into bytes (bitwise operations):
   *rgb_ptr++ = static_cast<std::uint8_t>((code >> 16) & 0xFF);  // R = floor(code / 256²)
   *rgb_ptr++ = static_cast<std::uint8_t>((code >> 8)  & 0xFF);  // G = floor((code - R×256²) / 256)
   *rgb_ptr++ = static_cast<std::uint8_t>( code        & 0xFF);  // B = code - R×256² - G×256
   ```

5. **PNG Creation**
   - PNG data generation through STB Image Write
   - RAII for memory management
   - Result return to Ruby

#### Memory Management

The extension uses modern C++ approaches for safe memory management:

- `std::vector` for dynamic arrays
- `std::unique_ptr` with custom deleter for PNG data
- RAII principles for automatic resource cleanup
- Memory pre-allocation for performance optimization

#### Error Handling

Multi-level error handling system is implemented:

- Input parameter validation
- LERC metadata validation
- Decoding error handling
- C++ exceptions with translation to Ruby exceptions
- Detailed error messages

## Integration

### Ruby API
```ruby
# LercFFI module provides method:
LercFFI.lerc_to_mapbox_png(lerc_data) # => png_data
```

### Service Usage
The extension is integrated into the main tile caching service (`config.ru`) and is automatically applied for processing LERC data from ArcGIS services.

## Performance

### Optimizations
- Memory pre-allocation (`reserve()`)
- Direct pointer arithmetic in critical loops
- Aggressive compiler flags (`-O3`, `-march=native`, `-flto`)
- RTTI disabled for size reduction

### Limitations
- Only float data type is supported
- Maximum elevation value is limited to 24-bit range
- Only single-channel elevation data processing

## Building

The extension is built through the standard Ruby `mkmf` mechanism using `extconf.rb`. Requires LERC library installed in the system.

### Dependencies
- Ruby 3.4+
- LERC 4.0.0
- STB Image Write (header-only library)
- C++23 compatible compiler
