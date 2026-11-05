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
#include <set>
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
    EncoderKind kind = EncoderKind::None;
    bool encoder_wrote_untracked = false; ///< the open encoder wrote guest memory
    bool encoder_has_dispatch = false;    ///< the open compute encoder ran a dispatch
    bool internal_dispatch = false;       ///< the last dispatch was the renderer's own

    id<MTLFence> Fence() const {
        return fences[open_lane];
    }
    bool& FencePending() {
        return fence_pendings[open_lane];
    }

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

bool ConcurrentDispatch() {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_CONCURRENT_DISPATCH");
        return !v || v[0] != '0';
    }();
    return on;
}

namespace {
void Barrier(id<MTLComputeCommandEncoder> enc) {
    [enc memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures];
}
} // namespace

void BeforeGuestDispatch(Scheduler& scheduler, id<MTLComputeCommandEncoder> enc, bool guest_barrier) {
    auto* impl = scheduler.impl_();
    if (ConcurrentDispatch() && impl->encoder_has_dispatch && (guest_barrier || impl->internal_dispatch)) {
        Barrier(enc);
    }
    impl->encoder_has_dispatch = true;
    impl->internal_dispatch = false;
}

void BeforeInternalDispatch(Scheduler& scheduler, id<MTLComputeCommandEncoder> enc) {
    auto* impl = scheduler.impl_();
    if (ConcurrentDispatch() && impl->encoder_has_dispatch) {
        Barrier(enc);
    }
    impl->encoder_has_dispatch = true;
    impl->internal_dispatch = true;
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
    impl->queues[0] = [device newCommandQueueWithMaxCommandBufferCount:64];
    impl->queues[0].label = [NSString stringWithUTF8String:name];
    impl->fences[0] = [device newFence];
    if (AsyncCompute()) {
        impl->queues[1] = [device newCommandQueueWithMaxCommandBufferCount:64];
        impl->queues[1].label = [NSString stringWithFormat:@"%s compute", name];
        impl->fences[1] = [device newFence];
        impl->compute_event = [device newSharedEvent];
        impl->graphics_event = [device newSharedEvent];
        std::printf("GPU (Metal): async compute on (a second queue for the guest's compute queues)\n");
    }
}

bool Scheduler::AsyncCompute() noexcept {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_ASYNC_COMPUTE");
        return v && v[0] == '1';
    }();
    return on;
}

void Scheduler::SelectLane(int lane) noexcept {
    if (impl->queues[1]) {
        impl->lane = lane;
    }
}

Scheduler::~Scheduler() {
    Finish();
}

namespace {
/// Opens a command buffer on the selected lane (none may be open).
void OpenCommandBuffer(Scheduler::Impl& impl);
} // namespace

void* Scheduler::CommandBuffer() {
    if (impl->cmdbuf && impl->open_lane != impl->lane) {
        Flush(); // the other lane's work goes to its queue now
    }
    if (!impl->cmdbuf) {
        OpenCommandBuffer(*impl);
    }
    return (__bridge void*)impl->cmdbuf;
}

namespace {
void OpenCommandBuffer(Scheduler::Impl& impl_ref) {
    Scheduler::Impl* const impl = &impl_ref;
    {
        MTLCommandBufferDescriptor* desc = [MTLCommandBufferDescriptor new];
        desc.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
        impl->open_lane = impl->lane;
        impl->cmdbuf = [impl->queues[impl->open_lane] commandBufferWithDescriptor:desc];
        if (impl->queues[1]) {
            static const bool serial = [] {
                const char* v = std::getenv("TLG_METAL_ASYNC_COMPUTE_SERIAL");
                return v && v[0] == '1';
            }();
            if (impl->open_lane == 0 && impl->compute_signaled > impl->graphics_waited) {
                // Graphics after compute: everything the compute lane committed before it.
                [impl->cmdbuf encodeWaitForEvent:impl->compute_event value:impl->compute_signaled];
                impl->graphics_waited = impl->compute_signaled;
            } else if (impl->open_lane == 1 && serial && impl->graphics_signaled) {
                [impl->cmdbuf encodeWaitForEvent:impl->graphics_event value:impl->graphics_signaled];
            }
        }
    }
}
} // namespace

void Scheduler::EndEncoding() {
    if (!impl->encoder) {
        return;
    }
    if (impl->encoder_wrote_untracked) {
        if (impl->kind == EncoderKind::Render) {
            [(id<MTLRenderCommandEncoder>)impl->encoder updateFence:impl->Fence()
                                                        afterStages:MTLRenderStageFragment];
        } else if (impl->kind == EncoderKind::Compute) {
            [(id<MTLComputeCommandEncoder>)impl->encoder updateFence:impl->Fence()];
        } else {
            [(id<MTLBlitCommandEncoder>)impl->encoder updateFence:impl->Fence()];
        }
        impl->FencePending() = true;
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
    if (impl->kind != EncoderKind::Compute || impl->open_lane != impl->lane) {
        EndEncoding();
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)CommandBuffer();
        id<MTLComputeCommandEncoder> enc = [cb
            computeCommandEncoderWithDispatchType:MetalScheduler::ConcurrentDispatch() ? MTLDispatchTypeConcurrent
                                                                                        : MTLDispatchTypeSerial];
        impl->encoder_has_dispatch = false;
        if (impl->FencePending()) {
            [enc waitForFence:impl->Fence()];
        }
        impl->encoder = enc;
        impl->kind = EncoderKind::Compute;
        ++encoders;
    }
    return (__bridge void*)impl->encoder;
}

void* Scheduler::BlitEncoder() {
    if (impl->kind != EncoderKind::Blit || impl->open_lane != impl->lane) {
        EndEncoding();
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)CommandBuffer();
        id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
        if (impl->FencePending()) {
            [enc waitForFence:impl->Fence()];
        }
        impl->encoder = enc;
        impl->kind = EncoderKind::Blit;
        ++encoders;
    }
    return (__bridge void*)impl->encoder;
}

void* Scheduler::CurrentRenderEncoder() const noexcept {
    return impl->kind == EncoderKind::Render && impl->open_lane == impl->lane ? (__bridge void*)impl->encoder
                                                                              : nullptr;
}

void Scheduler::SetRenderEncoder(void* encoder, u64 pass_key) {
    EndEncoding();
    id<MTLRenderCommandEncoder> enc = (__bridge id<MTLRenderCommandEncoder>)encoder;
    if (impl->FencePending()) {
        [enc waitForFence:impl->Fence() beforeStages:MTLRenderStageVertex];
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
    if (!impl->cmdbuf) {
        OpenCommandBuffer(*impl);
    }
    id<MTLCommandBuffer> cb = impl->cmdbuf;
    const u64 tick = current_tick.load(std::memory_order_relaxed);
    std::vector<std::function<void()>> signals;
    {
        std::scoped_lock lock{impl->signal_mutex};
        signals.swap(impl->signals);
    }
    Impl* const state = impl.get();
    std::atomic<u64>* const completed = &completed_tick;
    const char* const queue_name = name;
    if (impl->queues[1]) {
        if (impl->open_lane == 1) {
            [cb encodeSignalEvent:impl->compute_event value:++impl->compute_signaled];
        } else {
            [cb encodeSignalEvent:impl->graphics_event value:++impl->graphics_signaled];
        }
    }
    {
        std::scoped_lock lock{impl->mutex};
        impl->inflight.insert(tick);
        impl->committed = tick;
    }
    // TLG_METAL_LANE_STATS=1: per lane and second, the command buffers' wait before the GPU
    // started them, their GPU time, and the delay of their completion handler.
    static const bool lane_stats = std::getenv("TLG_METAL_LANE_STATS") != nullptr;
    const int lane = impl->open_lane;
    const double commit_time = lane_stats ? CACurrentMediaTime() : 0.0;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (lane_stats && done.GPUEndTime > 0) {
            static std::mutex m;
            static double sums[2][3]{}, maxs[2][3]{};
            static u64 counts[2]{};
            static double last = 0;
            const double now = CACurrentMediaTime();
            const double v[3] = {done.GPUStartTime - commit_time, done.GPUEndTime - done.GPUStartTime,
                                 now - done.GPUEndTime};
            std::scoped_lock lk{m};
            ++counts[lane];
            for (int i = 0; i < 3; ++i) {
                sums[lane][i] += v[i];
                maxs[lane][i] = std::max(maxs[lane][i], v[i]);
            }
            if (now - last > 1.0) {
                last = now;
                for (int l = 0; l < 2; ++l) {
                    if (!counts[l]) {
                        continue;
                    }
                    std::printf("lane %d: %llu cbs, queued %.2f/%.2f ms, gpu %.2f/%.2f ms, callback %.2f/%.2f ms (mean/max)\n",
                                l, (unsigned long long)counts[l], sums[l][0] / counts[l] * 1e3, maxs[l][0] * 1e3,
                                sums[l][1] / counts[l] * 1e3, maxs[l][1] * 1e3, sums[l][2] / counts[l] * 1e3,
                                maxs[l][2] * 1e3);
                    counts[l] = 0;
                    for (int i = 0; i < 3; ++i) {
                        sums[l][i] = maxs[l][i] = 0;
                    }
                }
            }
        }
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
            // A tick is complete when it and every tick before it are (the two lanes'
            // command buffers complete out of order).
            std::scoped_lock lock{state->mutex};
            state->inflight.erase(tick);
            const u64 done_to = state->inflight.empty() ? state->committed : *state->inflight.begin() - 1;
            u64 prev = completed->load(std::memory_order_relaxed);
            while (prev < done_to && !completed->compare_exchange_weak(prev, done_to)) {
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
    if (impl->cmdbuf && impl->open_lane != impl->lane) {
        Flush(); // the signal goes with the selected lane's work
    }
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
