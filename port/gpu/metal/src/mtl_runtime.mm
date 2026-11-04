// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: Runtime (buffer and image transfers on blit encoders).

#include <algorithm>
#include <cstdio>

#include "common/assert.h"
#include "mtl_format.h"
#include "mtl_objc.h"
#include "mtl_scheduler_internal.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_runtime.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"

namespace Vulkan {

namespace {

using Metal::FormatInfo;

bool IsUntracked(id<MTLBuffer> buffer) {
    return buffer.hazardTrackingMode == MTLHazardTrackingModeUntracked;
}

bool Is3D(const VideoCore::Image& image) {
    return image.info.type == AmdGpu::ImageType::Color3D && !image.info.props.is_host_2d;
}

/// Bytes per block of `aspect` in a buffer copy, and the blit option selecting it.
std::pair<u32, MTLBlitOption> AspectBytes(const FormatInfo& f, vk::ImageAspectFlags aspect) {
    if (f.depth && f.stencil) {
        if (aspect == vk::ImageAspectFlagBits::eStencil) {
            return {1, MTLBlitOptionStencilFromDepthStencil};
        }
        if (aspect == vk::ImageAspectFlagBits::eDepth) {
            return {4, MTLBlitOptionDepthFromDepthStencil};
        }
    }
    return {f.block_bytes, MTLBlitOptionNone};
}

MTLSize MipSize(id<MTLTexture> texture, u32 level) {
    return MTLSizeMake(std::max<NSUInteger>(texture.width >> level, 1),
                       std::max<NSUInteger>(texture.height >> level, 1),
                       std::max<NSUInteger>(texture.depth >> level, 1));
}

/// Clamps a copy box at `origin` to the mip's size.
MTLSize Clamp(MTLSize size, MTLOrigin origin, MTLSize mip) {
    return MTLSizeMake(origin.x >= mip.width ? 0 : std::min(size.width, mip.width - origin.x),
                       origin.y >= mip.height ? 0 : std::min(size.height, mip.height - origin.y),
                       origin.z >= mip.depth ? 0 : std::min(size.depth, mip.depth - origin.z));
}

void LogOnce(const char* what) {
    static std::atomic<u32> count{0};
    if (count.fetch_add(1) < 32) {
        std::printf("GPU (Metal): %s\n", what);
    }
}

const char* kFillSource = R"(
#include <metal_stdlib>
using namespace metal;
kernel void fill_u32(device uint* dst [[buffer(0)]], constant uint2& p [[buffer(1)]],
                     uint i [[thread_position_in_grid]]) {
    if (i < p.y) {
        dst[i] = p.x;
    }
}
)";

} // namespace

Runtime::Runtime(const Instance& instance_, Scheduler& scheduler_)
    : instance{instance_}, scheduler{scheduler_}, staging_pool{instance, scheduler} {
    NSError* error = nil;
    id<MTLDevice> device = Metal::Device();
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:kFillSource]
                                                  options:nil
                                                    error:&error];
    ASSERT_MSG(library, "Metal fill shader: {}", error.localizedDescription.UTF8String);
    id<MTLFunction> fn = [library newFunctionWithName:@"fill_u32"];
    id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&error];
    ASSERT_MSG(pso, "Metal fill pipeline: {}", error.localizedDescription.UTF8String);
    fill_pipeline = (__bridge_retained void*)pso;
}

Runtime::~Runtime() {
    if (fill_pipeline) {
        id pso = (__bridge_transfer id)fill_pipeline;
        (void)pso;
    }
}

void Runtime::TickFrame() {
    staging_pool.TickFrame();
}

void Runtime::CopyBuffer(const VideoCore::Buffer* src, const VideoCore::Buffer* dst,
                         std::span<const vk::BufferCopy> copies) {
    if (copies.empty()) {
        return;
    }
    id<MTLBuffer> s = Metal::Buffer(src->Handle());
    id<MTLBuffer> d = Metal::Buffer(dst->Handle());
    id<MTLBlitCommandEncoder> blit = MetalScheduler::Blit(scheduler, "CopyBuffer");
    for (const auto& c : copies) {
        if (c.size == 0) {
            continue;
        }
        [blit copyFromBuffer:s sourceOffset:c.srcOffset toBuffer:d destinationOffset:c.dstOffset
                        size:c.size];
    }
    if (IsUntracked(d)) {
        MetalScheduler::NoteUntrackedWrite(scheduler);
    }
}

void Runtime::FillBuffer(const VideoCore::Buffer* dst, u64 offset, u64 size, u32 value) {
    if (size == 0) {
        return;
    }
    id<MTLBuffer> d = Metal::Buffer(dst->Handle());
    const u8 b = value & 0xff;
    if (value == u32(b) * 0x01010101u) {
        [MetalScheduler::Blit(scheduler, "FillBuffer") fillBuffer:d range:NSMakeRange(offset, size) value:b];
    } else {
        ASSERT_MSG(offset % 4 == 0 && size % 4 == 0, "unaligned u32 fill");
        id<MTLComputeCommandEncoder> enc = MetalScheduler::Compute(scheduler, "fill");
        [enc setComputePipelineState:(__bridge id<MTLComputePipelineState>)fill_pipeline];
        [enc setBuffer:d offset:offset atIndex:0];
        const u32 params[2] = {value, u32(size / 4)};
        [enc setBytes:params length:sizeof(params) atIndex:1];
        [enc dispatchThreads:MTLSizeMake(size / 4, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    }
    if (IsUntracked(d)) {
        MetalScheduler::NoteUntrackedWrite(scheduler);
    }
}

void Runtime::InlineData(VideoCore::Buffer* dst, u64 offset, u32 value) {
    FillBuffer(dst, offset, 4, value);
}

bool Runtime::Transit(VideoCore::Image* image, vk::ImageLayout dst_layout,
                      vk::PipelineStageFlags2 dst_stage, vk::AccessFlags2 dst_access,
                      std::optional<VideoCore::SubresourceRange>) {
    auto& state = image->backing->state;
    state.layout = dst_layout;
    state.pl_stage = dst_stage;
    state.access_mask = dst_access;
    return false;
}

void Runtime::AccessBuffer(const VideoCore::Buffer* handle, u64, u64, vk::PipelineStageFlags2,
                           vk::AccessFlags2 src_access) {
    constexpr auto writes = vk::AccessFlagBits2::eShaderWrite |
                            vk::AccessFlagBits2::eShaderStorageWrite |
                            vk::AccessFlagBits2::eMemoryWrite | vk::AccessFlagBits2::eTransferWrite;
    if ((src_access & writes) && IsUntracked(Metal::Buffer(handle->Handle()))) {
        MetalScheduler::NoteUntrackedWrite(scheduler);
    }
}

void Runtime::UploadImage(VideoCore::Image* dst, const VideoCore::Buffer* src,
                          std::span<const vk::BufferImageCopy> upload_copies) {
    dst->flags &= ~VideoCore::ImageFlagBits::Dirty;
    id<MTLTexture> texture = Metal::Texture(dst->GetImage());
    if (!texture || upload_copies.empty()) {
        return;
    }
    const FormatInfo& f = Metal::GetFormat(dst->info.pixel_format);
    id<MTLBuffer> buffer = Metal::Buffer(src->Handle());
    id<MTLBlitCommandEncoder> blit = MetalScheduler::Blit(scheduler, "UploadImage");
    const bool is_3d = texture.textureType == MTLTextureType3D;
    for (const auto& c : upload_copies) {
        const auto [bytes, option] = AspectBytes(f, c.imageSubresource.aspectMask);
        const u32 row_texels = c.bufferRowLength ? c.bufferRowLength : c.imageExtent.width;
        const u32 image_rows = c.bufferImageHeight ? c.bufferImageHeight : c.imageExtent.height;
        const u64 bpr = u64((row_texels + f.block_width - 1) / f.block_width) * bytes;
        const u64 bpi = bpr * ((image_rows + f.block_height - 1) / f.block_height);
        const u32 level = c.imageSubresource.mipLevel;
        if (level >= texture.mipmapLevelCount) {
            continue;
        }
        const MTLOrigin origin = MTLOriginMake(c.imageOffset.x, c.imageOffset.y,
                                               is_3d ? c.imageOffset.z : 0);
        const MTLSize size = Clamp(MTLSizeMake(c.imageExtent.width, c.imageExtent.height,
                                               is_3d ? c.imageExtent.depth : 1),
                                   origin, MipSize(texture, level));
        if (size.width == 0 || size.height == 0 || size.depth == 0) {
            continue;
        }
        const u32 layers = is_3d ? 1 : c.imageSubresource.layerCount;
        for (u32 layer = 0; layer < layers; ++layer) {
            const u32 slice = c.imageSubresource.baseArrayLayer + layer;
            if (slice >= texture.arrayLength * (texture.textureType == MTLTextureTypeCube ? 6 : 1) &&
                !is_3d) {
                break;
            }
            [blit copyFromBuffer:buffer
                       sourceOffset:c.bufferOffset + layer * bpi
                  sourceBytesPerRow:bpr
                sourceBytesPerImage:bpi
                         sourceSize:size
                          toTexture:texture
                   destinationSlice:is_3d ? 0 : slice
                   destinationLevel:level
                  destinationOrigin:origin
                            options:option];
        }
    }
}

void Runtime::DownloadImage(VideoCore::Image* src, const VideoCore::Buffer* dst,
                            std::span<const vk::BufferImageCopy> download_copies) {
    id<MTLTexture> texture = Metal::Texture(src->GetImage());
    if (!texture || download_copies.empty()) {
        return;
    }
    SetBackingSamples(src, 1);
    texture = Metal::Texture(src->GetImage());
    const FormatInfo& f = Metal::GetFormat(src->info.pixel_format);
    id<MTLBuffer> buffer = Metal::Buffer(dst->Handle());
    id<MTLBlitCommandEncoder> blit = MetalScheduler::Blit(scheduler, "DownloadImage");
    const bool is_3d = texture.textureType == MTLTextureType3D;
    for (const auto& c : download_copies) {
        const auto [bytes, option] = AspectBytes(f, c.imageSubresource.aspectMask);
        const u32 row_texels = c.bufferRowLength ? c.bufferRowLength : c.imageExtent.width;
        const u32 image_rows = c.bufferImageHeight ? c.bufferImageHeight : c.imageExtent.height;
        const u64 bpr = u64((row_texels + f.block_width - 1) / f.block_width) * bytes;
        const u64 bpi = bpr * ((image_rows + f.block_height - 1) / f.block_height);
        const u32 level = c.imageSubresource.mipLevel;
        if (level >= texture.mipmapLevelCount) {
            continue;
        }
        const MTLOrigin origin = MTLOriginMake(c.imageOffset.x, c.imageOffset.y,
                                               is_3d ? c.imageOffset.z : 0);
        const MTLSize size = Clamp(MTLSizeMake(c.imageExtent.width, c.imageExtent.height,
                                               is_3d ? c.imageExtent.depth : 1),
                                   origin, MipSize(texture, level));
        if (size.width == 0 || size.height == 0 || size.depth == 0) {
            continue;
        }
        const u32 layers = is_3d ? 1 : c.imageSubresource.layerCount;
        for (u32 layer = 0; layer < layers; ++layer) {
            const u32 slice = c.imageSubresource.baseArrayLayer + layer;
            if (!is_3d && slice >= texture.arrayLength) {
                break;
            }
            [blit copyFromTexture:texture
                             sourceSlice:is_3d ? 0 : slice
                             sourceLevel:level
                            sourceOrigin:origin
                              sourceSize:size
                                toBuffer:buffer
                       destinationOffset:c.bufferOffset + layer * bpi
                  destinationBytesPerRow:bpr
                destinationBytesPerImage:bpi
                                 options:option];
        }
    }
    if (IsUntracked(buffer)) {
        MetalScheduler::NoteUntrackedWrite(scheduler);
    }
}

void Runtime::CopyRegion(VideoCore::Image* src, VideoCore::Image* dst, const vk::ImageCopy& r) {
    id<MTLTexture> s = Metal::Texture(src->GetImage());
    id<MTLTexture> d = Metal::Texture(dst->GetImage());
    if (!s || !d) {
        return;
    }
    if (s.sampleCount != d.sampleCount) {
        LogOnce("copy between images of different sample counts skipped");
        return;
    }
    const u32 src_level = r.srcSubresource.mipLevel;
    const u32 dst_level = r.dstSubresource.mipLevel;
    if (src_level >= s.mipmapLevelCount || dst_level >= d.mipmapLevelCount) {
        return;
    }
    const bool s3d = s.textureType == MTLTextureType3D;
    const bool d3d = d.textureType == MTLTextureType3D;
    // Layers of a 2D array map to slices of a 3D image.
    const u32 layers = std::max(r.srcSubresource.layerCount, r.dstSubresource.layerCount);
    const u32 depth = (s3d && d3d) ? r.extent.depth : 1;
    const MTLSize src_mip = MipSize(s, src_level);
    const MTLSize dst_mip = MipSize(d, dst_level);

    const FormatInfo& sf = Metal::GetFormat(src->info.pixel_format);
    const FormatInfo& df = Metal::GetFormat(dst->info.pixel_format);
    const bool direct = s.pixelFormat == d.pixelFormat;
    if (!direct && (sf.block_bytes != df.block_bytes || sf.block_width != df.block_width ||
                    sf.depth != df.depth || sf.stencil != df.stencil)) {
        // Different texel sizes (color <-> depth of another size): reinterpretation is not
        // implemented yet.
        LogOnce("image copy between incompatible formats skipped");
        return;
    }
    id<MTLBlitCommandEncoder> blit = MetalScheduler::Blit(scheduler, "CopyRegion");
    for (u32 layer = 0; layer < layers; ++layer) {
        const u32 src_slice = s3d ? 0 : r.srcSubresource.baseArrayLayer + layer;
        const u32 dst_slice = d3d ? 0 : r.dstSubresource.baseArrayLayer + layer;
        if ((!s3d && src_slice >= s.arrayLength) || (!d3d && dst_slice >= d.arrayLength)) {
            break;
        }
        const MTLOrigin so = MTLOriginMake(r.srcOffset.x, r.srcOffset.y,
                                           s3d ? r.srcOffset.z + (d3d ? 0 : layer) : 0);
        const MTLOrigin dor = MTLOriginMake(r.dstOffset.x, r.dstOffset.y,
                                            d3d ? r.dstOffset.z + (s3d ? 0 : layer) : 0);
        MTLSize size = MTLSizeMake(r.extent.width, r.extent.height, depth);
        size = Clamp(size, so, src_mip);
        size = Clamp(size, dor, dst_mip);
        if (size.width == 0 || size.height == 0 || size.depth == 0) {
            continue;
        }
        if (direct) {
            [blit copyFromTexture:s
                      sourceSlice:src_slice
                      sourceLevel:src_level
                     sourceOrigin:so
                       sourceSize:size
                        toTexture:d
                 destinationSlice:dst_slice
                 destinationLevel:dst_level
                destinationOrigin:dor];
            continue;
        }
        // Same block size, different format: through a staging buffer.
        const u64 bpr = Metal::RowBytes(sf, size.width);
        const u64 bpi = bpr * Metal::BlockRows(sf, size.height);
        const auto staging = staging_pool.Request(bpi * size.depth, VideoCore::MemoryType::DeviceLocal, 256);
        id<MTLBuffer> buf = Metal::Buffer(staging.buffer->Handle());
        [blit copyFromTexture:s
                         sourceSlice:src_slice
                         sourceLevel:src_level
                        sourceOrigin:so
                          sourceSize:size
                            toBuffer:buf
                   destinationOffset:staging.offset
              destinationBytesPerRow:bpr
            destinationBytesPerImage:bpi];
        [blit copyFromBuffer:buf
                   sourceOffset:staging.offset
              sourceBytesPerRow:bpr
            sourceBytesPerImage:bpi
                     sourceSize:size
                      toTexture:d
               destinationSlice:dst_slice
               destinationLevel:dst_level
              destinationOrigin:dor];
    }
}

void Runtime::CopyImage(VideoCore::Image* src, VideoCore::Image* dst) {
    const u32 num_mips = std::min(src->info.resources.levels, dst->info.resources.levels);
    const u32 base_width = src->info.size.width;
    const u32 base_height = src->info.size.height;
    const u32 base_depth = Is3D(*dst) ? dst->info.size.depth : src->info.size.depth;
    for (u32 mip = 0; mip < num_mips; ++mip) {
        vk::ImageCopy region{};
        region.srcSubresource.mipLevel = mip;
        region.dstSubresource.mipLevel = mip;
        const u32 w = std::max(base_width >> mip, 1u);
        const u32 h = std::max(base_height >> mip, 1u);
        const u32 d = std::max(base_depth >> mip, 1u);
        if (Is3D(*src) && Is3D(*dst)) {
            region.srcSubresource.layerCount = region.dstSubresource.layerCount = 1;
            region.extent = vk::Extent3D{w, h, d};
        } else if (Is3D(*dst)) {
            region.srcSubresource.layerCount = src->info.resources.layers;
            region.dstSubresource.layerCount = 1;
            region.extent = vk::Extent3D{w, h, 1};
        } else if (Is3D(*src)) {
            region.srcSubresource.layerCount = 1;
            region.dstSubresource.layerCount = dst->info.resources.layers;
            region.extent = vk::Extent3D{w, h, 1};
        } else {
            const u32 layers = std::min(src->info.resources.layers, dst->info.resources.layers);
            region.srcSubresource.layerCount = region.dstSubresource.layerCount = layers;
            region.extent = vk::Extent3D{w, h, 1};
        }
        CopyRegion(src, dst, region);
    }
    dst->flags |= (src->flags & VideoCore::ImageFlagBits::GpuModified);
    dst->flags &= ~VideoCore::ImageFlagBits::Dirty;
}

void Runtime::CopyAliasImage(VideoCore::Image* src, VideoCore::Image* dst,
                             const vk::Extent3D& extent) {
    vk::ImageCopy region{};
    region.srcSubresource.layerCount = 1;
    region.dstSubresource.layerCount = 1;
    region.extent = extent;
    CopyRegion(src, dst, region);
}

void Runtime::CopyImageWithBuffer(VideoCore::Image* src, VideoCore::Image* dst,
                                  const VideoCore::Buffer*, u64) {
    CopyImage(src, dst);
}

void Runtime::CopyMip(VideoCore::Image* src, VideoCore::Image* dst, u32 mip, u32 slice) {
    vk::ImageCopy region{};
    region.srcSubresource.mipLevel = 0;
    region.srcSubresource.layerCount = src->info.resources.layers;
    region.dstSubresource.mipLevel = mip;
    region.dstSubresource.baseArrayLayer = slice;
    region.dstSubresource.layerCount = src->info.resources.layers;
    region.extent = vk::Extent3D{src->info.size.width, src->info.size.height,
                                 src->info.size.depth};
    CopyRegion(src, dst, region);
    dst->flags |= (src->flags & VideoCore::ImageFlagBits::GpuModified);
    dst->flags &= ~VideoCore::ImageFlagBits::Dirty;
}

void Runtime::CopyColorAndDepth(VideoCore::Image* src, VideoCore::Image* dst) {
    if (src->info.num_samples == 1 && dst->info.num_samples == 1) {
        CopyImage(src, dst);
    } else {
        LogOnce("MSAA color/depth copy not implemented");
    }
}

void Runtime::CopyDepthStencil(VideoCore::Image* src, VideoCore::Image* dst,
                               const VideoCore::SubresourceRange& sub_range) {
    vk::ImageCopy region{};
    region.srcSubresource.mipLevel = sub_range.base.level;
    region.srcSubresource.baseArrayLayer = sub_range.base.layer;
    region.srcSubresource.layerCount = sub_range.extent.layers;
    region.dstSubresource = region.srcSubresource;
    region.extent = vk::Extent3D{dst->info.size.width, dst->info.size.height, 1};
    CopyRegion(src, dst, region);
}

void Runtime::ResolveImage(VideoCore::Image* src, VideoCore::Image* dst,
                           const VideoCore::SubresourceRange& src_range,
                           const VideoCore::SubresourceRange& dst_range) {
    id<MTLTexture> s = Metal::Texture(src->GetImage());
    id<MTLTexture> d = Metal::Texture(dst->GetImage());
    if (!s || !d) {
        return;
    }
    if (s.sampleCount <= 1) {
        vk::ImageCopy region{};
        region.srcSubresource.mipLevel = src_range.base.level;
        region.srcSubresource.baseArrayLayer = src_range.base.layer;
        region.srcSubresource.layerCount = src_range.extent.layers;
        region.dstSubresource.mipLevel = dst_range.base.level;
        region.dstSubresource.baseArrayLayer = dst_range.base.layer;
        region.dstSubresource.layerCount = dst_range.extent.layers;
        region.extent = vk::Extent3D{dst->info.size.width, dst->info.size.height, 1};
        CopyRegion(src, dst, region);
        return;
    }
    // A render pass whose only work is the MSAA resolve.
    if (MetalScheduler::PassStatsEnabled()) {
        MetalScheduler::NoteRenderBreak(scheduler, "ResolveImage");
    }
    scheduler.EndEncoding();
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = s;
    pass.colorAttachments[0].slice = src_range.base.layer;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    pass.colorAttachments[0].resolveTexture = d;
    pass.colorAttachments[0].resolveLevel = dst_range.base.level;
    pass.colorAttachments[0].resolveSlice = dst_range.base.layer;
    id<MTLRenderCommandEncoder> enc =
        [MetalScheduler::CommandBuffer(scheduler) renderCommandEncoderWithDescriptor:pass];
    scheduler.SetRenderEncoder((__bridge void*)enc, ~0ull);
    scheduler.EndEncoding();
}

void Runtime::ClearImage(VideoCore::Image* dst, const VideoCore::SubresourceRange& range,
                         const vk::ClearValue& clear_value) {
    id<MTLTexture> d = Metal::Texture(dst->GetImage());
    if (!d) {
        return;
    }
    const FormatInfo& f = Metal::GetFormat(dst->info.pixel_format);
    if (!f.renderable && !f.depth) {
        LogOnce("clear of a non-renderable image skipped");
        return;
    }
    if (MetalScheduler::PassStatsEnabled()) {
        MetalScheduler::NoteRenderBreak(scheduler, "ClearImage");
    }
    scheduler.EndEncoding();
    const bool is_3d = d.textureType == MTLTextureType3D;
    for (u32 level = range.base.level; level < range.base.level + range.extent.levels; ++level) {
        if (level >= d.mipmapLevelCount) {
            break;
        }
        const u32 slices = is_3d ? std::max<u32>(d.depth >> level, 1) : range.extent.layers;
        for (u32 i = 0; i < slices; ++i) {
            const u32 slice = is_3d ? i : range.base.layer + i;
            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            if (f.depth || f.stencil) {
                if (f.depth) {
                    pass.depthAttachment.texture = d;
                    pass.depthAttachment.level = level;
                    pass.depthAttachment.slice = is_3d ? 0 : slice;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = clear_value.depthStencil.depth;
                }
                if (f.stencil) {
                    pass.stencilAttachment.texture = d;
                    pass.stencilAttachment.level = level;
                    pass.stencilAttachment.slice = is_3d ? 0 : slice;
                    pass.stencilAttachment.loadAction = MTLLoadActionClear;
                    pass.stencilAttachment.storeAction = MTLStoreActionStore;
                    pass.stencilAttachment.clearStencil = clear_value.depthStencil.stencil;
                }
            } else {
                auto* att = pass.colorAttachments[0];
                att.texture = d;
                att.level = level;
                if (is_3d) {
                    att.depthPlane = slice;
                } else {
                    att.slice = slice;
                }
                att.loadAction = MTLLoadActionClear;
                att.storeAction = MTLStoreActionStore;
                const auto& c = clear_value.color.float32;
                att.clearColor = MTLClearColorMake(c[0], c[1], c[2], c[3]);
            }
            id<MTLRenderCommandEncoder> enc =
                [MetalScheduler::CommandBuffer(scheduler) renderCommandEncoderWithDescriptor:pass];
            scheduler.SetRenderEncoder((__bridge void*)enc, ~0ull);
            scheduler.EndEncoding();
        }
    }
    dst->flags |= VideoCore::ImageFlagBits::GpuModified;
}

} // namespace Vulkan
