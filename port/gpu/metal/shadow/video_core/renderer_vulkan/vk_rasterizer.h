// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the rasterizer. Liverpool (the GPU command processor) calls it on its own
// thread; draws and dispatches are encoded there directly (no draw recording thread): Metal
// encoding is cheap and the queue runs ahead on its own.

#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <source_location>
#include <string>
#include <thread>
#include <vector>

#include <boost/icl/interval_set.hpp>
#include <fmt/format.h>

#include "common/types.h"
#include "common/unique_function.h"
#include "shader_recompiler/backend/bindings.h"
#include "shader_recompiler/resource.h"
#include "video_core/buffer_cache/buffer_cache.h"
#include "video_core/page_manager.h"
#include "video_core/renderer_vulkan/vk_pipeline_cache.h"
#include "video_core/renderer_vulkan/vk_runtime.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"
#include "video_core/texture_cache/texture_cache.h"

#include <x86intrin.h> // __rdtsc (compat_include on Apple Silicon), used by Liverpool

#include "video_core/amdgpu/regs.h"

namespace AmdGpu {
struct Liverpool;
} // namespace AmdGpu

namespace Core {
class MemoryManager;
}

namespace Vulkan {

class Instance;
class GraphicsPipeline;
class ComputePipeline;

/// The Vulkan renderer's draw recording pipe: here a namespace of its constants, since draws are
/// encoded on the command processor thread.
struct DrawPipe {
    static constexpr u32 ReasonRasterizer = 0x1000;
    static constexpr u32 ReasonCommands = 0x1001;
    static constexpr u32 ReasonSubmissionEnd = 0x1002;
    static constexpr u32 ReasonConstRam = 0x1003;
    static constexpr u32 ReasonCompute = 0x1004;
    static bool OnStageB() {
        return false;
    }
};

/// The Vulkan renderer prepares draws on worker threads; draws are prepared when encoded here.
struct PreparedDraw;
class DrawPreparation {
public:
    struct Submission {};
    std::shared_ptr<Submission> Build(std::span<const u32>) {
        return {};
    }
    void Enqueue(u64, std::shared_ptr<Submission>) {}
    void BeginSubmission(u64, const AmdGpu::Regs&, u64) {}
    void EndSubmission() {}
    const PreparedDraw* NextDraw() {
        return nullptr;
    }
};

class Rasterizer {
public:
    explicit Rasterizer(const Instance& instance, Scheduler& scheduler, Runtime& runtime,
                        AmdGpu::Liverpool* liverpool);
    ~Rasterizer();

    Runtime& GetRuntime() noexcept {
        return runtime;
    }
    VideoCore::BufferCache& GetBufferCache() noexcept {
        return buffer_cache;
    }
    VideoCore::TextureCache& GetTextureCache() noexcept {
        return texture_cache;
    }
    PipelineCache& GetPipelineCache() noexcept {
        return pipeline_cache;
    }
    DrawPreparation& GetDrawPreparation() noexcept {
        return draw_prep;
    }

    // Draws and dispatches (encoded on this thread).
    void Draw(bool is_indexed, u32 index_offset = 0, const PreparedDraw* prepared = nullptr);
    void DrawIndirect(bool is_indexed, VAddr arg_address, u32 offset, u32 size, u32 max_count,
                      VAddr count_address, u16 vertex_sgpr_offset, u16 instance_sgpr_offset);
    void DispatchDirect();
    void DispatchIndirect(VAddr address, u32 offset, u32 size);
    /// tlg: 0 graphics, 1 compute (Scheduler::SelectLane, TLG_METAL_ASYNC_COMPUTE).
    void SelectLane(int lane) noexcept {
        scheduler.SelectLane(lane);
        lane_ = lane;
    }
    /// tlg: guest memory written by GPU work recorded on a lane (dispatches binding a written
    /// buffer, copies and fills into guest memory) since the last call for that lane.
    bool TakeGuestWrites(int lane) noexcept {
        return std::exchange(guest_writes[lane], false);
    }
    void NoteGuestWrite() noexcept {
        guest_writes[lane_] = true;
    }
    int lane_ = 0;
    /// tlg: the guest queue of the next dispatch had a barrier packet since its last dispatch
    /// (TLG_METAL_CONCURRENT_DISPATCH; true unless the command processor says otherwise).
    bool dispatch_barrier = true;
    bool guest_writes[2] = {false, false};
    u64 last_cs_hash[2] = {0, 0}; ///< tlg: the last compute shader recorded on each lane

    void ScopeMarker(fmt::string_view, fmt::format_args, auto&& func) {
        func();
    }
    void ScopeMarkerBegin(const std::string_view&, bool = false) {}
    void ScopeMarkerEnd(bool = false) {}
    void ScopedMarkerInsert(const std::string_view&, bool = false) {}
    void ScopedMarkerInsertColor(const std::string_view&, const u32, bool = false) {}

    void FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds);
    void CopyBuffer(VAddr dst, VAddr src, u32 num_bytes, bool dst_gds, bool src_gds);
    void OcclusionDump(VAddr address, u32 num_pairs);
    u32 ReadDataFromGds(u32 gds_offset);
    bool InvalidateMemory(VAddr addr, u64 size, bool assume_locks = false);

    // Ordering with the guest: everything runs in order on this thread.
    void WaitHostCopies(std::source_location = std::source_location::current()) {}
    /// The end of a guest submission commits the command buffer (the GPU starts on it).
    void DrainDrawPipe(u32 reason = DrawPipe::ReasonRasterizer, u32 = __builtin_LINE(),
                       const char* = __builtin_FILE());
    using OrderedTask = void (*)(Rasterizer& rasterizer, const u8* data);
    /// Runs `task` now. True: the caller notes the label writes it defers to the GPU's
    /// completion (Liverpool::pending_fences), so a WAIT_REG_MEM on such a label (GCN's
    /// EOS + wait shader barrier, ~10 per frame) passes without draining the GPU: the Metal
    /// queue runs the work after it in order anyway.
    bool RunInOrder(OrderedTask task, const void* data, u32 size, bool = false) {
        (void)size;
        task(*this, static_cast<const u8*>(data));
        return true;
    }
    bool RunCommandInOrder(Common::UniqueFunction<void>&& command) {
        command();
        return true;
    }
    /// Positions of pending label writes: command buffer ticks (written once the GPU has
    /// finished the command buffer).
    u64 DrawPipeHead() const {
        return scheduler.CurrentTick();
    }
    bool DrawPipeReached(u64 position) const {
        return scheduler.IsFree(position);
    }
    bool DrawPipeIdle() const {
        return true;
    }
    void AddComputeStep(u32, u64) {}
    int DrawPipeCpuClock() const {
        return -1;
    }
    u32 DrawPipeCpuThreadId() const {
        return 0;
    }
    void RetireSubmission() {}
    void NotePendingGpuWrite(VAddr, u64) {}
    /// Runs `write` (a guest label write) when the GPU has finished the work recorded so far.
    bool DeferUnifiedFence(Common::UniqueFunction<void>&& write);
    /// A command processor memory write (WRITE_DATA) issued while a GPU-side copy into guest
    /// memory (DMA_DATA) is still pending: run on the GPU's completion, after the copy, as the
    /// console's command processor orders them. False when nothing is pending (write at once).
    bool DeferWriteAfterCopy(Common::UniqueFunction<void>&& write);
    /// tlg: runs `write` (a guest label written "when recorded") once the encoder thread has
    /// encoded the work recorded before it, and after the labels queued before it (on the
    /// completion thread when they are still pending; never waiting). Unordered (written here,
    /// TLG_METAL_LABEL_NOW_MODE=record) the game stalls while loading.
    void RunAtEncode(Common::UniqueFunction<void>&& write);
    /// tlg: a WRITE_DATA to guest memory as GPU work, in order with the work recorded before and
    /// after it (as the console's command processor runs it). False: not GPU memory.
    bool WriteDataGpu(VAddr address, const u32* data, u32 bytes);
    bool pending_guest_copy = false;
    void SyncUnifiedRead(VAddr address, u64 size);
    void WaitDeferredSignals() {
        scheduler.WaitSignals();
    }
    void SignalAfterHostCopies(std::function<void()> signal) {
        signal();
    }
    void EagerCopyAtFence() {}

    bool IsGpuSideThread() const;
    bool IsGpuSideThreadId(u32 tid) const;
    void RunForeign(std::function<void()> work) {
        work();
    }

    bool OnWriteFault(VAddr addr, bool assume_locks, bool nowait = false);
    bool ReadMemory(VAddr addr, u64 size, bool assume_locks = false, bool lagged = false);
    void ProcessDownloadImages();
    bool IsMapped(VAddr addr, u64 size);
    void MapMemory(VAddr addr, u64 size);
    void RegisterMemory(VAddr addr, u64 size);
    void UnmapMemory(VAddr addr, u64 size);

    u64 Flush();
    void Finish();
    void OnSubmit();

    template <typename Func>
    void ForEachMappedRangeInRange(VAddr addr, u64 size, Func&& func) {
        const auto range = decltype(mapped_ranges)::interval_type::right_open(addr, addr + size);
        std::shared_lock lock{mapped_ranges_mutex};
        for (const auto& mapped_range : (mapped_ranges & range)) {
            func(mapped_range);
        }
    }

    std::thread::id GetGpuCommandProcessorThread();
    u32 GetGpuCommandProcessorThreadId();

    /// The renderer's draw path (mtl_draw.mm).
    struct DrawState;

    /// Debugging (frame dumps): the color targets of the frame's passes, in order.
    struct FrameTarget {
        void* texture; ///< id<MTLTexture>, retained
        std::string label;
    };
    void CollectFrameTargets(bool on) {
        collect_targets = on;
    }
    std::vector<FrameTarget> TakeFrameTargets() {
        return std::exchange(frame_targets, {});
    }

private:
    struct IndirectArgs {
        VAddr args;
        VAddr count;
        u32 stride;
        u32 max_count;
        u16 vertex_sgpr_offset;
        u16 instance_sgpr_offset;
    };
    void DrawImpl(bool is_indexed, u32 index_offset, const IndirectArgs* indirect);
    void DispatchImpl(VAddr indirect_args);
    bool BindStage(const MetalStage& stage, Shader::Backend::Bindings& binding,
                   Shader::PushData& push_data, struct StageBindings& out);
    /// Clears the binding flags of the images the last draw used.
    void ResetBindings();

    const Instance& instance;
    Scheduler& scheduler;
    Runtime& runtime;
    VideoCore::PageManager page_manager;
    VideoCore::BufferCache buffer_cache;
    VideoCore::TextureCache texture_cache;
    AmdGpu::Liverpool* liverpool;
    Core::MemoryManager* memory;
    PipelineCache pipeline_cache;
    DrawPreparation draw_prep;
    boost::icl::interval_set<VAddr> mapped_ranges;
    std::shared_mutex mapped_ranges_mutex;
    std::atomic<u64> draws{0};
    std::atomic<u64> dispatches{0};
    std::unique_ptr<DrawState> draw_state;
    std::vector<VideoCore::ImageId> bound_images;
    bool collect_targets = false;
    struct PendingSnap {
        void* src;  ///< id<MTLTexture>, retained
        void* snap; ///< id<MTLTexture>, retained
        u32 cb;
        u64 draw;
    };
    std::vector<PendingSnap> snapshots_pending;
    std::vector<FrameTarget> frame_targets;
};

} // namespace Vulkan
