// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: command buffers, encoders, ticks.
//
// Ordering: textures and the renderer's own buffers are hazard-tracked by Metal, which orders
// encoders that touch them as needed. Guest memory (one untracked MTLBuffer, mtl_buffer_cache)
// is ordered here: an encoder that wrote it updates a fence that the next encoder waits for
// (NoteUntrackedWrite).

#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mach/mach_time.h>
#include <pthread.h>
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
std::atomic<u32> g_gpu_errors{0};

// ---- TLG_METAL_ENC_TIMES=1: per-encoder GPU timestamps (diagnosis of long command buffers) ----
constexpr NSUInteger EncSamples = 4096; ///< per command buffer (2 per encoder)

bool EncTimesEnabled() {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_ENC_TIMES");
        return v && v[0] == '1';
    }();
    return on;
}

/// Command buffers longer than this report their encoders (TLG_METAL_ENC_TIMES_MS, default 300).
double EncTimesThreshold() {
    static const double s = [] {
        const char* v = std::getenv("TLG_METAL_ENC_TIMES_MS");
        return (v ? std::atof(v) : 300.0) / 1e3;
    }();
    return s;
}

std::mutex g_sb_mutex;
std::vector<id<MTLCounterSampleBuffer>> g_sb_pool;
id<MTLCounterSet> g_timestamp_set = nil;
bool g_sb_failed = false;
MTLTimestamp g_cal_cpu = 0, g_cal_gpu = 0; ///< a CPU/GPU timestamp pair from the start

id<MTLCounterSampleBuffer> TakeSampleBuffer(id<MTLDevice> device) {
    std::scoped_lock lock{g_sb_mutex};
    if (!g_sb_pool.empty()) {
        id<MTLCounterSampleBuffer> sb = g_sb_pool.back();
        g_sb_pool.pop_back();
        return sb;
    }
    if (g_sb_failed) {
        return nil;
    }
    if (!g_timestamp_set) {
        if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
            std::printf("GPU (Metal): encoder times: no stage-boundary counter sampling on this GPU\n");
            g_sb_failed = true;
            return nil;
        }
        for (id<MTLCounterSet> set in device.counterSets) {
            if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) {
                g_timestamp_set = set;
            }
        }
        if (!g_timestamp_set) {
            std::printf("GPU (Metal): encoder times: no timestamp counter set\n");
            g_sb_failed = true;
            return nil;
        }
        [device sampleTimestamps:&g_cal_cpu gpuTimestamp:&g_cal_gpu];
        std::printf("GPU (Metal): encoder times on (command buffers over %.0f ms report their encoders)\n",
                    EncTimesThreshold() * 1e3);
    }
    MTLCounterSampleBufferDescriptor* d = [MTLCounterSampleBufferDescriptor new];
    d.counterSet = g_timestamp_set;
    d.storageMode = MTLStorageModeShared;
    d.sampleCount = EncSamples;
    NSError* err = nil;
    id<MTLCounterSampleBuffer> sb = [device newCounterSampleBufferWithDescriptor:d error:&err];
    if (!sb) {
        std::printf("GPU (Metal): encoder times: no sample buffer: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
        g_sb_failed = true;
    }
    return sb;
}

void GiveSampleBuffer(id<MTLCounterSampleBuffer> sb) {
    if (sb) {
        std::scoped_lock lock{g_sb_mutex};
        g_sb_pool.push_back(sb);
    }
}

/// The encoders of a long command buffer: offsets from its GPU start, durations, and the gaps
/// between encoders (the GPU idle or blocked inside the command buffer).
void ReportEncoders(id<MTLCommandBuffer> done, const Scheduler::Impl::EncTimes& et, u64 tick) {
    const NSUInteger n = et.encs.size();
    if (!n) {
        return;
    }
    NSData* data = [et.sb resolveCounterRange:NSMakeRange(0, n * 2)];
    if (!data || data.length < n * 2 * sizeof(MTLCounterResultTimestamp)) {
        std::fprintf(stderr, "GPU:   encoder times: could not resolve the samples\n");
        return;
    }
    const auto* ts = static_cast<const MTLCounterResultTimestamp*>(data.bytes);
    // GPU ticks to host seconds (CACurrentMediaTime, as GPUStartTime).
    MTLTimestamp cpu = 0, gpu = 0;
    [done.device sampleTimestamps:&cpu gpuTimestamp:&gpu];
    static std::mutex m;
    std::scoped_lock lock{m};
    // GPU ticks per host second, from the calibration pair taken with the first sample buffer
    // (Apple GPUs count nanoseconds; that is the fallback).
    double gpu_ns_per_tick = 1.0;
    if (g_cal_gpu && gpu > g_cal_gpu + 1000000) {
        const double host_ns = double(cpu - g_cal_cpu); // sampleTimestamps: CPU in nanoseconds
        gpu_ns_per_tick = host_ns / double(gpu - g_cal_gpu);
    }
    const double now_host = CACurrentMediaTime();
    auto host = [&](u64 g) { return now_host + (double(g) - double(gpu)) * gpu_ns_per_tick / 1e9; };
    const double t0 = done.GPUStartTime;
    std::fprintf(stderr, "GPU:   cb %llu: %zu encoders (GPU %.1f ms; start..end in ms from its GPU start):\n",
                 (unsigned long long)tick, size_t(n), (done.GPUEndTime - t0) * 1e3);
    double prev_end = t0;
    int shown = 0;
    int counted[3] = {0, 0, 0};
    double kind_ms[3] = {0, 0, 0};
    double gaps = 0;
    for (NSUInteger i = 0; i < n; ++i) {
        const u64 a = ts[i * 2].timestamp, b = ts[i * 2 + 1].timestamp;
        const int k = et.encs[i].kind == 'R' ? 0 : et.encs[i].kind == 'C' ? 1 : 2;
        if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || !a || !b || b < a) {
            if (shown < 40) {
                ++shown;
                std::fprintf(stderr, "GPU:     #%zu %c %s: no sample\n", size_t(i), et.encs[i].kind,
                             et.encs[i].what.c_str());
            }
            continue;
        }
        const double s = host(a), e = host(b);
        const double gap = s - prev_end, dur = e - s;
        ++counted[k];
        kind_ms[k] += dur * 1e3;
        if (gap > 0) {
            gaps += gap;
        }
        if ((dur > 0.010 || gap > 0.010) && shown < 40) {
            ++shown;
            std::fprintf(stderr, "GPU:     #%zu %c %8.1f..%8.1f (%7.1f ms, gap before %7.1f ms) %s\n", size_t(i),
                         et.encs[i].kind, (s - t0) * 1e3, (e - t0) * 1e3, dur * 1e3, gap * 1e3,
                         et.encs[i].what.c_str());
        }
        prev_end = std::max(prev_end, e);
    }
    std::fprintf(stderr, "GPU:   render %d/%.1f ms, compute %d/%.1f ms, blit %d/%.1f ms, gaps %.1f ms, "
                 "after the last %.1f ms\n",
                 counted[0], kind_ms[0], counted[1], kind_ms[1], counted[2], kind_ms[2], gaps * 1e3,
                 (done.GPUEndTime - prev_end) * 1e3);
}
} // namespace

NSUInteger Scheduler::Impl::SampleIndex(char kind, std::string what) {
    enc_sampled = false;
    if (!enc_times || !enc_times->sb || (enc_times->encs.size() + 1) * 2 > EncSamples) {
        return NSNotFound;
    }
    enc_times->encs.push_back({kind, std::move(what)});
    enc_sampled = true;
    return (enc_times->encs.size() - 1) * 2;
}

void Scheduler::Impl::SampleRender(MTLRenderPassDescriptor* rp) {
    if (!EncTimesEnabled() || !rp) {
        return;
    }
    CommandBuffer();
    id<MTLTexture> t = rp.colorAttachments[0].texture ?: rp.depthAttachment.texture;
    char what[160] = "";
    if (t) {
        std::snprintf(what, sizeof(what), "%lux%lu fmt %lu %s", (unsigned long)t.width, (unsigned long)t.height,
                      (unsigned long)t.pixelFormat, t.label.UTF8String ?: "");
    }
    MTLRenderPassSampleBufferAttachmentDescriptor* a = rp.sampleBufferAttachments[0];
    const NSUInteger idx = SampleIndex('R', what);
    if (idx == NSNotFound) {
        a.sampleBuffer = nil;
        return;
    }
    a.sampleBuffer = enc_times->sb;
    a.startOfVertexSampleIndex = idx;
    a.endOfVertexSampleIndex = MTLCounterDontSample;
    a.startOfFragmentSampleIndex = MTLCounterDontSample;
    a.endOfFragmentSampleIndex = idx + 1;
}

namespace MetalScheduler {

void NoteUntrackedWrite(Scheduler& scheduler) {
    Scheduler::Impl* impl = scheduler.impl_();
    impl->Record([impl] { impl->encoder_wrote_untracked = true; });
}

bool ConcurrentDispatch() {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_CONCURRENT_DISPATCH");
        return !v || v[0] != '0';
    }();
    return on;
}

bool EncoderThreadEnabled() {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_ENCODER_THREAD");
        return !(v && v[0] == '0');
    }();
    return on;
}

namespace {
void Barrier(id<MTLComputeCommandEncoder> enc) {
    [enc memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures];
}
} // namespace

void BeforeGuestDispatch(Scheduler::Impl& impl, id<MTLComputeCommandEncoder> enc, bool guest_barrier) {
    if (ConcurrentDispatch() && impl.encoder_has_dispatch && (guest_barrier || impl.internal_dispatch)) {
        Barrier(enc);
    }
    impl.encoder_has_dispatch = true;
    impl.internal_dispatch = false;
}

void BeforeInternalDispatch(Scheduler::Impl& impl, id<MTLComputeCommandEncoder> enc) {
    if (ConcurrentDispatch() && impl.encoder_has_dispatch) {
        Barrier(enc);
    }
    impl.encoder_has_dispatch = true;
    impl.internal_dispatch = true;
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
    if (scheduler.OpenKind() != Scheduler::Kind::Render) {
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
    impl->owner = this;
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
    if (std::strcmp(name, "draw") == 0 && MetalScheduler::EncoderThreadEnabled()) {
        impl->ring = std::make_unique<MetalScheduler::EncodeRing>(4u << 20);
        MetalScheduler::EncodeRing* ring = impl->ring.get();
        impl->thread = std::thread([ring] {
            pthread_setname_np("GpuEncoder");
            // TLG_METAL_ENCODER_QOS=ui: user-interactive; default: the QoS it inherits.
            if (const char* qos = std::getenv("TLG_METAL_ENCODER_QOS"); qos && std::strcmp(qos, "ui") == 0) {
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
            }
            ring->Consume([](MetalScheduler::EncodeRing& r, void (*body)(MetalScheduler::EncodeRing&)) {
                @autoreleasepool {
                    body(r);
                }
            });
        });
        std::printf("GPU (Metal): encoder thread on\n");
        // Watchdog (TLG_METAL_WATCHDOG=0: off): reports work published to the encoder thread
        // and not run, or command buffers committed and not completed, for 2 s or more.
        if (const char* v = std::getenv("TLG_METAL_WATCHDOG"); !(v && v[0] == '0')) {
            Impl* const i = impl.get();
            std::atomic<u64>* const completed = &completed_tick;
            impl->watchdog = std::thread([i, completed] {
                pthread_setname_np("GpuWatchdog");
                u64 last_consumed = 0, last_completed = 0;
                auto since_ring = std::chrono::steady_clock::now(), since_gpu = since_ring;
                bool told_ring = false, told_gpu = false;
                while (!i->watchdog_stop.load(std::memory_order_relaxed)) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(250));
                    const auto now = std::chrono::steady_clock::now();
                    const u64 published = i->ring->Published(), consumed = i->ring->Consumed();
                    if (consumed != last_consumed || consumed == published) {
                        last_consumed = consumed;
                        since_ring = now;
                        told_ring = false;
                    } else if (!told_ring && now - since_ring > std::chrono::seconds(2)) {
                        told_ring = true;
                        std::fprintf(stderr, "GPU (Metal) watchdog: encoder thread has not run published work for 2 s "
                                     "(published %llu, consumed %llu, sleeping %d)\n",
                                     (unsigned long long)published, (unsigned long long)consumed,
                                     int(i->ring->ConsumerSleeping()));
                    }
                    u64 committed;
                    {
                        std::scoped_lock lock{i->mutex};
                        committed = i->committed;
                    }
                    const u64 done = completed->load(std::memory_order_relaxed);
                    if (done != last_completed || done >= committed) {
                        last_completed = done;
                        since_gpu = now;
                        told_gpu = false;
                    } else if (!told_gpu && now - since_gpu > std::chrono::seconds(2)) {
                        told_gpu = true;
                        std::fprintf(stderr, "GPU (Metal) watchdog: no command buffer completed for 2 s "
                                     "(committed %llu, completed %llu)\n",
                                     (unsigned long long)committed, (unsigned long long)done);
                    }
                }
            });
        }
    }
}

bool Scheduler::AsyncCompute() noexcept {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_ASYNC_COMPUTE");
        return v && (v[0] == '1' || v[0] == 'p');
    }();
    return on;
}

bool Scheduler::ParticleLanes() noexcept {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_ASYNC_COMPUTE");
        return v && v[0] == 'p';
    }();
    return on;
}

void Scheduler::SelectLane(int lane) noexcept {
    if (!impl->queues[1] || rec_lane == lane) {
        return;
    }
    rec_lane = lane;
    // The lane is encoding-side state (the encoder thread's when it runs), recorded in order
    // with the work; the tick is the open command buffer's (Commit closes it).
    Impl* const i = impl.get();
    const u64 tick = CurrentTick();
    i->Record([i, lane, tick] {
        i->lane = lane;
        i->lane_tick = tick;
    });
}

Scheduler::~Scheduler() {
    Finish();
    if (impl->ring) {
        impl->ring->Stop();
        impl->thread.join();
        impl->watchdog_stop = true;
        if (impl->watchdog.joinable()) {
            impl->watchdog.join();
        }
    }
}

// ---- Encoding side ----

id<MTLCommandBuffer> Scheduler::Impl::CommandBuffer() {
    if (!cmdbuf || open_lane != lane) {
        if (cmdbuf) {
            // Async compute: the other lane's work goes to its queue now (as part of the same
            // tick: the tick's Commit adds this lane's command buffer).
            CommitBuffer(cmdbuf, lane_tick, {}, &owner->completed_tick, owner->name, false);
        }
        MTLCommandBufferDescriptor* desc = [MTLCommandBufferDescriptor new];
        desc.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
        open_lane = lane;
        cmdbuf = [queues[open_lane] commandBufferWithDescriptor:desc];
        if (EncTimesEnabled()) {
            enc_times = std::make_shared<EncTimes>();
            enc_times->sb = TakeSampleBuffer(queues[open_lane].device);
        }
        if (queues[1]) {
            static const bool serial = [] {
                const char* v = std::getenv("TLG_METAL_ASYNC_COMPUTE_SERIAL");
                return v && v[0] == '1';
            }();
            if (open_lane == 0 && compute_signaled > graphics_waited) {
                // Graphics after compute: everything the compute lane committed before it.
                [cmdbuf encodeWaitForEvent:compute_event value:compute_signaled];
                graphics_waited = compute_signaled;
            } else if (open_lane == 1 && serial && graphics_signaled) {
                [cmdbuf encodeWaitForEvent:graphics_event value:graphics_signaled];
            }
        }
    }
    return cmdbuf;
}

void Scheduler::Impl::EndEncoding() {
    if (!encoder) {
        kind = Kind::None;
        return;
    }
    if (encoder_wrote_untracked) {
        if (kind == Kind::Render) {
            [(id<MTLRenderCommandEncoder>)encoder updateFence:Fence() afterStages:MTLRenderStageFragment];
        } else if (kind == Kind::Compute) {
            [(id<MTLComputeCommandEncoder>)encoder updateFence:Fence()];
        } else {
            [(id<MTLBlitCommandEncoder>)encoder updateFence:Fence()];
        }
        FencePending() = true;
        encoder_wrote_untracked = false;
    }
    if (enc_sampled && enc_times && !enc_times->encs.empty()) {
        enc_sampled = false;
        if (NSString* label = encoder.label) {
            auto& what = enc_times->encs.back().what;
            what = what.empty() ? std::string(label.UTF8String) : what + " " + label.UTF8String;
        }
    }
    [encoder endEncoding];
    encoder = nil;
    kind = Kind::None;
}

id<MTLComputeCommandEncoder> Scheduler::Impl::ComputeEncoder() {
    if (kind != Kind::Compute || !encoder || open_lane != lane) {
        EndEncoding();
        id<MTLCommandBuffer> cb = CommandBuffer();
        const MTLDispatchType type =
            MetalScheduler::ConcurrentDispatch() ? MTLDispatchTypeConcurrent : MTLDispatchTypeSerial;
        id<MTLComputeCommandEncoder> enc;
        if (const NSUInteger idx = EncTimesEnabled() ? SampleIndex('C') : NSNotFound; idx != NSNotFound) {
            MTLComputePassDescriptor* d = [MTLComputePassDescriptor computePassDescriptor];
            d.dispatchType = type;
            d.sampleBufferAttachments[0].sampleBuffer = enc_times->sb;
            d.sampleBufferAttachments[0].startOfEncoderSampleIndex = idx;
            d.sampleBufferAttachments[0].endOfEncoderSampleIndex = idx + 1;
            enc = [cb computeCommandEncoderWithDescriptor:d];
        } else {
            enc = [cb computeCommandEncoderWithDispatchType:type];
        }
        encoder_has_dispatch = false;
        if (FencePending()) {
            [enc waitForFence:Fence()];
        }
        encoder = enc;
        kind = Kind::Compute;
    }
    return (id<MTLComputeCommandEncoder>)encoder;
}

id<MTLBlitCommandEncoder> Scheduler::Impl::BlitEncoder() {
    if (kind != Kind::Blit || !encoder || open_lane != lane) {
        EndEncoding();
        id<MTLCommandBuffer> cb = CommandBuffer();
        id<MTLBlitCommandEncoder> enc;
        if (const NSUInteger idx = EncTimesEnabled() ? SampleIndex('B') : NSNotFound; idx != NSNotFound) {
            MTLBlitPassDescriptor* d = [MTLBlitPassDescriptor blitPassDescriptor];
            d.sampleBufferAttachments[0].sampleBuffer = enc_times->sb;
            d.sampleBufferAttachments[0].startOfEncoderSampleIndex = idx;
            d.sampleBufferAttachments[0].endOfEncoderSampleIndex = idx + 1;
            enc = [cb blitCommandEncoderWithDescriptor:d];
        } else {
            enc = [cb blitCommandEncoder];
        }
        if (FencePending()) {
            [enc waitForFence:Fence()];
        }
        encoder = enc;
        kind = Kind::Blit;
    }
    return (id<MTLBlitCommandEncoder>)encoder;
}

void Scheduler::Impl::SetRenderEncoder(id<MTLRenderCommandEncoder> enc) {
    EndEncoding();
    if (!enc) {
        return; // a failed pass: its draws go to nil
    }
    if (FencePending()) {
        [enc waitForFence:Fence() beforeStages:MTLRenderStageVertex];
    }
    encoder = enc;
    kind = Kind::Render;
}

void Scheduler::Impl::Commit(u64 tick, std::vector<std::function<void()>>&& signals_in,
                             std::atomic<u64>* completed, const char* queue_name) {
    EndEncoding();
    // Async compute: an open command buffer of the other lane goes out first (without the
    // signals: they belong with the selected lane's work, on an empty command buffer of that
    // lane when nothing is open, which completes after the lane's earlier ones).
    if (cmdbuf && open_lane != lane) {
        CommitBuffer(cmdbuf, tick, {}, completed, queue_name, false);
    }
    if (!cmdbuf) {
        open_lane = lane;
    }
    CommitBuffer(cmdbuf ? cmdbuf : CommandBuffer(), tick, std::move(signals_in), completed, queue_name, true);
}

void Scheduler::Impl::CommitBuffer(id<MTLCommandBuffer> cb, u64 tick, std::vector<std::function<void()>>&& signals_in,
                                   std::atomic<u64>* completed, const char* queue_name, bool final) {
    Impl* const state = this;
    std::vector<std::function<void()>> signals = std::move(signals_in);
    if (queues[1]) {
        if (open_lane == 1) {
            [cb encodeSignalEvent:compute_event value:++compute_signaled];
        } else {
            [cb encodeSignalEvent:graphics_event value:++graphics_signaled];
        }
    }
    {
        // `committed` advances with a tick's closing command buffer only: an earlier buffer of
        // the tick (the other lane's, with async compute) completing while the tick is still
        // open must not mark the tick complete (done_to stays at tick - 1).
        std::scoped_lock lock{mutex};
        inflight.insert(tick);
        if (final) {
            committed = tick;
        }
    }
    // TLG_METAL_LANE_STATS=1: per lane and second, the command buffers' wait before the GPU
    // started them, their GPU time, and the delay of their completion handler.
    static const bool lane_stats = std::getenv("TLG_METAL_LANE_STATS") != nullptr;
    const int lane = open_lane;
    const double commit_time = lane_stats ? CACurrentMediaTime() : 0.0;
    std::shared_ptr<EncTimes> et = std::move(enc_times);
    enc_sampled = false;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (et) {
            if (et->sb && done.status != MTLCommandBufferStatusError &&
                done.GPUEndTime - done.GPUStartTime > EncTimesThreshold()) {
                std::fprintf(stderr, "GPU: Metal command buffer %llu (%s) ran %.0f ms on the GPU (encoder times)\n",
                             (unsigned long long)tick, queue_name, (done.GPUEndTime - done.GPUStartTime) * 1e3);
                ReportEncoders(done, *et, tick);
            }
            GiveSampleBuffer(et->sb);
        }
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
                std::fprintf(stderr, "GPU: Metal command buffer %llu (%s) failed after %.0f ms on the GPU: %s\n",
                             (unsigned long long)tick, queue_name,
                             (done.GPUEndTime - done.GPUStartTime) * 1e3,
                             done.error.localizedDescription.UTF8String);
                // The encoders that did not complete (named with TLG_METAL_LABEL=1).
                NSArray* infos = done.error.userInfo[MTLCommandBufferEncoderInfoErrorKey];
                int shown = 0, completed = 0;
                for (id<MTLCommandBufferEncoderInfo> info in infos) {
                    if (info.errorState == MTLCommandEncoderErrorStateCompleted) {
                        ++completed;
                        continue;
                    }
                    if (shown++ < 12) {
                        const char* state = info.errorState == MTLCommandEncoderErrorStateFaulted   ? "FAULTED"
                                            : info.errorState == MTLCommandEncoderErrorStateAffected ? "affected"
                                            : info.errorState == MTLCommandEncoderErrorStatePending  ? "pending"
                                                                                                     : "unknown";
                        std::fprintf(stderr, "GPU:   encoder %s: %s\n", info.label.UTF8String ?: "(no label)", state);
                    }
                }
                std::fprintf(stderr, "GPU:   %d encoders completed, %d not\n", completed, shown);
            }
        } else if (done.GPUEndTime - done.GPUStartTime > 0.5) {
            std::fprintf(stderr, "GPU: Metal command buffer %llu (%s) ran %.0f ms on the GPU\n",
                         (unsigned long long)tick, queue_name, (done.GPUEndTime - done.GPUStartTime) * 1e3);
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
            if (auto it = state->inflight.find(tick); it != state->inflight.end()) {
                state->inflight.erase(it);
            }
            const u64 done_to = state->inflight.empty() ? state->committed : *state->inflight.begin() - 1;
            u64 prev = completed->load(std::memory_order_relaxed);
            while (prev < done_to && !completed->compare_exchange_weak(prev, done_to)) {
            }
        }
        state->cv.notify_all();
        if (!signals.empty()) {
            std::vector<std::function<void()>> after;
            {
                std::scoped_lock lock{state->signal_mutex};
                state->signals_done += signals.size();
                while (!state->after_signals.empty() &&
                       state->after_signals.front().first <= state->signals_done) {
                    after.emplace_back(std::move(state->after_signals.front().second));
                    state->after_signals.pop_front();
                }
            }
            state->signal_cv.notify_all();
            for (auto& f : after) {
                f();
            }
        }
    }];
    // Diagnosis: TLG_METAL_COMMIT_DELAY_US: each commit that late (the GPU fed later).
    if (static const long delay = [] {
            const char* v = std::getenv("TLG_METAL_COMMIT_DELAY_US");
            return v ? std::atol(v) : 0L;
        }();
        delay > 0) {
        std::this_thread::sleep_for(std::chrono::microseconds(delay));
    }
    [cb commit];
    cmdbuf = nil;
    // tlg: fence_pending stays set: command buffers of one queue start in order but may overlap
    // on the GPU, and guest memory is untracked, so the next command buffer's encoders still
    // wait for the last write (a fence works across the queue's command buffers). Resetting it
    // here let the mid-frame commits (TLG_METAL_COMMIT_DRAWS) read guest memory a compute job
    // in the previous command buffer was still writing: blocks of the opening cutscene's depth
    // of field in the wrong places for a frame.
}

// ---- Recording side ----

void Scheduler::EndEncoding() {
    if (open_kind == Kind::None) {
        return;
    }
    open_kind = Kind::None;
    render_pass_key = 0;
    Impl* const i = impl.get();
    i->Record([i] { i->EndEncoding(); });
}

void Scheduler::EndRendering() {
    if (open_kind == Kind::Render) {
        EndEncoding();
    }
}

void Scheduler::Flush() {
    if (MetalScheduler::PassStatsEnabled()) {
        MetalScheduler::NoteRenderBreak(*this, "flush");
    }
    EndEncoding();
    const u64 tick = current_tick.load(std::memory_order_relaxed);
    std::vector<std::function<void()>> signals;
    {
        std::scoped_lock lock{impl->signal_mutex};
        signals.swap(impl->signals);
    }
    Impl* const i = impl.get();
    i->Record([i, tick, signals = std::move(signals), completed = &completed_tick,
               queue_name = name]() mutable { i->Commit(tick, std::move(signals), completed, queue_name); });
    // TLG_METAL_INFLIGHT_STATS=1: command buffers committed and not completed at each commit
    // (how far recording runs ahead of the GPU), every 5 s.
    if (static const bool inflight_stats = std::getenv("TLG_METAL_INFLIGHT_STATS") != nullptr; inflight_stats &&
        std::strcmp(name, "draw") == 0) {
        static u64 n = 0, sum = 0, max = 0;
        static auto last = std::chrono::steady_clock::now();
        const u64 ahead = tick - CompletedTick();
        ++n;
        sum += ahead;
        max = std::max(max, ahead);
        if (const auto now = std::chrono::steady_clock::now(); now - last >= std::chrono::seconds(5)) {
            last = now;
            std::printf("GPU (Metal): ticks ahead of the GPU at commit: mean %.1f max %llu (%llu commits)\n",
                        double(sum) / n, (unsigned long long)max, (unsigned long long)n);
            n = sum = max = 0;
        }
    }
    // Diagnosis: TLG_METAL_MAX_AHEAD=<n>: recording waits until at most n command buffers are
    // committed and not completed (the GPU's backlog bounds how stale the memory it reads is).
    if (static const u64 max_ahead = [] {
            const char* v = std::getenv("TLG_METAL_MAX_AHEAD");
            return v ? std::strtoull(v, nullptr, 10) : 0ull;
        }();
        max_ahead && std::strcmp(name, "draw") == 0 && tick > max_ahead) {
        if (i->ring) {
            i->ring->Publish();
        }
        if (!IsFree(tick - max_ahead)) {
            std::unique_lock lock{i->mutex};
            i->cv.wait(lock, [&] { return IsFree(tick - max_ahead); });
        }
    }
    if (i->ring) {
        i->ring->Publish(); // the commit goes out now (recording publishes in batches)
        // TLG_METAL_ENCODER_STATS=1: closures run, kernel sleeps of the encoder thread and
        // waits of the recording thread for ring space, every 5 s.
        static const bool stats = std::getenv("TLG_METAL_ENCODER_STATS") != nullptr;
        static auto last = std::chrono::steady_clock::now();
        if (const auto now = std::chrono::steady_clock::now(); stats && now - last >= std::chrono::seconds(5)) {
            last = now;
            std::printf("GPU (Metal): encoder thread: %llu closures, %llu sleeps, %llu full waits in 5 s\n",
                        (unsigned long long)i->ring->runs.exchange(0),
                        (unsigned long long)i->ring->wakeups.exchange(0),
                        (unsigned long long)i->ring->full_waits.exchange(0));
        }
    }
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
    impl->pending_front.store(impl->pending.front().first, std::memory_order_release);
}

void Scheduler::PopPendingOperations() {
    for (;;) {
        if (const u64 front = impl->pending_front.load(std::memory_order_acquire);
            front == ~u64(0) || !IsFree(front)) {
            return;
        }
        Common::UniqueFunction<void> func;
        {
            std::scoped_lock lock{impl->pending_mutex};
            if (impl->pending.empty() || !IsFree(impl->pending.front().first)) {
                return;
            }
            func = std::move(impl->pending.front().second);
            impl->pending.pop_front();
            impl->pending_front.store(impl->pending.empty() ? ~u64(0) : impl->pending.front().first,
                                      std::memory_order_release);
        }
        func();
    }
}

void Scheduler::SignalOnCompletion(std::function<void()> func) {
    if (!impl->ring && impl->cmdbuf && impl->open_lane != impl->lane) {
        Flush(); // the signal goes with the selected lane's work
    }
    {
        std::scoped_lock lock{impl->signal_mutex};
        impl->signals.emplace_back(std::move(func));
        ++impl->signals_queued;
    }
    Flush();
}

u64 Scheduler::SignalsQueued() {
    std::scoped_lock lock{impl->signal_mutex};
    return impl->signals_queued;
}

u64 Scheduler::SignalsDone() {
    std::scoped_lock lock{impl->signal_mutex};
    return impl->signals_done;
}

void Scheduler::RunAfterSignals(u64 target, std::function<void()> func) {
    {
        std::scoped_lock lock{impl->signal_mutex};
        if (impl->signals_done < target || !impl->after_signals.empty()) {
            impl->after_signals.emplace_back(target, std::move(func));
            return;
        }
    }
    func();
}

void Scheduler::WaitSignalsUpTo(u64 target) {
    std::unique_lock lock{impl->signal_mutex};
    impl->signal_cv.wait(lock, [&] { return impl->signals_done >= target; });
}

void Scheduler::WaitSignals() {
    std::unique_lock lock{impl->signal_mutex};
    const u64 target = impl->signals_queued;
    impl->signal_cv.wait(lock, [&] { return impl->signals_done >= target; });
}

} // namespace Vulkan
