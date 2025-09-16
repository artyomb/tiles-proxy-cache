#include "ruby.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define DT_FLOAT 6
#define LERC_OK 0
#define MAPBOX_OFFSET 10000.0f
#define MAPBOX_SCALE 0.1f
#define MAX_24BIT 16777215

extern int lerc_getBlobInfo(const unsigned char* pLercBlob, 
                           unsigned int blobSize, 
                           unsigned int* infoArray, 
                           double* dataRangeArray, 
                           int infoArraySize, 
                           int dataRangeArraySize);

extern int lerc_decode(const unsigned char* pLercBlob, 
                      unsigned int blobSize, 
                      int band, 
                      const unsigned char* pValidBytes, 
                      int nDepth,
                      int nCols, 
                      int nRows, 
                      int nBands, 
                      int dataType, 
                      void* pData);

static void* safe_malloc(size_t size) {
    if (size == 0) return NULL;
    void* ptr = malloc(size);
    if (!ptr) {
        rb_raise(rb_eNoMemError, "Memory allocation failed: %zu bytes", size);
    }
    return ptr;
}

static void safe_free(void* ptr) {
    if (ptr) free(ptr);
}

static void cleanup_resources(void* elevation_data, void* rgb_data, void* png_data) {
    safe_free(elevation_data);
    safe_free(rgb_data);
    safe_free(png_data);
}

static int elevation_to_mapbox_c(float* elevation_data, uint8_t* rgb_data, int target_count, 
                                int src_width, int src_height, int target_width, int target_height) {
    if (!elevation_data || !rgb_data || target_count <= 0) return -1;
    
    int rgb_idx = 0;
    for (int y = 0; y < target_height; y++) {
        for (int x = 0; x < target_width; x++) {
            int src_idx = y * src_width + x;
            float elevation = elevation_data[src_idx];
            
            int32_t code = (int32_t)((elevation + MAPBOX_OFFSET) / MAPBOX_SCALE);
            if (code < 0) code = 0;
            if (code > MAX_24BIT) code = MAX_24BIT;
            
            rgb_data[rgb_idx * 3] = (code >> 16) & 0xFF;
            rgb_data[rgb_idx * 3 + 1] = (code >> 8) & 0xFF;
            rgb_data[rgb_idx * 3 + 2] = code & 0xFF;
            rgb_idx++;
        }
    }
    return 0;
}

static char* create_png_c(uint8_t* rgb_data, int width, int height, size_t* png_size) {
    if (!rgb_data || width <= 0 || height <= 0 || !png_size) {
        return NULL;
    }
    
    int len;
    unsigned char *png_data = stbi_write_png_to_mem(rgb_data, width * 3, width, height, 3, &len);
    if (!png_data) {
        return NULL;
    }
    
    *png_size = len;
    return (char*)png_data;
}

static VALUE lerc_to_mapbox_png_c(VALUE self, VALUE lerc_data) {
    Check_Type(lerc_data, T_STRING);
    
    const char* lerc_ptr = RSTRING_PTR(lerc_data);
    size_t lerc_size = RSTRING_LEN(lerc_data);
    if (lerc_size == 0) {
        rb_raise(rb_eArgError, "Empty LERC data");
    }
    
    float* elevation_data = NULL;
    uint8_t* rgb_data = NULL;
    char* png_data = NULL;
    
    unsigned int info[11] = {0};
    double ranges[3] = {0.0};
    
    int ret = lerc_getBlobInfo((const unsigned char*)lerc_ptr, (unsigned int)lerc_size, info, ranges, 11, 3);
    if (ret != LERC_OK) {
        rb_raise(rb_eRuntimeError, "LERC getBlobInfo failed with code: %d", ret);
    }
    
    int nCols = (int)info[3];
    int nRows = (int)info[4];
    int nBands = (int)info[5];
    int dataType = (int)info[1];
    
    if (nCols <= 0 || nRows <= 0 || nBands <= 0) {
        rb_raise(rb_eRuntimeError, "Invalid LERC dimensions: %dx%dx%d", nCols, nRows, nBands);
    }
    if (dataType != DT_FLOAT) {
        rb_raise(rb_eRuntimeError, "Unsupported LERC data type: %d (expected %d)", dataType, DT_FLOAT);
    }
    
    size_t elevation_size = nCols * nRows * nBands * sizeof(float);
    elevation_data = (float*)safe_malloc(elevation_size);
    
    ret = lerc_decode((const unsigned char*)lerc_ptr, (unsigned int)lerc_size, 0, NULL, 1, 
                     nCols, nRows, nBands, dataType, elevation_data);
    if (ret != LERC_OK) {
        cleanup_resources(elevation_data, rgb_data, png_data);
        rb_raise(rb_eRuntimeError, "LERC decode failed with code: %d", ret);
    }
    
    int target_width = (nCols == 257) ? 256 : nCols;
    int target_height = (nRows == 257) ? 256 : nRows;
    int pixel_count = target_width * target_height;
    size_t rgb_size = pixel_count * 3;
    rgb_data = (uint8_t*)safe_malloc(rgb_size);
    
    if (elevation_to_mapbox_c(elevation_data, rgb_data, pixel_count, nCols, nRows, target_width, target_height) != 0) {
        cleanup_resources(elevation_data, rgb_data, png_data);
        rb_raise(rb_eRuntimeError, "Elevation to Mapbox conversion failed");
    }
    
    safe_free(elevation_data);
    elevation_data = NULL;
    
    size_t png_size;
    png_data = create_png_c(rgb_data, target_width, target_height, &png_size);
    if (!png_data) {
        cleanup_resources(elevation_data, rgb_data, png_data);
        rb_raise(rb_eRuntimeError, "PNG creation failed");
    }
    
    safe_free(rgb_data);
    rgb_data = NULL;
    
    VALUE result = rb_str_new(png_data, png_size);
    safe_free(png_data);
    
    return result;
}

void Init_lerc_extension(void) {
    VALUE LercFFI = rb_define_module("LercFFI");
    rb_define_singleton_method(LercFFI, "lerc_to_mapbox_png_c", lerc_to_mapbox_png_c, 1);
}
