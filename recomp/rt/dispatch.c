/* Guest address -> recompiled function lookup, host imports, guest calls from host code,
 * per-thread guest contexts, traps. */
#define _DARWIN_C_SOURCE
#include "x86.h"
#include "recomp_table.h"
#include "recomp_host.h"
#include "recomp_rt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <execinfo.h>

/* ---------------------------------------------------------------- function table */
static uint64_t *hash_keys;
static GFn *hash_fns;
static uint64_t hash_mask;

static inline uint64_t mix(uint64_t k) { k ^= k >> 33; k *= 0xff51afd7ed558ccdULL; k ^= k >> 33; return k; }

void recomp_table_init(void) {
    uint64_t n = 1;
    while (n < recomp_table_count * 3) n <<= 1;
    hash_keys = calloc(n, sizeof(*hash_keys));
    hash_fns = calloc(n, sizeof(*hash_fns));
    hash_mask = n - 1;
    for (unsigned long i = 0; i < recomp_table_count; ++i) {
        uint64_t k = recomp_table[i].offset + 1, h = mix(k) & hash_mask;
        while (hash_keys[h]) h = (h + 1) & hash_mask;
        hash_keys[h] = k; hash_fns[h] = recomp_table[i].fn;
    }
}

static GFn find_offset(uint64_t off) {
    uint64_t k = off + 1, h = mix(k) & hash_mask;
    for (;;) {
        uint64_t x = hash_keys[h];
        if (x == k) return hash_fns[h];
        if (!x) return NULL;
        h = (h + 1) & hash_mask;
    }
}

/* ---------------------------------------------------------------- imports */
RecompImport *recomp_imports;
uint64_t recomp_import_count;

static void import_call(Ctx *c, uint64_t i) {
    RecompImport *imp = &recomp_imports[i];
    if (!imp->fn) {
        fprintf(stderr, "STOP: guest called unresolved import #%llu %s (%s)\n", (unsigned long long)i,
                imp->name, imp->label ? imp->label : "?");
        recomp_backtrace();
        exit(22);
    }
    uint64_t rsp = c->r[4];
    uint64_t ints[8] = { c->r[7], c->r[6], c->r[2], c->r[1], c->r[8], c->r[9], ld64(rsp + 8), ld64(rsp + 16) };
    simde__m128i vecs[8];
    for (int k = 0; k < 8; ++k) vecs[k] = c->x[k].lo;
    uint64_t stack[16];
    for (int k = 0; k < 16; ++k) stack[k] = ld64(rsp + 24 + 8 * k);
    uint64_t out[6];
    if (imp->trace) fprintf(stderr, "import %s(%#llx, %#llx, %#llx, %#llx)\n", imp->label ? imp->label : imp->name,
                            (unsigned long long)ints[0], (unsigned long long)ints[1], (unsigned long long)ints[2], (unsigned long long)ints[3]);
    recomp_hostcall(imp->fn, ints, vecs, stack, imp->variadic ? 16 : 16, out);
    c->r[0] = out[0];
    c->r[2] = out[1];
    memcpy(&c->x[0].lo, &out[2], 16);
    c->r[4] = rsp + 8; /* the guest's call pushed a return address */
}

#include "thunks.inc"

/* ---------------------------------------------------------------- lookup */
static void unknown_target(Ctx *c) { (void)c; }

GFn recomp_lookup(uint64_t guest) {
    if (guest - RECOMP_IMPORT_BASE < recomp_import_count * 16) {
        uint64_t i = (guest - RECOMP_IMPORT_BASE) / 16;
        if (i < 1024) return import_thunks[i];
    }
    if (guest - RECOMP_IMPORT_BASE < 1024 * 16 && recomp_imports[(guest - RECOMP_IMPORT_BASE) / 16].fn)
        return import_thunks[(guest - RECOMP_IMPORT_BASE) / 16];
    if (guest - IMG >= recomp_image_size) {
        /* A host function pointer the runtime gave the guest (exit handler, dlsym result):
         * give it an import slot so the call goes through the native-ABI trampoline. */
        Dl_info info;
        static void *self_base;
        if (!self_base && dladdr((void *)recomp_lookup, &info)) self_base = info.dli_fbase;
        if (dladdr((void *)guest, &info) && info.dli_fbase == self_base) {
            static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
            static uint64_t next = 1023;
            pthread_mutex_lock(&lock);
            for (uint64_t i = next + 1; i < 1024; ++i)
                if (recomp_imports[i].fn == (void *)guest) { pthread_mutex_unlock(&lock); return import_thunks[i]; }
            uint64_t slot = next--;
            if (slot <= recomp_import_count) { pthread_mutex_unlock(&lock); fprintf(stderr, "STOP: out of host-call slots\n"); exit(23); }
            recomp_imports[slot].fn = (void *)guest;
            recomp_imports[slot].name = info.dli_sname ? info.dli_sname : "host function";
            recomp_imports[slot].label = recomp_imports[slot].name;
            pthread_mutex_unlock(&lock);
            fprintf(stderr, "Runtime: guest calls host function %s through slot %llu\n", recomp_imports[slot].name, (unsigned long long)slot);
            return import_thunks[slot];
        }
    }
    if (guest - IMG < recomp_image_size) {
        GFn f = find_offset(guest - IMG);
        if (f) return f;
        fprintf(stderr, "STOP: no recompiled function at guest offset %#llx (add it to the seeds)\n",
                (unsigned long long)(guest - IMG));
    } else {
        fprintf(stderr, "STOP: jump/call to non-guest address %#llx\n", (unsigned long long)guest);
    }
    recomp_backtrace();
    FILE *f = fopen("recomp_missing.txt", "a");
    if (f) { fprintf(f, "%llx\n", (unsigned long long)(guest - IMG)); fclose(f); }
    exit(23);
    return unknown_target;
}

/* ---------------------------------------------------------------- threads */
static __thread Ctx *tls_ctx;
static __thread int tls_ctx_owned;

Ctx *recomp_ctx(void) {
    Ctx *c = tls_ctx;
    if (!c) {
        /* A host thread entering guest code without recomp_thread_begin: private guest stack. */
        const size_t size = 1u << 20;
        void *stack = recomp_low_stack(size);
        recomp_thread_begin(stack, size);
        tls_ctx_owned = 1;
        c = tls_ctx;
    }
    return c;
}

static uint32_t initial_mxcsr = 0x1f80;
void recomp_thread_begin(void *stack, size_t size) {
    Ctx *c = calloc(1, sizeof(Ctx));
    c->r[4] = ((uint64_t)stack + size - 64) & ~15ULL;
    c->fcw = 0x37f;
    c->mxcsr = initial_mxcsr;
    tls_ctx = c;
    recomp_ldmxcsr(c, c->mxcsr);
}
void recomp_thread_end(void) { free(tls_ctx); tls_ctx = NULL; }
void recomp_set_fs(void *base) { recomp_ctx()->fs = (uint64_t)base; }
void *recomp_get_fs(void) { return tls_ctx ? (void *)tls_ctx->fs : NULL; }
uint32_t recomp_get_mxcsr(void) { return tls_ctx ? tls_ctx->mxcsr : initial_mxcsr; }
void recomp_set_mxcsr(uint32_t v) { if (tls_ctx) recomp_ldmxcsr(tls_ctx, v); else initial_mxcsr = v; }

#define GUEST_RETURN_SENTINEL 0x7ffffff0ULL
uint64_t recomp_guest_call(uint64_t fn, int n, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    Ctx *c = recomp_ctx();
    uint64_t saved[16];
    memcpy(saved, c->r, sizeof(saved));
    (void)n;
    c->r[7] = a0; c->r[6] = a1; c->r[2] = a2; c->r[1] = a3; c->r[8] = a4; c->r[9] = a5;
    uint64_t rsp = (saved[4] - 256) & ~15ULL;   /* below the caller's red zone, 16-byte aligned */
    rsp -= 8; st64(rsp, GUEST_RETURN_SENTINEL);
    c->r[4] = rsp;
    c->depth++;
    recomp_lookup(fn)(c);
    c->depth--;
    uint64_t result = c->r[0];
    /* callee-saved registers were restored by the guest; keep the outer frame's view */
    memcpy(c->r, saved, sizeof(saved));
    return result;
}

/* ---------------------------------------------------------------- CPU helpers */
static mach_timebase_info_data_t timebase;
uint64_t recomp_tsc_frequency(void) { return 1000000000ULL; }
uint64_t recomp_rdtsc(void) {
    if (!timebase.denom) mach_timebase_info(&timebase);
    return mach_absolute_time() * timebase.numer / timebase.denom; /* ns: a 1 GHz TSC */
}

void recomp_cpuid(uint64_t *rax, uint64_t *rbx, uint64_t *rcx, uint64_t *rdx) {
    /* AMD Jaguar (PS4) as the guest expects it. */
    uint32_t leaf = (uint32_t)*rax, a = 0, b = 0, cc = 0, d = 0;
    switch (leaf) {
    case 0: a = 0xd; b = 0x68747541; d = 0x69746e65; cc = 0x444d4163; break; /* AuthenticAMD */
    case 1: a = 0x00700f01; b = 0x00080800;
        cc = (1u << 0) | (1u << 1) | (1u << 9) | (1u << 13) | (1u << 19) | (1u << 20) | (1u << 22) | (1u << 23) |
             (1u << 25) | (1u << 26) | (1u << 27) | (1u << 28) | (1u << 29);
        d = 0x178bfbff; break;
    case 7: b = (1u << 3); break;
    case 0x80000000: a = 0x8000001e; b = 0x68747541; d = 0x69746e65; cc = 0x444d4163; break;
    case 0x80000001: cc = (1u << 0) | (1u << 5) | (1u << 6) | (1u << 8) | (1u << 11); d = 0x2fd3fbff; break;
    default: break;
    }
    *rax = a; *rbx = b; *rcx = cc; *rdx = d;
}

void recomp_ldmxcsr(Ctx *c, uint32_t v) {
    c->mxcsr = v;
    uint64_t fpcr;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    fpcr &= ~((3ULL << 22) | (1ULL << 24));
    static const uint64_t rmode[4] = { 0, 2, 1, 3 }; /* x86 RC: nearest, down, up, zero -> FPCR RN, RM, RP, RZ */
    fpcr |= rmode[(v >> 13) & 3] << 22;
    if (v & ((1u << 15) | (1u << 6))) fpcr |= 1ULL << 24; /* FTZ/DAZ -> FZ */
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr));
}

void recomp_backtrace(void) {
    void *frames[48];
    int n = backtrace(frames, 48);
    for (int i = 0; i < n; ++i) {
        Dl_info info;
        if (dladdr(frames[i], &info) && info.dli_sname)
            fprintf(stderr, "  #%d %s+%#lx\n", i, info.dli_sname, (unsigned long)((uintptr_t)frames[i] - (uintptr_t)info.dli_saddr));
        else
            fprintf(stderr, "  #%d %p\n", i, frames[i]);
    }
}

int recomp_describe_host_pc(uintptr_t pc, char *out, size_t size) {
    Dl_info info;
    if (dladdr((void *)pc, &info) && info.dli_sname) {
        snprintf(out, size, "%s+%#lx", info.dli_sname, (unsigned long)(pc - (uintptr_t)info.dli_saddr));
        return 1;
    }
    snprintf(out, size, "%#lx", (unsigned long)pc);
    return 0;
}

void recomp_trap(uint64_t at, const char *what) {
    fprintf(stderr, "STOP: guest trap '%s' at guest offset %#llx\n", what, (unsigned long long)at);
    recomp_backtrace();
    exit(24);
}
void recomp_unimpl(uint64_t at, const char *text) {
    fprintf(stderr, "STOP: unimplemented instruction at guest offset %#llx: %s\n", (unsigned long long)at, text);
    recomp_backtrace();
    exit(25);
}
void recomp_int(Ctx *c, uint64_t at, int n) {
    (void)c;
    fprintf(stderr, "STOP: guest int %#x at guest offset %#llx\n", n, (unsigned long long)at);
    recomp_backtrace();
    exit(26);
}
