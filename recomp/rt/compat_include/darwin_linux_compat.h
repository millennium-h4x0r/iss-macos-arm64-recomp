/* Linux-only APIs the GPU library and runtime use, mapped onto macOS (force-included). */
#pragma once
#ifdef __APPLE__
#include <errno.h>
#include <pthread.h>
#include <time.h>
#include <stdint.h>
#include <sys/resource.h>
#include <unistd.h>
#include <sched.h>
#include <stdlib.h>
#include <sys/mman.h>
#ifdef __cplusplus
extern "C" {
#endif
static inline pid_t recomp_gettid(void) { uint64_t t = 0; pthread_threadid_np(NULL, &t); return (pid_t)t; }
#define gettid() recomp_gettid()
static inline int recomp_pthread_getcpuclockid(pthread_t t, clockid_t *c) { (void)t; (void)c; return ENOTSUP; }
#define pthread_getcpuclockid(t, c) recomp_pthread_getcpuclockid(t, c)
#ifndef RUSAGE_THREAD
#define RUSAGE_THREAD RUSAGE_SELF
#endif
/* struct stat timestamps */
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
#ifndef CLOCK_REALTIME_COARSE
#define CLOCK_REALTIME_COARSE CLOCK_REALTIME
#endif
#ifndef CLOCK_MONOTONIC_COARSE
#define CLOCK_MONOTONIC_COARSE CLOCK_MONOTONIC
#endif
#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_RECURSIVE_MUTEX_INITIALIZER
#endif
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0  /* callers check the returned address */
#endif
#ifndef TIMER_ABSTIME
#define TIMER_ABSTIME 1
#endif
static inline long recomp_getrandom(void *buf, size_t len, unsigned flags) { (void)flags; arc4random_buf(buf, len); return (long)len; }
#define getrandom(b, l, f) recomp_getrandom(b, l, f)
static inline int recomp_clock_nanosleep(clockid_t clock, int flags, const struct timespec *t, struct timespec *rem) {
    struct timespec d = *t;
    if (flags & TIMER_ABSTIME) {
        struct timespec now; clock_gettime(clock, &now);
        int64_t ns = (int64_t)(t->tv_sec - now.tv_sec) * 1000000000 + (t->tv_nsec - now.tv_nsec);
        if (ns <= 0) return 0;
        d.tv_sec = ns / 1000000000; d.tv_nsec = ns % 1000000000;
    }
    return nanosleep(&d, rem) ? errno : 0;
}
#define clock_nanosleep(c, f, t, r) recomp_clock_nanosleep(c, f, t, r)
/* Timed locks: polling (macOS has no pthread_*_timedlock). */
static inline int recomp_abs_passed(const struct timespec *end) {
    struct timespec now; clock_gettime(CLOCK_REALTIME, &now);
    return now.tv_sec > end->tv_sec || (now.tv_sec == end->tv_sec && now.tv_nsec >= end->tv_nsec);
}
static inline int recomp_pthread_mutex_timedlock(pthread_mutex_t *m, const struct timespec *end) {
    for (unsigned spin = 0;; ++spin) {
        int e = pthread_mutex_trylock(m);
        if (e != EBUSY) return e;
        if (recomp_abs_passed(end)) return ETIMEDOUT;
        if (spin < 64) sched_yield(); else { struct timespec d = {0, 100000}; nanosleep(&d, NULL); }
    }
}
#define pthread_mutex_timedlock(m, t) recomp_pthread_mutex_timedlock(m, t)
static inline int recomp_pthread_rwlock_timedrdlock(pthread_rwlock_t *l, const struct timespec *end) {
    for (unsigned spin = 0;; ++spin) {
        int e = pthread_rwlock_tryrdlock(l);
        if (e != EBUSY) return e;
        if (recomp_abs_passed(end)) return ETIMEDOUT;
        if (spin < 64) sched_yield(); else { struct timespec d = {0, 100000}; nanosleep(&d, NULL); }
    }
}
static inline int recomp_pthread_rwlock_timedwrlock(pthread_rwlock_t *l, const struct timespec *end) {
    for (unsigned spin = 0;; ++spin) {
        int e = pthread_rwlock_trywrlock(l);
        if (e != EBUSY) return e;
        if (recomp_abs_passed(end)) return ETIMEDOUT;
        if (spin < 64) sched_yield(); else { struct timespec d = {0, 100000}; nanosleep(&d, NULL); }
    }
}
#define pthread_rwlock_timedrdlock(l, t) recomp_pthread_rwlock_timedrdlock(l, t)
#define pthread_rwlock_timedwrlock(l, t) recomp_pthread_rwlock_timedwrlock(l, t)
static inline int sched_getcpu(void) { return 0; }
#ifdef __cplusplus
}
#endif
#endif
