#ifndef RFB_RENDERING_C_H
#define RFB_RENDERING_C_H

#include <stdint.h>

/// Decode three 8x8 Apple DCT coefficient planes to 64 native BGRA pixels.
void rfb_apple_dct_tile_bgra(
    uint32_t output[64],
    const int16_t coefficients[192],
    const uint16_t luma_quantization[64],
    const uint16_t chroma_quantization[64]);

#endif
