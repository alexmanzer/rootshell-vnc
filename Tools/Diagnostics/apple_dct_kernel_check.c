#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "RFBRenderingC.h"
static uint32_t rng = 42;
static uint32_t next(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static uint64_t hash = UINT64_C(14695981039346656037);
static void accumulate(int16_t *c, uint16_t *q, uint16_t *qc) {
    uint32_t pixels[64];
    rfb_apple_dct_tile_bgra(pixels, c, q, qc);
    for (int i = 0; i < 64; ++i) for (int shift = 0; shift < 32; shift += 8)
        hash = (hash ^ ((pixels[i] >> shift) & 255)) * UINT64_C(1099511628211);
}
// Golden hashes were recorded from the original kernel before optimization.
// ARM and scalar results differ for extreme coefficients because ARM narrows
// intermediate lanes to 16 bits. Preserve each implementation's output.
static void finish(const char *name, uint64_t arm, uint64_t scalar) {
#if defined(__aarch64__) && !defined(RFB_DCT_FORCE_SCALAR)
    uint64_t expected = arm;
#else
    uint64_t expected = scalar;
#endif
    if (hash != expected) {
        fprintf(stderr, "%s: expected %llu, got %llu\n", name,
                (unsigned long long)expected, (unsigned long long)hash);
        exit(1);
    }
    hash = UINT64_C(14695981039346656037);
}

int main(void) {
    int16_t c[192] = {0}; uint16_t q[64], qc[64];
    for (int i = 0; i < 64; ++i) q[i] = qc[i] = 1;
    for (int dc = -32768; dc <= 32767; ++dc) {
        c[0] = (int16_t)dc; c[64] = (int16_t)(32767 - dc); c[128] = (int16_t)(dc * 3);
        accumulate(c, q, qc);
    }
    finish("DC", UINT64_C(15587640981737066277), UINT64_C(12076109194721359525));
    for (int test = 0; test < 100000; ++test) {
        memset(c, 0, sizeof(c));
        for (int p = 0; p < 3; ++p) {
            int remaining = 2048;
            while (remaining) {
                int n = 1 + next() % remaining, k = next() % 64;
                c[p * 64 + k] += (next() & 1) ? n : -n;
                remaining -= n;
            }
        }
        accumulate(c, q, qc);
    }
    finish("sparse", UINT64_C(9702086786252769603), UINT64_C(9702086786252769603));
    for (int test = 0; test < 100000; ++test) {
        for (int i = 0; i < 64; ++i) { q[i] = next() % 256; qc[i] = next() % 256; }
        for (int i = 0; i < 192; ++i) c[i] = (int8_t)next();
        c[0] = next(); c[64] = next(); c[128] = next();
        accumulate(c, q, qc);
    }
    finish("dense", UINT64_C(14676543489694806524), UINT64_C(5821545283234652625));
    for (int i = 0; i < 64; ++i) q[i] = qc[i] = 1;
    for (int cb = 0; cb < 256; ++cb) for (int cr = 0; cr < 256; ++cr) {
        memset(c, 0, sizeof(c));
        for (int i = 0; i < 64; ++i) c[i] = (int8_t)next();
        c[0] = (int)(next() % 2048) - 1024;
        c[64] = (cb - 128) * 8; c[128] = (cr - 128) * 8;
        accumulate(c, q, qc);
    }
    finish("constant chroma", UINT64_C(8307219995545036542), UINT64_C(8307219995545036542));
    for (int test = 0; test < 5000; ++test) {
        for (int i = 0; i < 64; ++i) { q[i] = next(); qc[i] = next(); }
        for (int i = 0; i < 192; ++i) c[i] = next();
        accumulate(c, q, qc);
    }
    finish("wide quantization", UINT64_C(11788263237359094935), UINT64_C(11458679545486711033));

    puts("DC, sparse, dense, constant chroma, and wide quantization: exact match");

}
