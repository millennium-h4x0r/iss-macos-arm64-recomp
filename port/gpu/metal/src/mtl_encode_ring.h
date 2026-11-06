// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the encoder thread's command ring. The command processor thread records
// closures (the Metal calls of a draw, a dispatch, a copy, a commit) into a ring; the encoder
// thread runs them in order. One producer, one consumer, no locks on the way: each closure is
// constructed in place in the ring, the consumer runs and destroys it where it lies.

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <type_traits>
#include <utility>

namespace Vulkan::MetalScheduler {

class EncodeRing {
public:
    explicit EncodeRing(size_t capacity);
    ~EncodeRing();

    EncodeRing(const EncodeRing&) = delete;
    EncodeRing& operator=(const EncodeRing&) = delete;

    /// Producer: records `f` (run as f() on the consumer thread).
    template <typename F>
    void Push(F&& f) {
        using C = std::decay_t<F>;
        static_assert(alignof(C) <= alignof(Header), "closure over-aligned");
        constexpr uint32_t size = Align(sizeof(Header) + sizeof(C));
        Header* h = Reserve(size);
        h->run = &Run<C>;
        h->size = size;
        ::new (static_cast<void*>(h + 1)) C(std::forward<F>(f));
        Advance(size);
    }

    /// Producer: records `f` with a copy of `bytes` bytes at `data` (16-byte aligned), run as
    /// f(const void* copy) on the consumer thread.
    template <typename F>
    void PushWith(const void* data, size_t bytes, F&& f) {
        using C = std::decay_t<F>;
        static_assert(alignof(C) <= alignof(Header), "closure over-aligned");
        constexpr uint32_t closure = Align(sizeof(Header) + sizeof(C));
        const uint32_t size = closure + Align(uint32_t(bytes));
        Header* h = Reserve(size);
        h->run = &RunWith<C>;
        h->size = size;
        h->data_off = closure;
        ::new (static_cast<void*>(h + 1)) C(std::forward<F>(f));
        if (bytes) {
            std::memcpy(reinterpret_cast<char*>(h) + closure, data, bytes);
        }
        Advance(size);
    }

    /// Producer: makes everything recorded visible to the consumer (recording publishes in
    /// batches of PublishBytes on its own).
    void Publish();

    /// Producer: waits until the consumer has run everything recorded.
    void WaitIdle();
    /// Consumer: runs closures until Stop(). `batch` is called around each run of closures
    /// (an autorelease pool on the Objective-C side).
    void Consume(void (*batch)(EncodeRing& ring, void (*body)(EncodeRing&)));
    /// Producer: ends Consume once everything recorded has run.
    void Stop();

    /// Watchdog: published and consumed positions, and whether the consumer sleeps.
    uint64_t Published() const {
        return head.load(std::memory_order_relaxed);
    }
    uint64_t Consumed() const {
        return tail_seen.load(std::memory_order_relaxed);
    }
    bool ConsumerSleeping() const {
        return consumer_sleeping.load(std::memory_order_relaxed);
    }

    /// Statistics: closures run, consumer wake-ups, producer waits for space.
    std::atomic<uint64_t> runs{0}, wakeups{0}, full_waits{0};

private:
    struct alignas(16) Header {
        void (*run)(Header*); ///< null: padding up to the end of the ring
        uint32_t size;        ///< of the entry, header included
        uint32_t data_off;    ///< PushWith: the copy's offset from the header
    };

    static constexpr uint32_t Align(size_t n) {
        return uint32_t((n + 15) & ~size_t(15));
    }
    template <typename C>
    static void Run(Header* h) {
        C* c = std::launder(reinterpret_cast<C*>(h + 1));
        (*c)();
        c->~C();
    }
    template <typename C>
    static void RunWith(Header* h) {
        C* c = std::launder(reinterpret_cast<C*>(h + 1));
        (*c)(static_cast<const void*>(reinterpret_cast<const char*>(h) + h->data_off));
        c->~C();
    }

    static constexpr uint64_t PublishBytes = 2048;

    Header* Reserve(uint32_t size);
    void Advance(uint32_t size) {
        head_local += size;
        if (head_local - head_published >= PublishBytes) {
            Publish();
        }
    }
    void WaitSpace(uint64_t needed_tail);
    void RunAvailable();
    static void RunAvailableThunk(EncodeRing& ring) {
        ring.RunAvailable();
    }
    Header* At(uint64_t pos) const {
        return reinterpret_cast<Header*>(base + (pos % capacity));
    }

    char* base = nullptr;
    uint64_t capacity = 0;
    uint64_t head_local = 0; ///< producer's
    uint64_t head_published = 0; ///< producer's: the last value stored to head
    uint64_t tail_cached = 0; ///< producer's view of tail
    uint64_t tail_local = 0; ///< consumer's

    alignas(64) std::atomic<uint64_t> head{0}; ///< published by the producer
    alignas(64) std::atomic<uint64_t> tail{0}; ///< published by the consumer
    alignas(64) std::atomic<bool> consumer_sleeping{false};
    std::atomic<uint32_t> consumer_wake{0};
    alignas(64) std::atomic<bool> producer_waiting{false};
    std::atomic<uint32_t> producer_wake{0};
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> tail_seen{0}; ///< the consumer's position after each batch (watchdog)
};

} // namespace Vulkan::MetalScheduler
