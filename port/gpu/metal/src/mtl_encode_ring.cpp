// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the encoder thread's command ring (mtl_encode_ring.h).
//
// Sleeping: the consumer spins a little when the ring is empty, then announces that it sleeps
// (consumer_sleeping) and waits on consumer_wake; the producer, after publishing, wakes it only
// when it announced so. Both sides store their flag/position and then load the other's with
// sequentially consistent accesses (stlr/ldar on arm64, no barrier instructions), so one of them
// always sees the other. The producer waits for space (or idle) the same way.

#include "mtl_encode_ring.h"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <thread>

#include <os/os_sync_wait_on_address.h>

namespace Vulkan::MetalScheduler {

namespace {
inline void CpuRelax() {
#if defined(__aarch64__)
    __asm__ __volatile__("yield");
#endif
}
/// The virtual counter (24 MHz on Apple silicon): a clock without a system call.
inline uint64_t Ticks() {
#if defined(__aarch64__)
    uint64_t v;
    __asm__ __volatile__("mrs %0, cntvct_el0" : "=r"(v));
    return v;
#else
    return 0;
#endif
}
inline uint64_t TicksPerSecond() {
#if defined(__aarch64__)
    uint64_t v;
    __asm__ __volatile__("mrs %0, cntfrq_el0" : "=r"(v));
    return v;
#else
    return 1;
#endif
}
/// Loads `*p` and arms the core's exclusive monitor on its cache line: a store by another core
/// to that line sends the event a following WFE waits for.
inline uint64_t LoadArm(const std::atomic<uint64_t>& p) {
#if defined(__aarch64__)
    uint64_t v;
    __asm__ __volatile__("ldaxr %0, [%1]" : "=r"(v) : "r"(&p) : "memory");
    return v;
#else
    return p.load(std::memory_order_acquire);
#endif
}
inline void WaitForEvent() {
#if defined(__aarch64__)
    __asm__ __volatile__("wfe" ::: "memory");
#endif
}
/// Waits up to `us` microseconds for `*word != unexpected` in the low-power WFE state (woken
/// by the other thread's store to the word's cache line, no system call on either side; a
/// spinning core took the GPU's and the other cores' power: -8% FPS). Returns the last value.
uint64_t WaitChange(const std::atomic<uint64_t>& word, uint64_t unexpected, uint64_t us) {
    static const uint64_t per_us = TicksPerSecond() / 1000000 ? TicksPerSecond() / 1000000 : 1;
    const uint64_t end = Ticks() + us * per_us;
    for (;;) {
        const uint64_t v = LoadArm(word);
        if (v != unexpected || Ticks() >= end) {
            return v;
        }
        WaitForEvent();
    }
}
/// How long the consumer waits in WFE before it sleeps in the kernel (then the producer's next
/// publish wakes it with a system call). TLG_METAL_ENCODER_SPIN_US.
uint64_t ConsumerSpinUs() {
    static const uint64_t us = [] {
        const char* v = std::getenv("TLG_METAL_ENCODER_SPIN_US");
        return v ? uint64_t(std::strtoull(v, nullptr, 0)) : uint64_t(2000);
    }();
    return us;
}
void WaitOn(std::atomic<uint32_t>& word, uint32_t expected) {
    while (word.load(std::memory_order_acquire) == expected) {
        const int r = os_sync_wait_on_address(reinterpret_cast<void*>(&word), expected, sizeof(uint32_t),
                                              OS_SYNC_WAIT_ON_ADDRESS_NONE);
        if (r < 0 && errno != EINTR && errno != EFAULT) {
            return;
        }
    }
}
void Wake(std::atomic<uint32_t>& word) {
    word.fetch_add(1, std::memory_order_release);
    os_sync_wake_by_address_any(reinterpret_cast<void*>(&word), sizeof(uint32_t),
                                OS_SYNC_WAKE_BY_ADDRESS_NONE);
}
} // namespace

EncodeRing::EncodeRing(size_t capacity_) : capacity{(capacity_ + 4095) & ~size_t(4095)} {
    base = static_cast<char*>(std::aligned_alloc(64, capacity));
    if (!base) {
        std::fprintf(stderr, "EncodeRing: out of memory\n");
        std::abort();
    }
}

EncodeRing::~EncodeRing() {
    std::free(base);
}

EncodeRing::Header* EncodeRing::Reserve(uint32_t size) {
    if (size > capacity / 4) {
        std::fprintf(stderr, "EncodeRing: entry of %u bytes too large\n", size);
        std::abort();
    }
    uint64_t off = head_local % capacity;
    const uint64_t pad = off + size > capacity ? capacity - off : 0;
    const uint64_t end = head_local + pad + size;
    if (end - tail_cached > capacity) {
        tail_cached = tail.load(std::memory_order_acquire);
        if (end - tail_cached > capacity) {
            WaitSpace(end - capacity);
        }
    }
    if (pad) {
        Header* p = At(head_local);
        p->run = nullptr;
        p->size = uint32_t(pad);
        head_local += pad;
    }
    return At(head_local);
}

void EncodeRing::Publish() {
    if (head_published == head_local) {
        return;
    }
    head_published = head_local;
    head.store(head_local, std::memory_order_seq_cst);
    if (consumer_sleeping.load(std::memory_order_seq_cst)) {
        Wake(consumer_wake);
    }
}

void EncodeRing::WaitSpace(uint64_t needed_tail) {
    Publish();
    full_waits.fetch_add(1, std::memory_order_relaxed);
    for (int i = 0; i < 1000; ++i) {
        // tail moves in steps (each batch, every 64 KB): wait for each step in WFE.
        tail_cached = tail.load(std::memory_order_acquire);
        if (tail_cached >= needed_tail) {
            return;
        }
        WaitChange(tail, tail_cached, 200);
    }
    for (;;) {
        const uint32_t seq = producer_wake.load(std::memory_order_acquire);
        producer_waiting.store(true, std::memory_order_seq_cst);
        if ((tail_cached = tail.load(std::memory_order_seq_cst)) >= needed_tail) {
            producer_waiting.store(false, std::memory_order_relaxed);
            return;
        }
        WaitOn(producer_wake, seq);
        producer_waiting.store(false, std::memory_order_relaxed);
    }
}

void EncodeRing::WaitIdle() {
    Publish();
    if (tail.load(std::memory_order_acquire) == head_local) {
        return;
    }
    WaitSpace(head_local);
}

void EncodeRing::Stop() {
    Publish();
    stop.store(true, std::memory_order_seq_cst);
    Wake(consumer_wake);
}

void EncodeRing::RunAvailable() {
    uint64_t h = head.load(std::memory_order_acquire);
    while (tail_local != h) {
        Header* e = At(tail_local);
        const uint32_t size = e->size;
        if (e->run) {
            e->run(e);
            runs.fetch_add(1, std::memory_order_relaxed);
        }
        tail_local += size;
        if (tail_local == h) {
            // Published once per batch: the producer reads it only when the ring is full.
            tail.store(tail_local, std::memory_order_seq_cst);
            if (producer_waiting.load(std::memory_order_seq_cst)) {
                Wake(producer_wake);
            }
            h = head.load(std::memory_order_acquire);
        } else if ((tail_local & 0xFFFF) < size) {
            tail.store(tail_local, std::memory_order_release); // progress inside a long batch
        }
    }
}

void EncodeRing::Consume(void (*batch)(EncodeRing& ring, void (*body)(EncodeRing&))) {
    for (;;) {
        if (head.load(std::memory_order_acquire) != tail_local) {
            batch(*this, &RunAvailableThunk);
            tail_seen.store(tail_local, std::memory_order_relaxed);
            continue;
        }
        if (WaitChange(head, tail_local, ConsumerSpinUs()) != tail_local) {
            continue;
        }
        if (stop.load(std::memory_order_acquire)) {
            return;
        }
        const uint32_t seq = consumer_wake.load(std::memory_order_acquire);
        consumer_sleeping.store(true, std::memory_order_seq_cst);
        if (head.load(std::memory_order_seq_cst) == tail_local && !stop.load(std::memory_order_seq_cst)) {
            WaitOn(consumer_wake, seq);
            wakeups.fetch_add(1, std::memory_order_relaxed);
        }
        consumer_sleeping.store(false, std::memory_order_relaxed);
    }
}

} // namespace Vulkan::MetalScheduler
