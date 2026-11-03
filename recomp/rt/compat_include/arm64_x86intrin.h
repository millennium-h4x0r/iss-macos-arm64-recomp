/* Apple Silicon stand-in for the x86 intrinsic headers the host code includes: SSE/AVX intrinsics
 * through SIMDe (native names), rdtsc from the ARM generic timer, pause as yield. */
#pragma once
#if defined(__aarch64__)
#ifndef SIMDE_ENABLE_NATIVE_ALIASES
#define SIMDE_ENABLE_NATIVE_ALIASES
#endif
#include "simde/x86/avx2.h"
#include "simde/x86/sse4.2.h"
#include "simde/x86/f16c.h"
#include <stdint.h>
static inline uint64_t __rdtsc(void) { uint64_t v; __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v)); return v; }
#define __builtin_ia32_pause() __asm__ volatile("yield")
#ifndef _mm_pause
#define _mm_pause() __asm__ volatile("yield")
#endif
#endif
