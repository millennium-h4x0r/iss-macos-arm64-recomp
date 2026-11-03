// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: transfers between buffers and images (blit encoders). Same API as the
// Vulkan renderer's Runtime; layouts and barriers do not exist in Metal (textures are hazard
// tracked), so Transit/FlushBarriers only keep the images' bookkeeping.

#pragma once

#include <optional>
#include <span>

#include "common/types.h"
#include "video_core/buffer_cache/buffer.h"
#include "video_core/renderer_vulkan/vk_staging_buffer_pool.h"
#include "video_core/texture_cache/image.h"
#include "video_core/texture_cache/types.h"

namespace Vulkan {

class Instance;
class Scheduler;
class SceneTargets;

class Runtime {
public:
    explicit Runtime(const Instance& instance, Scheduler& scheduler);
    ~Runtime();

    Scheduler& GetScheduler() {
        return scheduler;
    }
    const Instance& GetInstance() const {
        return instance;
    }
    StagingBufferPool& GetStagingPool() {
        return staging_pool;
    }

    void TickFrame();
    SceneTargets* scene_targets = nullptr;

    void CopyBuffer(const VideoCore::Buffer* src, const VideoCore::Buffer* dst,
                    std::span<const vk::BufferCopy> copies);
    void FillBuffer(const VideoCore::Buffer* dst, u64 offset, u64 size, u32 value);
    void InlineData(VideoCore::Buffer* dst, u64 offset, u32 value);

    bool Transit(VideoCore::Image* image, vk::ImageLayout dst_layout,
                 vk::PipelineStageFlags2 dst_stage, vk::AccessFlags2 dst_access,
                 std::optional<VideoCore::SubresourceRange> subres_range = {});

    class TransferMark {
    public:
        TransferMark(Runtime&, const char*, const VideoCore::Image&) {}
    };

    void UploadImage(VideoCore::Image* dst, const VideoCore::Buffer* src,
                     std::span<const vk::BufferImageCopy> upload_copies);
    void DownloadImage(VideoCore::Image* src, const VideoCore::Buffer* dst,
                       std::span<const vk::BufferImageCopy> download_copies);

    void CopyImage(VideoCore::Image* src, VideoCore::Image* dst);
    void CopyAliasImage(VideoCore::Image* src, VideoCore::Image* dst, const vk::Extent3D& extent);
    void CopyImageWithBuffer(VideoCore::Image* src, VideoCore::Image* dst,
                             const VideoCore::Buffer* buffer, u64 offset);
    void CopyMip(VideoCore::Image* src, VideoCore::Image* dst, u32 mip, u32 slice);
    void CopyColorAndDepth(VideoCore::Image* src, VideoCore::Image* dst);
    void CopyDepthStencil(VideoCore::Image* src, VideoCore::Image* dst,
                          const VideoCore::SubresourceRange& sub_range);
    void ResolveImage(VideoCore::Image* src, VideoCore::Image* dst,
                      const VideoCore::SubresourceRange& src_range,
                      const VideoCore::SubresourceRange& dst_range);
    void ClearImage(VideoCore::Image* dst, const VideoCore::SubresourceRange& range,
                    const vk::ClearValue& clear_value);

    /// MSAA backing of `image` with `num_samples` (created on first use; contents are not
    /// converted between sample counts yet).
    void SetBackingSamples(VideoCore::Image* image, u32 num_samples, bool copy_backing = true);

    void AccessBuffer(const VideoCore::Buffer* handle, u64 offset, u64 size,
                      vk::PipelineStageFlags2 src_stage, vk::AccessFlags2 src_access);
    bool IsBufferAccessed(const VideoCore::Buffer*, u64, u64, bool = false) {
        return false;
    }
    void FlushBarriers() {}

    void SetImageAccessHook(void (*hook)(void*), void* context) {
        image_access_hook = hook;
        image_access_context = context;
    }
    void BeforeImageAccess() {
        if (image_access_hook) {
            image_access_hook(image_access_context);
        }
    }

    /// One region of image-to-image copy (vk::ImageCopy semantics, extents in texels). Formats
    /// of equal block size that Metal cannot copy directly go through a staging buffer.
    void CopyRegion(VideoCore::Image* src, VideoCore::Image* dst, const vk::ImageCopy& region);

private:
    void (*image_access_hook)(void*) = nullptr;
    void* image_access_context = nullptr;
    const Instance& instance;
    Scheduler& scheduler;
    StagingBufferPool staging_pool;
    void* fill_pipeline = nullptr; ///< id<MTLComputePipelineState>: u32 pattern fill
};

} // namespace Vulkan
