/* Runs every generated instruction test on seeded random states and prints one hash line per run.
 * Built twice: -arch x86_64 (the reference, under Rosetta) and arm64 (the lifted C).
 * DETAIL=<test name> prints the full output state of that test's runs. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>

#define MEMBASE 0x7100000000ULL
#define MEMSIZE 0x10000ULL
#define RUNS 24

typedef struct { uint64_t r[16]; uint64_t flags; uint64_t pad[7]; uint8_t ymm[16][32]; } State;
#ifdef __x86_64__
extern unsigned char st[1024];
typedef void (*TestFn)(void);
extern TestFn x86_tests[];
#else
#include "x86.h"
typedef void (*TestFn)(Ctx *);
extern const TestFn arm_tests[];
#endif

static uint64_t rng;
static uint64_t next(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }
static uint64_t fnv(const void *p, size_t n) {
    const uint8_t *b = p; uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; ++i) { h ^= b[i]; h *= 1099511628211ULL; }
    return h;
}
static uint64_t vec_value(void) {
    switch (next() % 6) {
    case 0: return next();
    case 1: { float f[2] = { (float)((int)(next() % 2001) - 1000) / 8.0f, (float)((int)(next() % 2001) - 1000) / 3.0f };
              uint64_t v; memcpy(&v, f, 8); return v; }
    case 2: { double d = (double)((int64_t)(next() % 200001) - 100000) / 7.0; uint64_t v; memcpy(&v, &d, 8); return v; }
    case 3: return next() & 0x00ff00ff00ff00ffULL;
    case 4: { float f[2] = { 1.5f, -0.25f }; uint64_t v; memcpy(&v, f, 8); return v ^ (next() & 0x0000000f0000000fULL); }
    default: return next() % 300;
    }
}
static sigjmp_buf trap;
static void on_signal(int sig) { siglongjmp(trap, sig); }

int main(int argc, char **argv) {
    const char *cases_path = argc > 1 ? argv[1] : "cases.txt";
    const char *detail = getenv("DETAIL");
    FILE *f = fopen(cases_path, "r");
    if (!f) { perror("cases"); return 1; }
    unsigned char *mem = mmap((void *)MEMBASE, MEMSIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    if (mem != (void *)MEMBASE) { fprintf(stderr, "cannot map test memory\n"); return 1; }
    signal(SIGILL, on_signal); signal(SIGSEGV, on_signal); signal(SIGBUS, on_signal); signal(SIGFPE, on_signal);
    char line[512];
    int index = 0;
    while (fgets(line, sizeof line, f)) {
        char name[32], bases[128] = "", text[256] = "";
        unsigned long mask; char addr[32];
        if (sscanf(line, "%31s\t%lu\t%127[^\t]\t%31s\t%255[^\n]", name, &mask, bases, addr, text) < 4) {
            /* empty base list: shift fields */
            if (sscanf(line, "%31s\t%lu\t\t%31s\t%255[^\n]", name, &mask, addr, text) < 3) { ++index; continue; }
            bases[0] = 0;
        }
        int is_base[16] = {0}; /* 1 base (points into the buffer), 2 index (small) */
        for (char *p = bases; *p;) { int r = (int)strtol(p, &p, 10); if (r >= 0 && r < 16) is_base[r] = 1; else if (r < 0 && -1 - r < 16) is_base[-1 - r] = 2; if (*p == ',') ++p; else break; }
        for (int run = 0; run < RUNS; ++run) {
            rng = 0x9e3779b97f4a7c15ULL ^ ((uint64_t)index << 20) ^ (uint64_t)run;
            for (int k = 0; k < 4; ++k) next();
            State s; memset(&s, 0, sizeof s);
            for (int r = 0; r < 16; ++r) {
                s.r[r] = run % 3 == 0 ? next() : run % 3 == 1 ? next() % 64 : next() & 0xffffffffULL;
                if (is_base[r] == 1) s.r[r] = MEMBASE + 0x4000 + (next() % 64) * 64;
                else if (is_base[r] == 2) s.r[r] = next() % 8;
            }
            s.r[4] = 0;
            s.flags = (next() & 0x8d5) | 2;
            for (int v = 0; v < 16; ++v) for (int q = 0; q < 4; ++q) { uint64_t x = vec_value(); memcpy(&s.ymm[v][q * 8], &x, 8); }
            for (uint64_t i = 0; i < MEMSIZE; i += 8) { uint64_t x = vec_value(); memcpy(mem + i, &x, 8); }
            int sig = sigsetjmp(trap, 1);
            if (sig) { printf("%s %d SIGNAL %d\n", name, run, sig); continue; }
#ifdef __x86_64__
            memcpy(st, &s, sizeof s);
            uint64_t rsp_slot; memcpy(&rsp_slot, st + 32, 8);
            x86_tests[index]();
            memcpy(&s, st, sizeof s);
#else
            Ctx c; memset(&c, 0, sizeof c);
            memcpy(c.r, s.r, sizeof c.r); c.flags = s.flags;
            for (int v = 0; v < 16; ++v) { memcpy(&c.x[v].lo, s.ymm[v], 16); memcpy(&c.x[v].hi, s.ymm[v] + 16, 16); }
            c.mxcsr = 0x1f80;
            arm_tests[index](&c);
            memcpy(s.r, c.r, sizeof c.r); s.flags = c.flags;
            for (int v = 0; v < 16; ++v) { memcpy(s.ymm[v], &c.x[v].lo, 16); memcpy(s.ymm[v] + 16, &c.x[v].hi, 16); }
#endif
            s.r[4] = 0;
            uint64_t fl = s.flags & mask;
            printf("%s %d %016llx %03llx %016llx %016llx\n", name, run, (unsigned long long)fnv(s.r, sizeof s.r),
                   (unsigned long long)fl, (unsigned long long)fnv(s.ymm, sizeof s.ymm), (unsigned long long)fnv(mem, MEMSIZE));
            if (detail && !strcmp(detail, name)) {
                for (int r = 0; r < 16; ++r) printf("  r%d=%016llx\n", r, (unsigned long long)s.r[r]);
                printf("  flags=%03llx (mask %03lx)\n", (unsigned long long)s.flags, mask);
                for (int v = 0; v < 16; ++v) {
                    printf("  ymm%d=", v);
                    for (int q = 3; q >= 0; --q) { uint64_t x; memcpy(&x, &s.ymm[v][q * 8], 8); printf("%016llx ", (unsigned long long)x); }
                    printf("\n");
                }
            }
        }
        ++index;
    }
    return 0;
}
