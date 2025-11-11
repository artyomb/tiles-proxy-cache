#include "ruby.h"
#include <png.h>
#include <vector>
#include <cstdint>
#include <cmath>
#include <string_view>
#include <algorithm>
#include <limits>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

constexpr double MAPBOX_TERRAIN_RGB_OFFSET = 10000.0;
constexpr double MAPBOX_TERRAIN_RGB_SCALE = 0.1;
constexpr int32_t MAPBOX_TERRAIN_RGB_MAX_24BIT = 16777215;

constexpr float TERRARIUM_OFFSET = 32768.0f;

enum class DownsampleMethod {
    Average,
    Nearest,
    Maximum
};

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
    // Pack 24-bit code into RGB: R=bits 16-23, G=bits 8-15, B=bits 0-7
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

// RAII wrapper for libpng png_image
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

inline float decode_elevation(const std::uint8_t* rgb, bool is_terrarium) noexcept {
    return is_terrarium
        ? decode_terrarium(rgb[0], rgb[1], rgb[2])
        : decode_mapbox_terrain_rgb(rgb[0], rgb[1], rgb[2]);
}

// Nearest: copy left-top pixel RGB (no decode/encode needed)
void downsample_nearest(const std::uint8_t* input_ptr, int source_width,
                       int src_x, int src_y,
                       std::uint8_t& r, std::uint8_t& g, std::uint8_t& b) noexcept {
    const int idx = (src_y * source_width + src_x) * 3;
    r = input_ptr[idx];
    g = input_ptr[idx + 1];
    b = input_ptr[idx + 2];
}

// Average: mean of 4 pixels in 2×2 block
void downsample_average(const std::uint8_t* input_ptr, int source_width,
                       int src_x, int src_y, bool is_terrarium,
                       std::uint8_t& r, std::uint8_t& g, std::uint8_t& b) noexcept {
    const int idx00 = (src_y * source_width + src_x) * 3;
    const int idx10 = (src_y * source_width + (src_x + 1)) * 3;
    const int idx01 = ((src_y + 1) * source_width + src_x) * 3;
    const int idx11 = ((src_y + 1) * source_width + (src_x + 1)) * 3;
    
    const float e00 = decode_elevation(input_ptr + idx00, is_terrarium);
    const float e10 = decode_elevation(input_ptr + idx10, is_terrarium);
    const float e01 = decode_elevation(input_ptr + idx01, is_terrarium);
    const float e11 = decode_elevation(input_ptr + idx11, is_terrarium);
    
    const float avg_elevation = (e00 + e10 + e01 + e11) * 0.25f;
    
    if (is_terrarium) {
        encode_terrarium(avg_elevation, r, g, b);
    } else {
        encode_mapbox_terrain_rgb(avg_elevation, r, g, b);
    }
}

// Maximum: highest elevation from 4 pixels in 2×2 block
void downsample_maximum(const std::uint8_t* input_ptr, int source_width,
                       int src_x, int src_y, bool is_terrarium,
                       std::uint8_t& r, std::uint8_t& g, std::uint8_t& b) noexcept {
    const int idx00 = (src_y * source_width + src_x) * 3;
    const int idx10 = (src_y * source_width + (src_x + 1)) * 3;
    const int idx01 = ((src_y + 1) * source_width + src_x) * 3;
    const int idx11 = ((src_y + 1) * source_width + (src_x + 1)) * 3;
    
    const float e00 = decode_elevation(input_ptr + idx00, is_terrarium);
    const float e10 = decode_elevation(input_ptr + idx10, is_terrarium);
    const float e01 = decode_elevation(input_ptr + idx01, is_terrarium);
    const float e11 = decode_elevation(input_ptr + idx11, is_terrarium);
    
    const float max_elevation = std::max({e00, e10, e01, e11});
    
    if (is_terrarium) {
        encode_terrarium(max_elevation, r, g, b);
    } else {
        encode_mapbox_terrain_rgb(max_elevation, r, g, b);
    }
}

extern "C" VALUE downsample_png(VALUE /*self*/, VALUE png_data, VALUE target_size_val, VALUE encoding_type_val, VALUE method_val) {
    try {
        Check_Type(png_data, T_STRING);
        Check_Type(target_size_val, T_FIXNUM);
        Check_Type(encoding_type_val, T_STRING);
        Check_Type(method_val, T_STRING);
        
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
        
        const std::string_view method_str{RSTRING_PTR(method_val),
                                         static_cast<size_t>(RSTRING_LEN(method_val))};
        
        DownsampleMethod downsample_method;
        if (method_str == "average") {
            downsample_method = DownsampleMethod::Average;
        } else if (method_str == "nearest") {
            downsample_method = DownsampleMethod::Nearest;
        } else if (method_str == "maximum") {
            downsample_method = DownsampleMethod::Maximum;
        } else {
            rb_raise(rb_eArgError, "Unknown downsample method: %s (expected 'average', 'nearest', or 'maximum')", method_str.data());
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
                
                std::uint8_t r, g, b;
                
                switch (downsample_method) {
                    case DownsampleMethod::Nearest:
                        downsample_nearest(input_ptr, source_width, src_x, src_y, r, g, b);
                        break;
                    
                    case DownsampleMethod::Average:
                        downsample_average(input_ptr, source_width, src_x, src_y, is_terrarium, r, g, b);
                        break;
                    
                    case DownsampleMethod::Maximum:
                        downsample_maximum(input_ptr, source_width, src_x, src_y, is_terrarium, r, g, b);
                        break;
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
    rb_define_singleton_method(TerrainDownsampleFFI, "downsample_png", downsample_png, 4);
}

