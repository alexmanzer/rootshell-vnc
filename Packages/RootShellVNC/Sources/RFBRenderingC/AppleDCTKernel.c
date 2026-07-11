#include "RFBRenderingC.h"
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

// Integer DCT_ISLOW and YCbCr conversion derived from stb_image, which is
// public domain or MIT licensed. Keeping the integer biases and shifts is
// necessary for output identical to its ARM SIMD implementation.

#define FSH(x) ((x) * 4096)
#define IDCT_1D(s0,s1,s2,s3,s4,s5,s6,s7) \
    int t0,t1,t2,t3,p1,p2,p3,p4,p5,x0,x1,x2,x3; \
    p2=(s2); p3=(s6); p1=(p2+p3)*2217; \
    t2=p1+p3*-7567; t3=p1+p2*3135; \
    p2=(s0); p3=(s4); t0=FSH(p2+p3); t1=FSH(p2-p3); \
    x0=t0+t3; x3=t0-t3; x1=t1+t2; x2=t1-t2; \
    t0=(s7); t1=(s5); t2=(s3); t3=(s1); \
    p3=t0+t2; p4=t1+t3; p1=t0+t3; p2=t1+t2; \
    p5=(p3+p4)*4816; t0*=1223; t1*=8410; t2*=12586; t3*=6149; \
    p1=p5+p1*-3685; p2=p5+p2*-10497; p3*=-8034; p4*=-1597; \
    t3+=p1+p4; t2+=p2+p3; t1+=p2+p4; t0+=p1+p3

static uint8_t clamp_u8(int value) {
    if ((unsigned)value > 255) return value < 0 ? 0 : 255;
    return (uint8_t)value;
}

static void idct_block(uint8_t output[64], const int16_t input[64]) {
    int values[64];
    int *v = values;
    const int16_t *d = input;
    for (int column = 0; column < 8; ++column, ++d, ++v) {
        if (d[8]==0 && d[16]==0 && d[24]==0 && d[32]==0 &&
            d[40]==0 && d[48]==0 && d[56]==0) {
            int dc = d[0] * 4;
            v[0]=v[8]=v[16]=v[24]=v[32]=v[40]=v[48]=v[56]=dc;
        } else {
            IDCT_1D(d[0],d[8],d[16],d[24],d[32],d[40],d[48],d[56]);
            x0+=512; x1+=512; x2+=512; x3+=512;
            v[0]=(x0+t3)>>10; v[56]=(x0-t3)>>10;
            v[8]=(x1+t2)>>10; v[48]=(x1-t2)>>10;
            v[16]=(x2+t1)>>10; v[40]=(x2-t1)>>10;
            v[24]=(x3+t0)>>10; v[32]=(x3-t0)>>10;
        }
    }
    v = values;
    for (int row = 0; row < 8; ++row, v += 8) {
        IDCT_1D(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7]);
        x0+=65536+(128<<17); x1+=65536+(128<<17);
        x2+=65536+(128<<17); x3+=65536+(128<<17);
        output[row*8+0]=clamp_u8((x0+t3)>>17);
        output[row*8+7]=clamp_u8((x0-t3)>>17);
        output[row*8+1]=clamp_u8((x1+t2)>>17);
        output[row*8+6]=clamp_u8((x1-t2)>>17);
        output[row*8+2]=clamp_u8((x2+t1)>>17);
        output[row*8+5]=clamp_u8((x2-t1)>>17);
        output[row*8+3]=clamp_u8((x3+t0)>>17);
        output[row*8+4]=clamp_u8((x3-t0)>>17);
    }
}

#if defined(__aarch64__)
// stb_image's ARM integer IDCT. It is designed to be bit-identical to the
// scalar DCT_ISLOW routine above while processing all eight lanes together.
static void idct_block_neon(uint8_t *out, const int16_t data[64]) {
    int16x8_t row0,row1,row2,row3,row4,row5,row6,row7;
    int16x4_t rot0_0=vdup_n_s16(2217),rot0_1=vdup_n_s16(-7567),rot0_2=vdup_n_s16(3135);
    int16x4_t rot1_0=vdup_n_s16(4816),rot1_1=vdup_n_s16(-3685),rot1_2=vdup_n_s16(-10497);
    int16x4_t rot2_0=vdup_n_s16(-8034),rot2_1=vdup_n_s16(-1597);
    int16x4_t rot3_0=vdup_n_s16(1223),rot3_1=vdup_n_s16(8410);
    int16x4_t rot3_2=vdup_n_s16(12586),rot3_3=vdup_n_s16(6149);
#define LM(out,in,co) int32x4_t out##_l=vmull_s16(vget_low_s16(in),co); int32x4_t out##_h=vmull_s16(vget_high_s16(in),co)
#define LMA(out,ac,in,co) int32x4_t out##_l=vmlal_s16(ac##_l,vget_low_s16(in),co); int32x4_t out##_h=vmlal_s16(ac##_h,vget_high_s16(in),co)
#define WID(out,in) int32x4_t out##_l=vshll_n_s16(vget_low_s16(in),12); int32x4_t out##_h=vshll_n_s16(vget_high_s16(in),12)
#define WADD(out,a,b) int32x4_t out##_l=vaddq_s32(a##_l,b##_l); int32x4_t out##_h=vaddq_s32(a##_h,b##_h)
#define WSUB(out,a,b) int32x4_t out##_l=vsubq_s32(a##_l,b##_l); int32x4_t out##_h=vsubq_s32(a##_h,b##_h)
#define BFLY(out0,out1,a,b,shiftop,s) { WADD(sum,a,b); WSUB(dif,a,b); out0=vcombine_s16(shiftop(sum_l,s),shiftop(sum_h,s)); out1=vcombine_s16(shiftop(dif_l,s),shiftop(dif_h,s)); }
#define PASS(shiftop,shift) { \
    int16x8_t sum26=vaddq_s16(row2,row6); LM(p1e,sum26,rot0_0); LMA(t2e,p1e,row6,rot0_1); LMA(t3e,p1e,row2,rot0_2); \
    int16x8_t sum04=vaddq_s16(row0,row4),dif04=vsubq_s16(row0,row4); WID(t0e,sum04); WID(t1e,dif04); \
    WADD(x0,t0e,t3e); WSUB(x3,t0e,t3e); WADD(x1,t1e,t2e); WSUB(x2,t1e,t2e); \
    int16x8_t sum15=vaddq_s16(row1,row5),sum17=vaddq_s16(row1,row7),sum35=vaddq_s16(row3,row5),sum37=vaddq_s16(row3,row7); \
    int16x8_t sumodd=vaddq_s16(sum17,sum35); LM(p5o,sumodd,rot1_0); LMA(p1o,p5o,sum17,rot1_1); LMA(p2o,p5o,sum35,rot1_2); \
    LM(p3o,sum37,rot2_0); LM(p4o,sum15,rot2_1); WADD(sump13o,p1o,p3o); WADD(sump24o,p2o,p4o); WADD(sump23o,p2o,p3o); WADD(sump14o,p1o,p4o); \
    LMA(x4,sump13o,row7,rot3_0); LMA(x5,sump24o,row5,rot3_1); LMA(x6,sump23o,row3,rot3_2); LMA(x7,sump14o,row1,rot3_3); \
    BFLY(row0,row7,x0,x7,shiftop,shift); BFLY(row1,row6,x1,x6,shiftop,shift); BFLY(row2,row5,x2,x5,shiftop,shift); BFLY(row3,row4,x3,x4,shiftop,shift); }
    row0=vld1q_s16(data); row1=vld1q_s16(data+8); row2=vld1q_s16(data+16); row3=vld1q_s16(data+24);
    row4=vld1q_s16(data+32); row5=vld1q_s16(data+40); row6=vld1q_s16(data+48); row7=vld1q_s16(data+56);
    row0=vaddq_s16(row0,vsetq_lane_s16(1024,vdupq_n_s16(0),0));
    PASS(vrshrn_n_s32,10);
#define T16(x,y) {int16x8x2_t t=vtrnq_s16(x,y);x=t.val[0];y=t.val[1];}
#define T32(x,y) {int32x4x2_t t=vtrnq_s32(vreinterpretq_s32_s16(x),vreinterpretq_s32_s16(y));x=vreinterpretq_s16_s32(t.val[0]);y=vreinterpretq_s16_s32(t.val[1]);}
#define T64(x,y) {int16x8_t a=x,b=y;x=vcombine_s16(vget_low_s16(a),vget_low_s16(b));y=vcombine_s16(vget_high_s16(a),vget_high_s16(b));}
    T16(row0,row1);T16(row2,row3);T16(row4,row5);T16(row6,row7);
    T32(row0,row2);T32(row1,row3);T32(row4,row6);T32(row5,row7);
    T64(row0,row4);T64(row1,row5);T64(row2,row6);T64(row3,row7);
    PASS(vshrn_n_s32,16);
    uint8x8_t p0=vqrshrun_n_s16(row0,1),p1=vqrshrun_n_s16(row1,1),p2=vqrshrun_n_s16(row2,1),p3=vqrshrun_n_s16(row3,1);
    uint8x8_t p4=vqrshrun_n_s16(row4,1),p5=vqrshrun_n_s16(row5,1),p6=vqrshrun_n_s16(row6,1),p7=vqrshrun_n_s16(row7,1);
#define T8(x,y) {uint8x8x2_t t=vtrn_u8(x,y);x=t.val[0];y=t.val[1];}
#define T816(x,y) {uint16x4x2_t t=vtrn_u16(vreinterpret_u16_u8(x),vreinterpret_u16_u8(y));x=vreinterpret_u8_u16(t.val[0]);y=vreinterpret_u8_u16(t.val[1]);}
#define T832(x,y) {uint32x2x2_t t=vtrn_u32(vreinterpret_u32_u8(x),vreinterpret_u32_u8(y));x=vreinterpret_u8_u32(t.val[0]);y=vreinterpret_u8_u32(t.val[1]);}
    T8(p0,p1);T8(p2,p3);T8(p4,p5);T8(p6,p7);T816(p0,p2);T816(p1,p3);T816(p4,p6);T816(p5,p7);T832(p0,p4);T832(p1,p5);T832(p2,p6);T832(p3,p7);
    vst1_u8(out,p0);vst1_u8(out+8,p1);vst1_u8(out+16,p2);vst1_u8(out+24,p3);vst1_u8(out+32,p4);vst1_u8(out+40,p5);vst1_u8(out+48,p6);vst1_u8(out+56,p7);
#undef LM
#undef LMA
#undef WID
#undef WADD
#undef WSUB
#undef BFLY
#undef PASS
#undef T16
#undef T32
#undef T64
#undef T8
#undef T816
#undef T832
}
#endif

static uint32_t ycbcr_to_bgra(uint8_t y, uint8_t cb_byte, uint8_t cr_byte) {
    int y_fixed=((int)y<<20)+(1<<19);
    int cb=(int)cb_byte-128, cr=(int)cr_byte-128;
    int r=(y_fixed+cr*(5743<<8))>>20;
    int green_cb=(int32_t)((uint32_t)(cb*-(1410<<8))&0xffff0000u);
    int g=(y_fixed+cr*-(2925<<8)+green_cb)>>20;
    int b=(y_fixed+cb*(7258<<8))>>20;
    return 0xff000000u | ((uint32_t)clamp_u8(r)<<16) |
        ((uint32_t)clamp_u8(g)<<8) | clamp_u8(b);
}

void rfb_apple_dct_tile_bgra(
    uint32_t output[64], const int16_t coefficients[192],
    const uint16_t luma_quantization[64],
    const uint16_t chroma_quantization[64]) {
    int16_t dequantized[64];
    uint8_t planes[192];
    for (int plane=0; plane<3; ++plane) {
        const uint16_t *quant=plane==0 ? luma_quantization : chroma_quantization;
        for (int i=0; i<64; ++i)
            dequantized[i]=(int16_t)(coefficients[plane*64+i]*quant[i]);
#if defined(__aarch64__)
        idct_block_neon(planes+plane*64,dequantized);
#else
        idct_block(planes+plane*64,dequantized);
#endif
    }
    for (int i=0; i<64; ++i)
        output[i]=ycbcr_to_bgra(planes[i],planes[64+i],planes[128+i]);
}
