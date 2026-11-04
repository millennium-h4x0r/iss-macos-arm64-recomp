// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: command buffers, encoders, ticks.
//
// Ordering: textures and the renderer's own buffers are hazard-tracked by Metal, which orders
// encoders that touch them as needed. Guest memory (one untracked MTLBuffer, mtl_buffer_cache)
// is ordered here: an encoder that wrote it updates a fence that the next encoder waits for
// (NoteUntrackedWrite).

#include <condition_variable>
#include <cstdio>
#include <algorithm>
#include <atomic>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "mtl_objc.h"
#include "mtl_scheduler_internal.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"

namespace Vulkan {

namespace {
enum class EncoderKind { None, Render, Compute, Blit };
std::atomic<u32> g_gpu_errors{0};
} // namespace

struct Scheduler::Impl {
    id<MTLCommandQueue> queue = nil;
    id<MTLCommandBuffer> cmdbuf = nil;
    id<MTLCommandEncoder> encoder = nil;
    EncoderKind kind = EncoderKind::None;
    id<MTLFence> fence = nil;
    bool encoder_wrote_untracked = false; ///< the open encoder wrote guest memory
    bool fence_pending = false;           ///< an earlier encoder updated the fence

    std::mutex mutex; ///< completion
    std::condition_variable cv;
    std::mutex pending_mutex; ///< DeferOperation may come from guest threads (unmaps)
    std::deque<std::pair<u64, Common::UniqueFunction<void>>> pending;

    std::mutex signal_mutex;
    std::condition_variable signal_cv;
    std::vector<std::function<void()>> signals; ///< for the command buffer being recorded
    u64 signals_queued = 0;
    u64 signals_done = 0;
};

namespace MetalScheduler {

void NoteUntrackedWrite(Scheduler& scheduler) {
    scheduler.impl_()->encoder_wrote_untracked = true;
}

namespace {
std::atomic<u64> g_gpu_busy_ns{0}; ///< GPU time of completed command buffers (TLG_METAL_PASS_STATS)
std::mutex g_break_mutex;
std::unordered_map<std::string, u64> g_breaks;
} // namespace

bool PassStatsEnabled() {
    static const bool on = [] {
        const char* env = std::getenv("TLG_METAL_PASS_STATS");
        return env && env[0] == '1';
    }();
    return on;
}

void NoteRenderBreak(Scheduler& scheduler, const char* why) {
    if (scheduler.impl_()->kind != EncoderKind::Render) {
        return;
    }
    std::scoped_lock lock{g_break_mutex};
    ++g_breaks[why];
}

std::string TakeRenderBreaks() {
    std::vector<std::pair<std::string, u64>> v;
    {
        std::scoped_lock lock{g_break_mutex};
        v.assign(g_breaks.begin(), g_breaks.end());
        g_breaks.clear();
    }
    std::sort(v.begin(), v.end(), [](const auto& a, const auto& b) { return a.second > b.second; });
    std::string out;
    char gpu[64];
    std::snprintf(gpu, sizeof(gpu), " | GPU busy %.0f ms", g_gpu_busy_ns.exchange(0) / 1e6);
    for (const auto& [why, n] : v) {
        out += " " + why + ":" + std::to_string(n);
    }
    return out + gpu;
}

} // namespace MetalScheduler

Scheduler::Scheduler(const Instance& instance, const char* name_)
    : impl{std::make_unique<Impl>()}, name{name_} {
    id<MTLDevice> device = (__bridge id<MTLDevice>)instance.MetalDevice();
    impl->queue = [device newCommandQueueWithMaxCommandBufferCount:64];
    impl->queue.label = [NSString stringWithUTF8String:name];
    impl->fence = [device newFence];
}

Scheduler::~Scheduler() {
    Finish();
}

void* Scheduler::CommandBuffer() {
    if (!impl->cmdbuf) {
        MTLCommandBufferDescriptor* desc = [MTLCommandBufferDescriptor new];
        desc.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
        impl->cmdbuf = [impl->queue commandBufferWithDescriptor:desc];
    }
    return (__bridge void*)impl->cmdbuf;
}

void Scheduler::EndEncoding() {
    if (!impl->encoder) {
        return;
    }
    if (impl->encoder_wrote_untracked) {
        if (impl->kind == EncoderKind::Render) {
            [(id<MTLRenderCommandEncoder>)impl->encoder updateFence:impl->fence
                                                        afterStages:MTLRenderStageFragment];
        } else if (impl->kind == EncoderKind::Compute) {
            [(id<MTLComputeCommandEncoder>)impl->encoder updateFence:impl->fence];
        } else {
            [(id<MTLBlitCommandEncoder>)impl->encoder updateFence:impl->fence];
        }
        impl->fence_pending = true;
        impl->encoder_wrote_untracked = false;
    }
    [impl->encoder endEncoding];
    impl->encoder = nil;
    impl->kind = EncoderKind::None;
    render_pass_key = 0;
}

void Scheduler::EndRendering() {
    if (impl->kind == EncoderKind::Render) {
        EndEncoding();
    }
}

void* Scheduler::ComputeEncoder() {
    if (impl->kind != EncoderKind::Compute) {
        EndEncoding();
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)CommandBuffer();
        id<MTLComputeCommandEncoder> enc =
            [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
        if (impl->fence_pending) {
            [enc waitForFence:impl->fence];
        }
        impl->encoder = enc;
        impl->kind = EncoderKind::Compute;
        ++encoders;
    }
    return (__bridge void*)impl->encoder;
}

void* Scheduler::BlitEncoder() {
    if (impl->kind != EncoderKind::Blit) {
        EndEncoding();
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)CommandBuffer();
        id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
        if (impl->fence_pending) {
            [enc waitForFence:impl->fence];
        }
        impl->encoder = enc;
        impl->kind = EncoderKind::Blit;
        ++encoders;
    }
    return (__bridge void*)impl->encoder;
}

void* Scheduler::CurrentRenderEncoder() const noexcept {
    return impl->kind == EncoderKind::Render ? (__bridge void*)impl->encoder : nullptr;
}

void Scheduler::SetRenderEncoder(void* encoder, u64 pass_key) {
    EndEncoding();
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    if (impl->fence_pending) {
        [enc waitForFence:impl->fence beforeStages:MTLRenderStageVertex];
    }
    impl->encoder = enc;
    impl->kind = EncoderKind::Render;
    render_pass_key = pass_key ? pass_key : 1;
    ++encoders;
}

void Scheduler::Flush() {
    if (MetalScheduler::PassStatsEnabled()) {
        MetalScheduler::NoteRenderBreak(*this, "flush");
    }
    EndEncoding();
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)CommandBuffer();
    const u64 tick = current_tick.load(std::memory_order_relaxed);
    std::vector<std::function<void()>> signals;
    {
        std::scoped_lock lock{impl->signal_mutex};
        signals.swap(impl->signals);
    }
    Impl* const state = impl.get();
    std::atomic<u64>* const completed = &completed_tick;
    const char* const queue_name = name;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status == MTLCommandBufferStatusError) {
            if (g_gpu_errors.fetch_add(1) < 20) {
                std::fprintf(stderr, "GPU: Metal command buffer %llu (%s) failed: %s\n",
                             (unsigned long long)tick, queue_name,
                             done.error.localizedDescription.UTF8String);
            }
        }
        if (MetalScheduler::PassStatsEnabled() && done.GPUEndTime > done.GPUStartTime) {
            // The union of the command buffers' GPU intervals (they overlap; one queue
            // completes in order).
            static double last_end = 0;
            const double start = std::max(done.GPUStartTime, last_end);
            if (done.GPUEndTime > start) {
                MetalScheduler::g_gpu_busy_ns.fetch_add(u64((done.GPUEndTime - start) * 1e9),
                                                        std::memory_order_relaxed);
            }
            last_end = std::max(last_end, done.GPUEndTime);
        }
        for (auto& signal : signals) {
            signal();
        }
        {
            std::scoped_lock lock{state->mutex};
            u64 prev = completed->load(std::memory_order_relaxed);
            while (prev < tick && !completed->compare_exchange_weak(prev, tick)) {
            }
        }
        state->cv.notify_all();
        if (!signals.empty()) {
            {
                std::scoped_lock lock{state->signal_mutex};
                state->signals_done += signals.size();
            }
            state->signal_cv.notify_all();
        }
    }];
    [cb commit];
    impl->cmdbuf = nil;
    // tlg: fence_pending stays set: command buffers of one queue start in order but may overlap
    // on the GPU, and guest memory is untracked, so the next command buffer's encoders still
    // wait for the last write (a fence works across the queue's command buffers). Resetting it
    // here let the mid-frame commits (TLG_METAL_COMMIT_DRAWS) read guest memory a compute job
    // in the previous command buffer was still writing: blocks of the opening cutscene's depth
    // of field in the wrong places for a frame.
    current_tick.store(tick + 1, std::memory_order_release);
    PopPendingOperations();
}

void Scheduler::Finish() {
    const u64 tick = CurrentTick();
    Flush();
    Wait(tick);
    PopPendingOperations();
}

void Scheduler::Wait(u64 tick) {
    if (tick >= CurrentTick()) {
        Flush();
    }
    if (IsFree(tick)) {
        return;
    }
    std::unique_lock lock{impl->mutex};
    impl->cv.wait(lock, [&] { return IsFree(tick); });
}

void Scheduler::DeferOperation(Common::UniqueFunction<void>&& func) {
    std::scoped_lock lock{impl->pending_mutex};
    impl->pending.emplace_back(CurrentTick(), std::move(func));
}

void Scheduler::PopPendingOperations() {
    for (;;) {
        Common::UniqueFunction<void> func;
        {
            std::scoped_lock lock{impl->pending_mutex};
            if (impl->pending.empty() || !IsFree(impl->pending.front().first)) {
                return;
            }
            func = std::move(impl->pending.front().second);
            impl->pending.pop_front();
        }
        func();
    }
}

void Scheduler::SignalOnCompletion(std::function<void()> func) {
    {
        std::scoped_lock lock{impl->signal_mutex};
        impl->signals.emplace_back(std::move(func));
        ++impl->signals_queued;
    }
    Flush();
}

void Scheduler::WaitSignals() {
    std::unique_lock lock{impl->signal_mutex};
    const u64 target = impl->signals_queued;
    impl->signal_cv.wait(lock, [&] { return impl->signals_done >= target; });
}

} // namespace Vulkan
