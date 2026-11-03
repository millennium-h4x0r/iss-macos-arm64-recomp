/* SSE4.2 PCMPxSTRx (SIMDe only has stubs). Returns IntRes2 as a bit mask; sets lengths/flags. */
#ifndef RECOMP_PCMPSTR_H
#define RECOMP_PCMPSTR_H
#include "x86.h"

typedef struct { uint32_t res; uint8_t cf, zf, sf, of; int n; } PcmpResult;

static inline PcmpResult pcmpstr(simde__m128i va, simde__m128i vb, int la, int lb, int imm, int implicit) {
    uint8_t A[16], B[16];
    memcpy(A, &va, 16); memcpy(B, &vb, 16);
    const int words = imm & 1, sgn = (imm >> 1) & 1, n = words ? 8 : 16;
    int64_t a[16], b[16];
    for (int i = 0; i < n; ++i) {
        if (words) {
            uint16_t x, y; memcpy(&x, A + 2 * i, 2); memcpy(&y, B + 2 * i, 2);
            a[i] = sgn ? (int16_t)x : x; b[i] = sgn ? (int16_t)y : y;
        } else {
            a[i] = sgn ? (int8_t)A[i] : A[i]; b[i] = sgn ? (int8_t)B[i] : B[i];
        }
    }
    if (implicit) {
        la = n; lb = n;
        for (int i = 0; i < n; ++i) if (a[i] == 0) { la = i; break; }
        for (int i = 0; i < n; ++i) if (b[i] == 0) { lb = i; break; }
    } else {
        la = la < 0 ? -la : la; lb = lb < 0 ? -lb : lb;
        if (la > n) la = n;
        if (lb > n) lb = n;
    }
    uint32_t r1 = 0;
    const int agg = (imm >> 2) & 3;
    for (int i = 0; i < n; ++i) {
        int bit = 0;
        switch (agg) {
        case 0: /* equal any */
            if (i < lb) for (int j = 0; j < la; ++j) if (a[j] == b[i]) { bit = 1; break; }
            break;
        case 1: /* ranges */
            if (i < lb) for (int j = 0; j + 1 < la + 1 && j < la; j += 2) {
                if (j + 1 >= la) break;
                if (b[i] >= a[j] && b[i] <= a[j + 1]) { bit = 1; break; }
            }
            break;
        case 2: /* equal each */
            if (i >= la && i >= lb) bit = 1;
            else if (i >= la || i >= lb) bit = 0;
            else bit = a[i] == b[i];
            break;
        default: /* equal ordered */
            bit = 1;
            for (int k = 0; k < n - i; ++k) {
                if (k >= la) break;
                if (i + k >= lb) { bit = 0; break; }
                if (a[k] != b[i + k]) { bit = 0; break; }
            }
            break;
        }
        r1 |= (uint32_t)bit << i;
    }
    const uint32_t full = (1u << n) - 1;
    uint32_t r2 = r1;
    switch ((imm >> 4) & 3) {
    case 1: r2 = ~r1 & full; break;
    case 3: r2 = (r1 ^ ((1u << lb) - 1)) & full; break;
    default: break;
    }
    PcmpResult out = { r2, r2 != 0, lb < n, la < n, r2 & 1, n };
    return out;
}
static inline uint32_t pcmp_index(PcmpResult r, int imm) {
    if (!r.res) return (uint32_t)r.n;
    return (imm & 0x40) ? 31u - (uint32_t)__builtin_clz(r.res) : (uint32_t)__builtin_ctz(r.res);
}
static inline simde__m128i pcmp_mask(PcmpResult r, int imm) {
    if (!(imm & 0x40)) return simde_mm_cvtsi32_si128((int)r.res);
    uint8_t out[16];
    if (imm & 1) {
        for (int i = 0; i < 8; ++i) { uint16_t v = (r.res >> i) & 1 ? 0xffff : 0; memcpy(out + 2 * i, &v, 2); }
    } else {
        for (int i = 0; i < 16; ++i) out[i] = (r.res >> i) & 1 ? 0xff : 0;
    }
    simde__m128i v; memcpy(&v, out, 16); return v;
}
#endif
