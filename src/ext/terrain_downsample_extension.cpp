#include "ruby.h"
#include <png.h>
#include <vector>
#include <cstdint>
#include <stdexcept>
#include <cmath>
#include <string_view>
#include <algorithm>
#include <array>
#include <climits>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// Mapbox Terrain RGB encoding constants
constexpr double MAPBOX_TERRAIN_RGB_OFFSET = 10000.0;
constexpr double MAPBOX_TERRAIN_RGB_SCALE = 0.1;
constexpr int32_t MAPBOX_TERRAIN_RGB_MAX_24BIT = 16777215;

// Terrarium encoding constants
constexpr float TERRARIUM_OFFSET = 32768.0f;

constexpr float decode_mapbox_terrain_rgb(std::uint8_t r, std::uint8_t g, std::uint8_t b) noexcept {
    return -MAPBOX_TERRAIN_RGB_OFFSET + ((r * 256 * 256) + (g * 256) + b) * MAPBOX_TERRAIN_RGB_SCALE;
}

constexpr float decode_terrarium(std::uint8_t r, std::uint8_t g, std::uint8_t b) noexcept {
    return (r * 256 + g + b / 256.0f) - TERRARIUM_OFFSET;
}

constexpr void encode_mapbox_terrain_rgb(float elevation, std::uint8_t& r, std::uint8_t& g, std::uint8_t& b) noexcept {
    const int32_t code = std::clamp(
        static_cast<int32_t>(std::round((elevation + MAPBOX_TERRAIN_RGB_OFFSET) / MAPBOX_TERRAIN_RGB_SCALE)),
        0, MAPBOX_TERRAIN_RGB_MAX_24BIT);
    r = static_cast<std::uint8_t>((code >> 16) & 0xFF);
    g = static_cast<std::uint8_t>((code >> 8) & 0xFF);
    b = static_cast<std::uint8_t>(code & 0xFF);
}

void encode_terrarium(float elevation, std::uint8_t& r, std::uint8_t& g, std::uint8_t& b) noexcept {
    const float value = elevation + TERRARIUM_OFFSET;
    const float H = std::floor(value);
    const float F = value - H;
    const int32_t H_int = static_cast<int32_t>(H);
    r = static_cast<std::uint8_t>((H_int >> 8) & 0xFF);
    g = static_cast<std::uint8_t>(H_int & 0xFF);
    b = static_cast<std::uint8_t>(std::round(F * 256.0f));
}

struct PngImage {
    png_image image{};
    PngImage() { image.version = PNG_IMAGE_VERSION; }
    ~PngImage() { png_image_free(&image); }
    PngImage(const PngImage&) = delete;
    PngImage& operator=(const PngImage&) = delete;
};

struct PngInfo {
    int width;
    int height;
    std::vector<std::uint8_t> rgb_data;
};

PngInfo decompress_png_to_rgb(VALUE png_data) {
    PngImage png;
    
    if (!png_image_begin_read_from_memory(&png.image, RSTRING_PTR(png_data), RSTRING_LEN(png_data))) {
        rb_raise(rb_eRuntimeError, "Failed to read PNG: invalid or corrupted data");
    }
    
    if (png.image.format != PNG_FORMAT_RGB) {
        rb_raise(rb_eRuntimeError, "Invalid PNG format: expected RGB, got %d", png.image.format);
    }
    
    const int width = static_cast<int>(png.image.width);
    const int height = static_cast<int>(png.image.height);
    
    std::vector<std::uint8_t> rgb_data(PNG_IMAGE_SIZE(png.image));
    if (!png_image_finish_read(&png.image, nullptr, rgb_data.data(), 0, nullptr)) {
        rb_raise(rb_eRuntimeError, "Failed to decode PNG data");
    }
    
    return {width, height, std::move(rgb_data)};
}

VALUE create_png_from_rgb(const std::vector<std::uint8_t>& rgb, int width, int height) {
    int png_len = 0;
    unsigned char* png_data = stbi_write_png_to_mem(rgb.data(), width * 3, width, height, 3, &png_len);
    
    if (!png_data) {
        rb_raise(rb_eRuntimeError, "PNG creation failed");
    }
    
    VALUE result = rb_str_new(reinterpret_cast<const char*>(png_data), static_cast<long>(png_len));
    std::free(png_data);
    
    return result;
}

extern "C" VALUE downsample_png(VALUE /*self*/, VALUE png_data, VALUE target_size_val, VALUE encoding_type_val) {
    try {
        Check_Type(png_data, T_STRING);
        Check_Type(target_size_val, T_FIXNUM);
        Check_Type(encoding_type_val, T_STRING);
        
        if (RSTRING_LEN(png_data) == 0) {
            rb_raise(rb_eArgError, "Empty PNG data");
        }
        
        const int target_size = NUM2INT(target_size_val);
        if (target_size <= 0 || target_size > 1024) {
            rb_raise(rb_eArgError, "Invalid target size: %d (must be 1-1024)", target_size);
        }
        
        const std::string_view encoding_type{RSTRING_PTR(encoding_type_val),
                                            static_cast<size_t>(RSTRING_LEN(encoding_type_val))};
        
        bool is_terrarium = (encoding_type == "terrarium");
        if (!is_terrarium && encoding_type != "mapbox") {
            rb_raise(rb_eArgError, "Unknown encoding type: %s (expected 'mapbox' or 'terrarium')", encoding_type.data());
        }
        
        PngInfo png_info = decompress_png_to_rgb(png_data);
        const int source_width = png_info.width;
        const int source_height = png_info.height;
        
        if (source_width <= target_size && source_height <= target_size) {
            return png_data;
        }
        
        const int scale_factor = source_width / target_size;
        const std::size_t output_size = static_cast<std::size_t>(target_size) * target_size * 3u;
        std::vector<std::uint8_t> output_rgb(output_size);
        
        std::uint8_t* output_ptr = output_rgb.data();
        const std::uint8_t* input_ptr = png_info.rgb_data.data();
        
        for (int out_y = 0; out_y < target_size; ++out_y) {
            for (int out_x = 0; out_x < target_size; ++out_x) {
                const int src_x = out_x * scale_factor;
                const int src_y = out_y * scale_factor;
                
                float sum_elevation = 0.0f;
                int count = 0;
                
                for (int dy = 0; dy < scale_factor; ++dy) {
                    for (int dx = 0; dx < scale_factor; ++dx) {
                        const int px = src_x + dx;
                        const int py = src_y + dy;
                        const int idx = (py * source_width + px) * 3;
                        
                        const std::uint8_t r = input_ptr[idx];
                        const std::uint8_t g = input_ptr[idx + 1];
                        const std::uint8_t b = input_ptr[idx + 2];
                        
                        float elevation;
                        if (is_terrarium) {
                            elevation = decode_terrarium(r, g, b);
                        } else {
                            elevation = decode_mapbox_terrain_rgb(r, g, b);
                        }
                        
                        sum_elevation += elevation;
                        ++count;
                    }
                }
                
                const float avg_elevation = sum_elevation / static_cast<float>(count);
                
                std::uint8_t r, g, b;
                if (is_terrarium) {
                    encode_terrarium(avg_elevation, r, g, b);
                } else {
                    encode_mapbox_terrain_rgb(avg_elevation, r, g, b);
                }
                
                *output_ptr++ = r;
                *output_ptr++ = g;
                *output_ptr++ = b;
            }
        }
        
        return create_png_from_rgb(output_rgb, target_size, target_size);
        
    } catch (const std::exception& e) {
        rb_raise(rb_eRuntimeError, "C++ exception: %s", e.what());
    } catch (...) {
        rb_raise(rb_eRuntimeError, "Unknown C++ exception occurred");
    }
}

extern "C" void Init_terrain_downsample_extension(void) {
    VALUE TerrainDownsampleFFI = rb_define_module("TerrainDownsampleFFI");
    rb_define_singleton_method(TerrainDownsampleFFI, "downsample_png", downsample_png, 3);
}

