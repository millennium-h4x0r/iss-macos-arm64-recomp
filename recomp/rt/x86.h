/* Guest CPU state and x86-64 semantic helpers used by the recompiled game code.
 * Generated functions have the signature `void F(Ctx *c)`; guest registers live in locals
 * of each function and are written back to the Ctx around calls and returns. */
#ifndef RECOMP_X86_H
#define RECOMP_X86_H
#include <stdint.h>
#include <string.h>
#define SIMDE_ENABLE_NATIVE_ALIASES_NOT 1
#include "simde/x86/avx.h"
#include "simde/x86/f16c.h"
#include "simde/x86/sse4.2.h"

typedef struct { simde__m128i lo, hi; } Ymm;

typedef struct Ctx {
    uint64_t r[16];          /* rax rcx rdx rbx rsp rbp rsi rdi r8..r15 (x86 numbering) */
    Ymm x[16];
    uint64_t fs;             /* guest TCB (fs:/gs: segment base) */
    uint32_t mxcsr;
    uint32_t pad;
    uint64_t flags;          /* only used by pushf/popf/lahf round trips across calls */
    void *thread;            /* runtime thread record */
    uint64_t depth;
    double st[8];            /* x87 stack (as doubles) */
    uint32_t ftop;
    uint16_t fcw, fsw;
} Ctx;

typedef void (*GFn)(Ctx *);

#ifndef RECOMP_IMAGE_BASE
#define RECOMP_IMAGE_BASE 0xe000000000ULL   /* 896 GiB: above Apple's GPU carveout, below the 1 TiB the guest assumes */
#endif
#define IMG RECOMP_IMAGE_BASE
#define RECOMP_IMPORT_BASE 0x7f00000000ULL  /* fake guest addresses of host imports (never mapped) */

/* Runtime entry points (dispatch.c). */
GFn recomp_lookup(uint64_t guest);            /* never NULL: reports and stops on unknown targets */
void recomp_trap(uint64_t at, const char *what) __attribute__((noreturn));
void recomp_unimpl(uint64_t at, const char *text) __attribute__((noreturn));
uint64_t recomp_rdtsc(void);
void recomp_cpuid(uint64_t *rax, uint64_t *rbx, uint64_t *rcx, uint64_t *rdx);
void recomp_ldmxcsr(Ctx *c, uint32_t v);
void recomp_int(Ctx *c, uint64_t at, int n);

#define MUSTTAIL __attribute__((musttail))
#define UNUSED __attribute__((unused))
#define AI static inline __attribute__((always_inline, unused))

/* ---- guest memory: guest addresses are host addresses ---- */
AI uint8_t  ld8(uint64_t a)  { return *(const volatile uint8_t *)a; }
AI uint16_t ld16(uint64_t a) { uint16_t v; __builtin_memcpy(&v, (const void *)a, 2); return v; }
AI uint32_t ld32(uint64_t a) { uint32_t v; __builtin_memcpy(&v, (const void *)a, 4); return v; }
AI uint64_t ld64(uint64_t a) { uint64_t v; __builtin_memcpy(&v, (const void *)a, 8); return v; }
AI void st8(uint64_t a, uint8_t v)   { *(volatile uint8_t *)a = v; }
AI void st16(uint64_t a, uint16_t v) { __builtin_memcpy((void *)a, &v, 2); }
AI void st32(uint64_t a, uint32_t v) { __builtin_memcpy((void *)a, &v, 4); }
AI void st64(uint64_t a, uint64_t v) { __builtin_memcpy((void *)a, &v, 8); }
/* Ordered accesses for every guest GPR load/store that is not rsp-relative (the lifter picks):
 * acquire loads (LDAPR) and release stores (STLR) together give x86's TSO ordering between
 * threads, which plain ARM accesses do not. The rare access straddling a 16-byte block faults
 * and is emulated (rcpc_fixup.h). -DRECOMP_WEAK_MEMORY turns them back into plain accesses. */
#ifdef RECOMP_WEAK_MEMORY
#define lda8 ld8
#define lda16 ld16
#define lda32 ld32
#define lda64 ld64
#define stl8 st8
#define stl16 st16
#define stl32 st32
#define stl64 st64
#else
/* An access straddling a 16-byte block cannot be LDAPR/STLR (alignment fault): it becomes a plain
 * access with a barrier after (load) or before (store), the same ordering. rcpc_fixup.h stays as
 * the safety net for anything else. */
#define RECOMP_INBLOCK(a, n) __builtin_expect(((a) & 15) <= 16 - (n), 1)
#define RECOMP_LDA(bits, n) \
    AI uint##bits##_t lda##bits(uint64_t a) { \
        if (RECOMP_INBLOCK(a, n)) return __atomic_load_n((const uint##bits##_t *)a, __ATOMIC_ACQUIRE); \
        uint##bits##_t v; __builtin_memcpy(&v, (const void *)a, n); \
        __atomic_thread_fence(__ATOMIC_ACQUIRE); return v; }
#define RECOMP_STL(bits, n) \
    AI void stl##bits(uint64_t a, uint##bits##_t v) { \
        if (RECOMP_INBLOCK(a, n)) { __atomic_store_n((uint##bits##_t *)a, v, __ATOMIC_RELEASE); return; } \
        __atomic_thread_fence(__ATOMIC_RELEASE); __builtin_memcpy((void *)a, &v, n); }
AI uint8_t lda8(uint64_t a) { return __atomic_load_n((const uint8_t *)a, __ATOMIC_ACQUIRE); }
AI void stl8(uint64_t a, uint8_t v) { __atomic_store_n((uint8_t *)a, v, __ATOMIC_RELEASE); }
RECOMP_LDA(16, 2) RECOMP_LDA(32, 4) RECOMP_LDA(64, 8)
RECOMP_STL(16, 2) RECOMP_STL(32, 4) RECOMP_STL(64, 8)
#endif
AI simde__m128i ld128(uint64_t a) { return simde_mm_loadu_si128((const void *)a); }
AI void st128(uint64_t a, simde__m128i v) { simde_mm_storeu_si128((void *)a, v); }

AI uint8_t parity8(uint64_t r) { return !__builtin_parity((unsigned)(r & 0xff)); }

/* ---- vector casts ---- */
#define PS(x) simde_mm_castsi128_ps(x)
#define PD(x) simde_mm_castsi128_pd(x)
#define SI_PS(x) simde_mm_castps_si128(x)
#define SI_PD(x) simde_mm_castpd_si128(x)
#define VZERO simde_mm_setzero_si128()

AI simde__m128i v_from64(uint64_t v) { return simde_mm_cvtsi64_si128((int64_t)v); }
AI simde__m128i v_from32(uint32_t v) { return simde_mm_cvtsi32_si128((int32_t)v); }
AI uint64_t v_lo64(simde__m128i v) { return (uint64_t)simde_mm_cvtsi128_si64(v); }
AI uint32_t v_lo32(simde__m128i v) { return (uint32_t)simde_mm_cvtsi128_si32(v); }

/* x86 float->int conversions: out of range and NaN give the "integer indefinite" value. */
AI int32_t cvtt_f32_i32(float f) { return (f != f || f >= 2147483648.0f || f < -2147483648.0f) ? INT32_MIN : (int32_t)f; }
AI int64_t cvtt_f32_i64(float f) { return (f != f || f >= 9223372036854775808.0f || f < -9223372036854775808.0f) ? INT64_MIN : (int64_t)f; }
AI int32_t cvtt_f64_i32(double f) { return (f != f || f >= 2147483648.0 || f <= -2147483649.0) ? INT32_MIN : (int32_t)f; }
AI int64_t cvtt_f64_i64(double f) { return (f != f || f >= 9223372036854775808.0 || f < -9223372036854775808.0) ? INT64_MIN : (int64_t)f; }
AI float vf32(simde__m128i v) { return simde_mm_cvtss_f32(PS(v)); }
AI double vf64(simde__m128i v) { return simde_mm_cvtsd_f64(PD(v)); }

/* Current-rounding conversions (cvtss2si etc.): MXCSR rounding is mirrored in FPCR. */
AI int32_t cvt_f32_i32(float f) { if (f != f || f >= 2147483648.0f || f < -2147483648.0f) return INT32_MIN; return (int32_t)__builtin_rintf(f); }
AI int64_t cvt_f32_i64(float f) { if (f != f || f >= 9223372036854775808.0f || f < -9223372036854775808.0f) return INT64_MIN; return (int64_t)__builtin_rintf(f); }
AI int32_t cvt_f64_i32(double f) { if (f != f || f >= 2147483647.5 || f < -2147483648.5) return INT32_MIN; return (int32_t)__builtin_rint(f); }
AI int64_t cvt_f64_i64(double f) { if (f != f || f >= 9223372036854775808.0 || f < -9223372036854775808.0) return INT64_MIN; return (int64_t)__builtin_rint(f); }

/* ucomiss/comiss flags: unordered ZF=PF=CF=1; less CF; equal ZF. */
#define UCOMI(a, b) do { \
    if ((a) != (a) || (b) != (b)) { zf = 1; pf = 1; cf = 1; } \
    else { zf = (a) == (b); pf = 0; cf = (a) < (b); } \
    of = 0; sf = 0; af = 0; } while (0)

/* SSE4a EXTRQ with immediates: extract `len` bits from `idx` of the low quadword. */
AI simde__m128i extrq_imm(simde__m128i v, unsigned len, unsigned idx) {
    len &= 63; idx &= 63;
    uint64_t lo = v_lo64(v) >> idx;
    if (len) lo &= (len == 64) ? ~0ULL : ((1ULL << len) - 1);
    return simde_mm_set_epi64x(0, (int64_t)lo);
}

/* vptest / vtestps helpers */
AI int v_allzero(simde__m128i v) { return v_lo64(v) == 0 && (uint64_t)simde_mm_extract_epi64(v, 1) == 0; }

/* Half <-> single precision (F16C), exact. */
AI simde__m128i cvtph2ps_lo(simde__m128i v) { return SI_PS(simde_mm_cvtph_ps(v)); }

AI uint64_t bswap64(uint64_t v) { return __builtin_bswap64(v); }
AI uint32_t bswap32(uint32_t v) { return __builtin_bswap32(v); }
AI uint16_t bswap16(uint16_t v) { return __builtin_bswap16(v); }

/* rep movs / stos, DF=0 or 1, element size n. Forward copies are byte-exact x86 order. */
AI void rep_movs(uint64_t *rdi, uint64_t *rsi, uint64_t *rcx, unsigned n, int df) {
    uint64_t count = *rcx;
    if (!count) return;
    uint64_t d = *rdi, s = *rsi, bytes = count * n;
    if (!df) {
        if (d >= s + bytes || s >= d + bytes || d <= s) __builtin_memmove((void *)d, (const void *)s, bytes);
        else for (uint64_t i = 0; i < bytes; ++i) ((uint8_t *)d)[i] = ((const uint8_t *)s)[i];
        *rdi = d + bytes; *rsi = s + bytes;
    } else {
        for (uint64_t i = 0; i < count; ++i) __builtin_memmove((void *)(d - i * n), (const void *)(s - i * n), n);
        *rdi = d - bytes; *rsi = s - bytes;
    }
    *rcx = 0;
}
AI void rep_stos(uint64_t *rdi, uint64_t *rcx, uint64_t val, unsigned n, int df) {
    uint64_t count = *rcx;
    if (!count) return;
    uint64_t d = *rdi;
    if (!df) {
        if (n == 1) __builtin_memset((void *)d, (int)(val & 0xff), count);
        else for (uint64_t i = 0; i < count; ++i) __builtin_memcpy((void *)(d + i * n), &val, n);
        *rdi = d + count * n;
    } else {
        for (uint64_t i = 0; i < count; ++i) __builtin_memcpy((void *)(d - i * n), &val, n);
        *rdi = d - count * n;
    }
    *rcx = 0;
}

#include "x87.h"
#include "pcmpstr.h"
#endif
