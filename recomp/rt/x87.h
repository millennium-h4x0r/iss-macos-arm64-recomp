/* x87 FPU on doubles (the PS4 libc uses it for long double; 80-bit precision is reduced to 64-bit
 * doubles, which is what long double is on the host anyway). Status/control words are kept. */
#ifndef RECOMP_X87_H
#define RECOMP_X87_H
#include <math.h>
#include "x86.h"

#define ST(i) (c->st[(c->ftop + (i)) & 7])
AI void fpush(Ctx *c, double v) { c->ftop = (c->ftop - 1) & 7; c->st[c->ftop] = v; }
AI double fpop(Ctx *c) { double v = c->st[c->ftop]; c->ftop = (c->ftop + 1) & 7; return v; }
AI uint16_t fsw_get(Ctx *c) { return (uint16_t)((c->fsw & ~0x3800) | ((c->ftop & 7) << 11)); }

AI double f80_load(uint64_t a) {
    uint64_t mant = ld64(a);
    uint16_t se = ld16(a + 8);
    int sign = se >> 15, exp = se & 0x7fff;
    if (exp == 0 && mant == 0) return sign ? -0.0 : 0.0;
    if (exp == 0x7fff) {
        if ((mant << 1) == 0) return sign ? -INFINITY : INFINITY;
        return NAN;
    }
    double m = (double)mant;                 /* includes the explicit integer bit */
    double v = ldexp(m, exp - 16383 - 63);
    return sign ? -v : v;
}
AI void f80_store(uint64_t a, double v) {
    uint64_t mant; uint16_t se;
    int sign = signbit(v) ? 1 : 0;
    if (v == 0) { mant = 0; se = (uint16_t)(sign << 15); }
    else if (isinf(v)) { mant = 0x8000000000000000ULL; se = (uint16_t)((sign << 15) | 0x7fff); }
    else if (isnan(v)) { mant = 0xc000000000000000ULL; se = (uint16_t)((sign << 15) | 0x7fff); }
    else {
        int e; double f = frexp(fabs(v), &e);   /* v = f * 2^e, f in [0.5, 1) */
        mant = (uint64_t)ldexp(f, 64);
        int exp = e - 1 + 16383;
        se = (uint16_t)((sign << 15) | exp);
    }
    st64(a, mant); st16(a + 8, se);
}
AI double fround(Ctx *c, double v) {
    switch ((c->fcw >> 10) & 3) {
    case 0: return nearbyint(v);
    case 1: return floor(v);
    case 2: return ceil(v);
    default: return trunc(v);
    }
}
AI int64_t fist(double v, int bits) {
    double lim = ldexp(1.0, bits - 1);
    if (v != v || v >= lim || v < -lim) return (int64_t)(UINT64_MAX << (bits - 1));
    return (int64_t)v;
}
/* FCOM-style status codes C3 C2 C0 */
AI void fcom_sw(Ctx *c, double a, double b) {
    c->fsw &= ~0x4500;
    if (a != a || b != b) c->fsw |= 0x4500;
    else if (a < b) c->fsw |= 0x0100;
    else if (a == b) c->fsw |= 0x4000;
}
AI void fxam(Ctx *c) {
    double v = ST(0);
    c->fsw &= ~0x4700;
    if (signbit(v)) c->fsw |= 0x0200;
    if (isnan(v)) c->fsw |= 0x0100;
    else if (isinf(v)) c->fsw |= 0x0500;
    else if (v == 0) c->fsw |= 0x4000;
    else if (fpclassify(v) == FP_SUBNORMAL) c->fsw |= 0x4400;
    else c->fsw |= 0x0400;
}
AI void fprem_op(Ctx *c, int ieee) {
    double a = ST(0), b = ST(1);
    ST(0) = ieee ? remainder(a, b) : fmod(a, b);
    c->fsw &= ~0x4700; /* C2 = 0: complete */
}
AI void fxtract_op(Ctx *c) {
    double v = ST(0);
    if (v == 0) { ST(0) = -INFINITY; fpush(c, v); return; }
    int e; double f = frexp(v, &e);
    ST(0) = (double)(e - 1);
    fpush(c, f * 2);
}
AI void fnstenv_op(Ctx *c, uint64_t a) {
    st32(a, c->fcw | 0xffff0000u); st32(a + 4, fsw_get(c) | 0xffff0000u); st32(a + 8, 0xffffffffu);
    for (int i = 12; i < 28; i += 4) st32(a + i, 0);
}
AI void fldenv_op(Ctx *c, uint64_t a) {
    c->fcw = ld16(a); uint16_t sw = ld16(a + 4); c->fsw = sw; c->ftop = (sw >> 11) & 7;
}
#endif
