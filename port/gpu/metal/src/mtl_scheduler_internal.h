// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: scheduler internals and the recording helpers for the renderer's
// Objective-C++ sources.
//
// Recording: the Metal calls go into closures (Record, RecordRender, RecordCompute, RecordBlit,
// BeginRender) that run on the encoder thread, in order (or at once without it). A closure may
// only use what it captured: copies of values and objects that stay alive until its tick
// completes (the caches free their objects through DeferOperation, which waits for the tick).
// Objects captured as strong references are retained by the closure; per-draw code captures
// __unsafe_unretained pointers of cache-owned objects instead (no retain/release).

#pragma once

#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "mtl_encode_ring.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

namespace Vulkan {

#ifdef __OBJC__
struct Scheduler::Impl {
    // ---- Encoding side (the encoder thread, or the recording thread without one) ----
    // Lanes (TLG_METAL_ASYNC_COMPUTE): 0 graphics, 1 compute; one queue and untracked-write
    // fence each (fences order encoders within one queue only).
    id<MTLCommandQueue> queues[2] = {nil, nil};
    id<MTLFence> fences[2] = {nil, nil};
    bool fence_pendings[2] = {false, false}; ///< an earlier encoder of the lane updated its fence
    int lane = 0;      ///< the lane recording goes to
    int open_lane = 0; ///< the lane of cmdbuf
    id<MTLSharedEvent> compute_event = nil;
    u64 compute_signaled = 0; ///< the event value of the last committed compute command buffer
    u64 graphics_waited = 0;  ///< the value the last graphics command buffer waits for
    u64 graphics_signaled = 0; ///< TLG_METAL_ASYNC_COMPUTE_SERIAL: compute waits for graphics
    id<MTLSharedEvent> graphics_event = nil;
    std::set<u64> inflight; ///< committed ticks not completed (the lanes complete out of order)
    u64 committed = 0;      ///< the last committed tick

    id<MTLCommandBuffer> cmdbuf = nil;
    id<MTLCommandEncoder> encoder = nil;
    Kind kind = Kind::None;
    bool encoder_wrote_untracked = false; ///< the open encoder wrote guest memory
    bool encoder_has_dispatch = false;    ///< the open compute encoder ran a dispatch
    bool internal_dispatch = false;       ///< the last dispatch was the renderer's own

    id<MTLFence> Fence() const {
        return fences[open_lane];
    }
    bool& FencePending() {
        return fence_pendings[open_lane];
    }

    // Encoding-side operations.
    id<MTLCommandBuffer> CommandBuffer();
    void EndEncoding();
    id<MTLComputeCommandEncoder> ComputeEncoder();
    id<MTLBlitCommandEncoder> BlitEncoder();
    id<MTLRenderCommandEncoder> RenderEncoder() const {
        return kind == Kind::Render ? (id<MTLRenderCommandEncoder>)encoder : nil;
    }
    void SetRenderEncoder(id<MTLRenderCommandEncoder> enc);
    void Commit(u64 tick, std::vector<std::function<void()>>&& signals,
                std::atomic<u64>* completed, const char* queue_name);

    Scheduler* owner = nullptr;

    // ---- The encoder thread ----
    std::unique_ptr<MetalScheduler::EncodeRing> ring; ///< null: closures run at once
    std::thread thread;
    std::thread watchdog;
    std::atomic<bool> watchdog_stop{false};

    template <typename F>
    void Record(F&& f) {
        if (ring) {
            ring->Push(std::forward<F>(f));
        } else {
            f();
        }
    }
    template <typename F>
    void RecordWith(const void* data, size_t bytes, F&& f) {
        if (ring) {
            ring->PushWith(data, bytes, std::forward<F>(f));
        } else {
            f(data);
        }
    }

    // ---- Shared ----
    std::mutex mutex; ///< completion
    std::condition_variable cv;
    std::mutex pending_mutex; ///< DeferOperation may come from guest threads (unmaps)
    std::deque<std::pair<u64, Common::UniqueFunction<void>>> pending;
    /// tlg: the front's tick (~0: none), so the per-draw PopPendingOperations needs no lock
    /// until one is due. Written under pending_mutex.
    std::atomic<u64> pending_front{~u64(0)};

    std::mutex signal_mutex;
    std::condition_variable signal_cv;
    std::vector<std::function<void()>> signals; ///< for the command buffer being recorded
    u64 signals_queued = 0;
    u64 signals_done = 0;
    std::deque<std::pair<u64, std::function<void()>>> after_signals; ///< RunAfterSignals, by target
};
#endif

namespace MetalScheduler {

/// The encoder thread runs (TLG_METAL_ENCODER_THREAD=0: off; never with async compute).
bool EncoderThreadEnabled();

/// tlg: compute encoders dispatch concurrently, as a GCN queue runs dispatches that no barrier
/// packet separates (98% of inFAMOUS's ~18000 compute dispatches a second; burning road 20 -> 28
/// FPS, cannery 24 -> 30). TLG_METAL_CONCURRENT_DISPATCH=0: serial, as before. The guest's dispatches wait for the earlier
/// ones only after such a packet (BeforeGuestDispatch); the renderer's own kernels after all
/// earlier work, and the next dispatch after them (BeforeInternalDispatch).
bool ConcurrentDispatch();

/// Profiling (TLG_METAL_PASS_STATS=1): counts why render passes end, by `why`; counted only while a render encoder is open.
bool PassStatsEnabled();
void NoteRenderBreak(Scheduler& scheduler, const char* why);
/// The counts since the last call, as " why:count" pairs (most frequent first), then reset.
std::string TakeRenderBreaks();

/// Profiling (TLG_METAL_LABEL=1): each compute job gets an encoder of its own named `label`,
/// for Metal System Trace.
inline bool LabelMode() {
    static const bool on = [] {
        const char* env = std::getenv("TLG_METAL_LABEL");
        return env && env[0] == '1';
    }();
    return on;
}

#ifdef __OBJC__
/// The open encoder writes guest memory (the untracked buffer): the next encoder waits for it.
/// Recorded: call it after recording the work that writes.
void NoteUntrackedWrite(Scheduler& scheduler);

void BeforeGuestDispatch(Scheduler::Impl& impl, id<MTLComputeCommandEncoder> enc, bool guest_barrier);
void BeforeInternalDispatch(Scheduler::Impl& impl, id<MTLComputeCommandEncoder> enc);

/// Records `f()` (Metal work outside an encoder, or state of the encoding side).
template <typename F>
inline void Record(Scheduler& s, F&& f) {
    s.impl_()->Record(std::forward<F>(f));
}

namespace detail {
/// A compute encoder for the next job: the open one, or a new one (each job its own in label
/// mode, named `label`).
inline void UseCompute(Scheduler& s, const char* label) {
    if (PassStatsEnabled()) {
        NoteRenderBreak(s, label);
    }
    if (LabelMode()) {
        s.EndEncoding();
    }
    s.UseEncoder(Scheduler::Kind::Compute);
}
inline id<MTLComputeCommandEncoder> ComputeFor(Scheduler::Impl& impl, const std::string& label) {
    id<MTLComputeCommandEncoder> enc = impl.ComputeEncoder();
    if (!label.empty()) {
        enc.label = [NSString stringWithUTF8String:label.c_str()];
    }
    return enc;
}
} // namespace detail

/// Records the renderer's own compute work, `f(id<MTLComputeCommandEncoder>)` (a barrier before
/// and after it with concurrent dispatch).
template <typename F>
inline void RecordCompute(Scheduler& s, const char* label, F&& f) {
    detail::UseCompute(s, label);
    Scheduler::Impl* impl = s.impl_();
    impl->Record([impl, name = LabelMode() ? std::string(label) : std::string(),
                  f = std::forward<F>(f)]() mutable {
        id<MTLComputeCommandEncoder> enc = detail::ComputeFor(*impl, name);
        BeforeInternalDispatch(*impl, enc);
        f(enc);
    });
}

/// Records a guest dispatch: waits for the earlier dispatches only after a guest barrier packet.
template <typename F>
inline void RecordComputeGuest(Scheduler& s, const char* label, bool guest_barrier, F&& f) {
    detail::UseCompute(s, label);
    Scheduler::Impl* impl = s.impl_();
    impl->Record([impl, guest_barrier, name = LabelMode() ? std::string(label) : std::string(),
                  f = std::forward<F>(f)]() mutable {
        id<MTLComputeCommandEncoder> enc = detail::ComputeFor(*impl, name);
        BeforeGuestDispatch(*impl, enc, guest_barrier);
        f(enc);
    });
}

/// Records `f(id<MTLBlitCommandEncoder>)`.
template <typename F>
inline void RecordBlit(Scheduler& s, const char* label, F&& f) {
    if (PassStatsEnabled()) {
        NoteRenderBreak(s, label);
    }
    s.UseEncoder(Scheduler::Kind::Blit);
    Scheduler::Impl* impl = s.impl_();
    impl->Record([impl, f = std::forward<F>(f)]() mutable { f(impl->BlitEncoder()); });
}

/// Opens a render pass: `make()` returns its MTLRenderPassDescriptor (built on the encoding
/// side). `pass_key` is the scheduler's RenderPassKey() while it is open.
template <typename F>
inline void BeginRender(Scheduler& s, u64 pass_key, F&& make) {
    s.EndEncoding();
    s.UseEncoder(Scheduler::Kind::Render, pass_key);
    Scheduler::Impl* impl = s.impl_();
    impl->Record([impl, make = std::forward<F>(make)]() mutable {
        MTLRenderPassDescriptor* rp = make();
        impl->EndEncoding();
        impl->SetRenderEncoder([impl->CommandBuffer() renderCommandEncoderWithDescriptor:rp]);
    });
}

/// Records `f(id<MTLRenderCommandEncoder>)` into the open render pass (nil if it failed to open).
template <typename F>
inline void RecordRender(Scheduler& s, F&& f) {
    Scheduler::Impl* impl = s.impl_();
    impl->Record([impl, f = std::forward<F>(f)]() mutable { f(impl->RenderEncoder()); });
}

/// As RecordRender, with a copy of `bytes` bytes at `data`: f(enc, const void* copy).
template <typename F>
inline void RecordRenderWith(Scheduler& s, const void* data, size_t bytes, F&& f) {
    Scheduler::Impl* impl = s.impl_();
    impl->RecordWith(data, bytes, [impl, f = std::forward<F>(f)](const void* copy) mutable {
        f(impl->RenderEncoder(), copy);
    });
}

/// Runs `f(id<MTLCommandBuffer>)` with the command buffer being recorded (after ending the open
/// encoder), e.g. to encode work of another library into it.
template <typename F>
inline void RecordCommandBuffer(Scheduler& s, F&& f) {
    s.EndEncoding();
    Scheduler::Impl* impl = s.impl_();
    impl->Record([impl, f = std::forward<F>(f)]() mutable { f(impl->CommandBuffer()); });
}
#endif

} // namespace MetalScheduler
} // namespace Vulkan
