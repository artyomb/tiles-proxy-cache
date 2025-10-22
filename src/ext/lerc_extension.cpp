#include "ruby.h"
#include <Lerc_c_api.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <array>
#include <memory>
#include <vector>
#include <algorithm>
#include <cstdint>
#include <stdexcept>

extern "C" VALUE lerc_to_mapbox_png(VALUE /*self*/, VALUE lerc_data) {
    try {
        Check_Type(lerc_data, T_STRING);
        const auto* blob = reinterpret_cast<const unsigned char*>(RSTRING_PTR(lerc_data));
        const auto   n   = static_cast<unsigned int>(RSTRING_LEN(lerc_data));
        if (n == 0) rb_raise(rb_eArgError, "Empty LERC data");

        constexpr int   DT_FLOAT      = 6;
        constexpr int   LERC_OK       = 0;
        constexpr float MAPBOX_OFFSET = 10000.0f;
        constexpr float MAPBOX_SCALE  = 0.1f;
        constexpr int32_t MAX_24BIT   = 16777215;

        std::array<unsigned int, 11> info{};
        std::array<double, 3> ranges{};
        if (const int rc = lerc_getBlobInfo(blob, n, info.data(), ranges.data(),
                                            static_cast<int>(info.size()), static_cast<int>(ranges.size()));
            rc != LERC_OK) {
            rb_raise(rb_eRuntimeError, "LERC getBlobInfo failed with code: %d", rc);
        }

        const int nCols = static_cast<int>(info[3]);
        const int nRows = static_cast<int>(info[4]);
        const int nBands= static_cast<int>(info[5]);
        const int nValidPixels = static_cast<int>(info[6]);
        const int type  = static_cast<int>(info[1]);

        if (nCols <= 0 || nRows <= 0 || nBands <= 0)
            rb_raise(rb_eRuntimeError, "Invalid LERC dimensions: %dx%dx%d", nCols, nRows, nBands);
        if (type != DT_FLOAT)
            rb_raise(rb_eRuntimeError, "Unsupported LERC data type: %d (expected %d)", type, DT_FLOAT);
        if (nValidPixels <= 0)
            return Qnil;

        const std::size_t total = static_cast<std::size_t>(nCols) * nRows * nBands;
        std::vector<float> elev;
        elev.reserve(total);
        elev.resize(total);

        if (const int rc = lerc_decode(blob, n, 0, nullptr, 1,
                                       nCols, nRows, nBands, type, elev.data());
            rc != LERC_OK) {
            rb_raise(rb_eRuntimeError, "LERC decode failed with code: %d", rc);
        }

        const int tw = (nCols == 257) ? 256 : nCols;
        const int th = (nRows == 257) ? 256 : nRows;
        const std::size_t rgb_size = static_cast<std::size_t>(tw) * th * 3u;

        std::vector<std::uint8_t> rgb;
        rgb.reserve(rgb_size);
        rgb.resize(rgb_size);

        const float* elev_ptr = elev.data();
        std::uint8_t* rgb_ptr = rgb.data();
        
        for (int y = 0; y < th; ++y) {
            const int row = y * nCols;
            for (int x = 0; x < tw; ++x) {
                const float e = elev_ptr[row + x];
                const int32_t code = std::clamp(
                    static_cast<int32_t>((e + MAPBOX_OFFSET) / MAPBOX_SCALE), 0, MAX_24BIT);
                
                *rgb_ptr++ = static_cast<std::uint8_t>((code >> 16) & 0xFF);
                *rgb_ptr++ = static_cast<std::uint8_t>((code >> 8)  & 0xFF);
                *rgb_ptr++ = static_cast<std::uint8_t>( code        & 0xFF);
            }
        }

        int png_len = 0;
        using png_ptr = std::unique_ptr<unsigned char, void(*)(void*)>;
        png_ptr png{ stbi_write_png_to_mem(rgb.data(), tw * 3, tw, th, 3, &png_len), std::free };
        if (!png) rb_raise(rb_eRuntimeError, "PNG creation failed");

        return rb_str_new(reinterpret_cast<const char*>(png.get()), static_cast<long>(png_len));
    } catch (const std::exception& e) {
        rb_raise(rb_eRuntimeError, "C++ exception: %s", e.what());
    } catch (...) {
        rb_raise(rb_eRuntimeError, "Unknown C++ exception occurred");
    }
    return Qnil;
}

extern "C" void Init_lerc_extension(void) {
    VALUE LercFFI = rb_define_module("LercFFI");
    rb_define_singleton_method(LercFFI, "lerc_to_mapbox_png", lerc_to_mapbox_png, 1);
}
