// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the rasterizer's memory hooks, transfers and fences. Draws and dispatches
// are in mtl_draw.mm.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstdio>
#include <cstring>

#include "common/assert.h"
#include "core/memory.h"
#include "mtl_draw.h"
#include "mtl_objc.h"
#include "mtl_scheduler_internal.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/buffer_cache/unified_memory.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_rasterizer.h"

namespace Vulkan {

Rasterizer::Rasterizer(const Instance& instance_, Scheduler& scheduler_, Runtime& runtime_,
                       AmdGpu::Liverpool* liverpool_)
    : instance{instance_}, scheduler{scheduler_}, runtime{runtime_}, page_manager{this},
      buffer_cache{instance, scheduler, runtime, liverpool_},
      texture_cache{instance, scheduler, runtime, liverpool_, buffer_cache, page_manager},
      liverpool{liverpool_}, memory{Core::Memory::Instance()},
      pipeline_cache{instance, scheduler, liverpool_},
      draw_state{std::make_unique<DrawState>(instance, scheduler, runtime)} {
    liverpool->BindRasterizer(this);
    memory->SetRasterizer(this);
}

Rasterizer::~Rasterizer() {
    scheduler.Finish();
}

void Rasterizer::DrainDrawPipe(u32 reason, u32, const char*) {
    if (reason == DrawPipe::ReasonSubmissionEnd) {
        scheduler.Flush();
    }
}

bool Rasterizer::IsGpuSideThread() const {
    return std::this_thread::get_id() == liverpool->GetGpuCommandProcessorThread();
}

bool Rasterizer::IsGpuSideThreadId(u32 tid) const {
    return tid == liverpool->GetGpuCommandProcessorThreadId();
}

std::thread::id Rasterizer::GetGpuCommandProcessorThread() {
    return liverpool->GetGpuCommandProcessorThread();
}

u32 Rasterizer::GetGpuCommandProcessorThreadId() {
    return liverpool->GetGpuCommandProcessorThreadId();
}

void Rasterizer::FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds) {
    ASSERT_MSG(address % 4 == 0 && num_bytes % 4 == 0,
               "FillBuffer address and size must be a multiple of 4 bytes");
    if (is_gds) {
        runtime.FillBuffer(draw_state->gds.get(), address, num_bytes, value);
        return;
    }
    texture_cache.ClearMeta(address);
    texture_cache.InvalidateMemoryFromGPU(address, num_bytes);
    const auto [buffer, offset] = buffer_cache.ObtainBuffer(address, num_bytes, true);
    runtime.FillBuffer(buffer, offset, num_bytes, value);
}

void Rasterizer::CopyBuffer(VAddr dst, VAddr src, u32 num_bytes, bool dst_gds, bool src_gds) {
    if (!dst_gds) {
        texture_cache.InvalidateMemoryFromGPU(dst, num_bytes);
    }
    const auto [src_buffer, src_offset] = [&] -> std::pair<const VideoCore::Buffer*, u64> {
        if (src_gds) {
            return {draw_state->gds.get(), src};
        }
        return buffer_cache.ObtainBuffer(src, num_bytes, false);
    }();
    const auto [dst_buffer, dst_offset] = [&] -> std::pair<const VideoCore::Buffer*, u64> {
        if (dst_gds) {
            return {draw_state->gds.get(), dst};
        }
        return buffer_cache.ObtainBuffer(dst, num_bytes, true);
    }();
    const vk::BufferCopy copy{.srcOffset = src_offset, .dstOffset = dst_offset, .size = num_bytes};
    runtime.CopyBuffer(src_buffer, dst_buffer, std::span{&copy, 1});
}

u32 Rasterizer::ReadDataFromGds(u32 gds_offset) {
    // The GDS lives in shared memory: wait for the GPU work that may write it.
    scheduler.Finish();
    u32 value;
    std::memcpy(&value, draw_state->gds->mapped_data.data() + gds_offset, sizeof(u32));
    return value;
}

void Rasterizer::OcclusionDump(VAddr address, u32 num_pairs) {
    // No occlusion queries yet: every query sees pixels. Each event (the begin and the end of a
    // query write the same slots of their own pair) stores a counter that grows from event to
    // event, so end - begin > 0 (Liverpool's fake counter, TLG_OCCLUSION_MODE=0).
    static constexpr u64 CounterValid = 1ULL << 63;
    static constexpr u64 Step = 0x2FFFFFFULL;
    static std::atomic<u64> pixel_counter{0};
    const u64 v = pixel_counter.fetch_add(Step) | CounterValid;
    num_pairs = std::clamp<u32>(num_pairs, 1, 16);
    u64* results = std::bit_cast<u64*>(address);
    for (u32 i = 0; i < num_pairs; ++i, results += 2) {
        *results = v;
    }
}

bool Rasterizer::InvalidateMemory(VAddr addr, u64 size, bool assume_locks) {
    if (!IsMapped(addr, size)) {
        return false;
    }
    texture_cache.ResolveReadbacks(addr, size, assume_locks, VideoCore::ReadbackSource::CpuWrite);
    texture_cache.InvalidateMemory(addr, size);
    return true;
}

bool Rasterizer::OnWriteFault(VAddr addr, bool assume_locks, bool) {
    return InvalidateMemory(addr, 8, assume_locks);
}

bool Rasterizer::ReadMemory(VAddr addr, u64 size, bool assume_locks, bool) {
    if (!IsMapped(addr, size)) {
        return false;
    }
    texture_cache.ResolveReadbacks(addr, size, assume_locks, VideoCore::ReadbackSource::CpuRead);
    return true;
}

void Rasterizer::ProcessDownloadImages() {
    texture_cache.ProcessDownloadImages();
}

bool Rasterizer::IsMapped(VAddr addr, u64 size) {
    if (size == 0 || static_cast<u64>(addr) > std::numeric_limits<u64>::max() - size) {
        return false;
    }
    const auto range = decltype(mapped_ranges)::interval_type::right_open(addr, addr + size);
    std::shared_lock lock{mapped_ranges_mutex};
    return boost::icl::contains(mapped_ranges, range);
}

void Rasterizer::MapMemory(VAddr addr, u64 size) {
    {
        std::scoped_lock lock{mapped_ranges_mutex};
        mapped_ranges += decltype(mapped_ranges)::interval_type::right_open(addr, addr + size);
    }
    buffer_cache.MapMemory(addr, size);
}

void Rasterizer::RegisterMemory(VAddr addr, u64 size) {
    page_manager.OnGpuMap(addr, size);
}

void Rasterizer::UnmapMemory(VAddr addr, u64 size) {
    texture_cache.UnmapMemory(addr, size);
    buffer_cache.UnmapMemory(addr, size);
    std::scoped_lock lock{mapped_ranges_mutex};
    mapped_ranges -= decltype(mapped_ranges)::interval_type::right_open(addr, addr + size);
}

u64 Rasterizer::Flush() {
    const u64 tick = scheduler.CurrentTick();
    scheduler.Flush();
    return tick;
}

void Rasterizer::Finish() {
    scheduler.Finish();
}

void Rasterizer::OnSubmit() {
    // Shader compiles in the last 5 s (stalls the command processor thread).
    static auto last_report = std::chrono::steady_clock::now();
    if (const auto now = std::chrono::steady_clock::now(); now - last_report >= std::chrono::seconds(5)) {
        last_report = now;
        pipeline_cache.ReportCompilerStats();
    }
    texture_cache.ProcessDownloadImages();
    texture_cache.RunGarbageCollector();
    scheduler.PopPendingOperations();
    draw_state->OnSubmit();
}

bool Rasterizer::DeferUnifiedFence(Common::UniqueFunction<void>&& write) {
    // Guest memory is the GPU's: the label is written once the GPU has finished what was recorded
    // before it (on the command buffer's completion), in order with the other labels.
    auto shared = std::make_shared<Common::UniqueFunction<void>>(std::move(write));
    scheduler.SignalOnCompletion([shared] { (*shared)(); });
    VideoCore::Unified::Add(VideoCore::Unified::FencesDeferred);
    return true;
}

void Rasterizer::SyncUnifiedRead(VAddr address, u64 size) {
    // The command processor reads guest memory the GPU may be writing (WAIT_REG_MEM): wait for
    // the work recorded so far.
    static std::atomic<u64> calls{0}, finishes{0};
    static std::atomic<s64> wait_ns{0};
    static const bool stats = std::getenv("TLG_METAL_SYNC_STATS") != nullptr;
    ++calls;
    if (buffer_cache.IsInPlace(address, size) && !scheduler.IsFree(scheduler.CurrentTick() - 1)) {
        const auto t0 = std::chrono::steady_clock::now();
        scheduler.Finish();
        ++finishes;
        wait_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
    }
    if (stats && calls % 500 == 0) {
        std::printf("GPU (Metal): WAIT_REG_MEM syncs %llu, GPU waits %llu (%.1f ms total)\n",
                    (unsigned long long)calls.load(), (unsigned long long)finishes.load(),
                    wait_ns.load() / 1e6);
    }
}

} // namespace Vulkan
