/* Host side of the recompiled guest: what the PS4 runtime (port/src) and the GPU library use to
 * reach guest code and guest thread state on Apple Silicon. */
#ifndef RECOMP_HOST_H
#define RECOMP_HOST_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Calls guest code at `fn` with up to six integer arguments (System V order) on the calling
 * thread's guest context; returns rax. */
uint64_t recomp_guest_call(uint64_t fn, int n, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5);
/* Prepares the calling host thread to run guest code on [stack, stack+size). */
void recomp_thread_begin(void *stack, size_t size);
void recomp_thread_end(void);
/* Guest TCB of the calling thread (fs:/gs: base). */
void recomp_set_fs(void *base);
void *recomp_get_fs(void);
/* Guest MXCSR of the calling thread (thread creation copies the creator's). */
uint32_t recomp_get_mxcsr(void);
void recomp_set_mxcsr(uint32_t v);
/* Guest code range, for diagnostics. */
int recomp_describe_host_pc(uintptr_t pc, char *out, size_t size);
#ifdef __cplusplus
}
#endif

#define GUEST_CALL0(f) recomp_guest_call((uint64_t)(uintptr_t)(f), 0, 0, 0, 0, 0, 0, 0)
#define GUEST_CALL1(f, a) recomp_guest_call((uint64_t)(uintptr_t)(f), 1, (uint64_t)(uintptr_t)(a), 0, 0, 0, 0, 0)
#define GUEST_CALL2(f, a, b) recomp_guest_call((uint64_t)(uintptr_t)(f), 2, (uint64_t)(uintptr_t)(a), (uint64_t)(uintptr_t)(b), 0, 0, 0, 0)
#define GUEST_CALL3(f, a, b, d) recomp_guest_call((uint64_t)(uintptr_t)(f), 3, (uint64_t)(uintptr_t)(a), (uint64_t)(uintptr_t)(b), (uint64_t)(uintptr_t)(d), 0, 0, 0)
#endif
