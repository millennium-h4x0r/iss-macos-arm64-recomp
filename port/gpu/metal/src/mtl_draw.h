// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the rasterizer's draw state.

#pragma once

#include <array>
#include <chrono>
#include <memory>

#include "video_core/buffer_cache/buffer.h"
#ifdef __OBJC__
#import <Metal/Metal.h>
#endif
#include "video_core/renderer_vulkan/vk_rasterizer.h"

namespace Vulkan {

struct Rasterizer::DrawState {
    DrawState(const Instance& instance, Scheduler& scheduler, Runtime& runtime);
    ~DrawState();

    /// Once per guest submission: statistics.
    void OnSubmit();
#ifdef __OBJC__
    /// Copies stride*max_count bytes of indirect arguments, zeroing the draws past *count.
    void ClampIndirect(Scheduler& scheduler, id<MTLBuffer> src, u64 src_offset,
                       id<MTLBuffer> count, u64 count_offset, id<MTLBuffer> dst, u64 dst_offset,
                       u32 stride, u32 max_count);
    /// Copies `size` bytes at any alignment (compute).
    void CopyBytes(Scheduler& scheduler, id<MTLBuffer> src, u64 src_offset, id<MTLBuffer> dst,
                   u64 dst_offset, u64 size);
    /// Triangle-list indices for `quads` quads (0 1 2 0 2 3 + 4q).
    id<MTLBuffer> QuadIndices(u32 quads);
    /// Indirect quad lists: indexed triangle-list arguments (20 bytes per draw) and, for indexed
    /// draws, converted indices (max_quads * 6 per draw).
    void ConvertQuadIndirect(Scheduler& scheduler, id<MTLBuffer> args, u64 args_offset, u32 stride,
                             u32 max_count, bool indexed, id<MTLBuffer> indices, u64 indices_offset,
                             bool is16, u32 max_quads, id<MTLBuffer> out_args, u64 out_args_offset,
                             id<MTLBuffer> out_indices, u64 out_indices_offset);
#endif

    struct Impl;
    std::unique_ptr<Impl> impl;
    std::unique_ptr<VideoCore::Buffer> gds; ///< the GPU's global data share (64 KB)
    u64 draws = 0;
    u64 skipped_draws = 0;
    u64 no_pipeline = 0;
    u64 unsupported_primitive = 0;
    u64 dispatches = 0;
    u64 skipped_dispatches = 0;
    u64 passes = 0;
    u64 indirect_draws = 0;
    u64 unaligned_vertex_buffers = 0;
    u64 indirect_dispatches = 0;
    std::array<u64, 32> prim_counts{};
    std::chrono::steady_clock::time_point last_report = std::chrono::steady_clock::now();
};

/// Debugging (TLG_METAL_NAN_SCAN=1): on the frames after a frame dump, counts the NaN and Inf
/// texels each pass and dispatch leaves in its float targets and prints the ones that have any.
namespace NanScan {
bool Enabled();
/// Called by the presenter at the end of a frame: prints the frame's results (once the GPU has
/// finished it) and arms or disarms the next frame.
void EndFrame(Scheduler& scheduler, bool next_active);
} // namespace NanScan

} // namespace Vulkan
