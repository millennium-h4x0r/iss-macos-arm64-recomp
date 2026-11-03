/* Runtime-internal declarations shared by the recompiler runtime files. */
#ifndef RECOMP_RT_H
#define RECOMP_RT_H
#include "x86.h"

typedef struct {
    void *fn;              /* host function, NULL: unresolved */
    const char *name;      /* NID#library */
    const char *label;     /* readable name, if known */
    int variadic, trace;
} RecompImport;

extern RecompImport *recomp_imports;
extern uint64_t recomp_import_count;
extern uint64_t recomp_image_size;

void recomp_table_init(void);
Ctx *recomp_ctx(void);
void recomp_hostcall(void *fn, const uint64_t ints[8], const void *vecs, const uint64_t *stack, uint64_t nstack, uint64_t out[6]);
void recomp_backtrace(void);
void *recomp_low_stack(size_t size);
uint64_t recomp_tsc_frequency(void);
#endif
