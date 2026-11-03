// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: GCN (de)tiling on the GPU with the Vulkan renderer's tiling.comp, translated
// to MSL (spec constants become function constants), and the blit helper.

#include <bit>
#include <cstdio>
#include <mutex>
#include <unordered_map>

#include "common/assert.h"
#include "mtl_objc.h"
#include "mtl_scheduler_internal.h"
#include "mtl_shader.h"
#include "video_core/amdgpu/tiling.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_runtime.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"
#include "video_core/texture_cache/blit_helper.h"
#include "video_core/texture_cache/image.h"
#include "video_core/texture_cache/image_info.h"
#include "video_core/texture_cache/tile_manager.h"

#include "video_core/host_shaders/tiling_macro_128_comp.h"
#include "video_core/host_shaders/tiling_macro_16_comp.h"
#include "video_core/host_shaders/tiling_macro_32_comp.h"
#include "video_core/host_shaders/tiling_macro_64_comp.h"
#include "video_core/host_shaders/tiling_macro_8_comp.h"
#include "video_core/host_shaders/tiling_macro_96_comp.h"
#include "video_core/host_shaders/tiling_micro_128_comp.h"
#include "video_core/host_shaders/tiling_micro_16_comp.h"
#include "video_core/host_shaders/tiling_micro_32_comp.h"
#include "video_core/host_shaders/tiling_micro_64_comp.h"
#include "video_core/host_shaders/tiling_micro_8_comp.h"
#include "video_core/host_shaders/tiling_micro_96_comp.h"

namespace VideoCore {

namespace {

struct TilingInfo {
    u32 bank_swizzle;
    u32 num_slices;
    u32 num_mips;
    std::array<ImageInfo::MipInfo, 16> mips;
};

std::mutex pipelines_mutex;
std::unordered_map<u64, id<MTLComputePipelineState>> pipelines;

id<MTLComputePipelineState> TilingPipeline(const ImageInfo& info, bool is_tiler) {
    const u64 key = (u64(info.tile_mode) << 40) | (u64(info.num_bits) << 16) |
                    (u64(info.num_samples) << 8) | u64(is_tiler);
    std::scoped_lock lock{pipelines_mutex};
    if (const auto it = pipelines.find(key); it != pipelines.end()) {
        return it->second;
    }
    const auto micro_tile_mode = AmdGpu::GetMicroTileMode(info.tile_mode);
    const bool is_macro = AmdGpu::IsMacroTiled(info.array_mode);
    std::array<u32, 12> spec{
        info.num_samples,
        u32(micro_tile_mode),
        AmdGpu::GetMicroTileThickness(info.array_mode),
        u32(is_tiler),
    };
    if (is_macro) {
        const auto macro_tile_mode =
            AmdGpu::CalculateMacrotileMode(info.tile_mode, info.num_bits, info.num_samples);
        spec[4] = u32(info.array_mode);
        spec[5] = u32(AmdGpu::GetPipeConfig(info.tile_mode));
        spec[6] = AmdGpu::GetBankWidth(macro_tile_mode);
        spec[7] = AmdGpu::GetBankHeight(macro_tile_mode);
        spec[8] = AmdGpu::GetNumBanks(macro_tile_mode);
        spec[9] = std::bit_width(spec[8]) - 1;
        spec[10] = AmdGpu::CalculateTileSplit(info.tile_mode, info.array_mode, micro_tile_mode,
                                              info.num_bits);
        spec[11] = AmdGpu::GetMacrotileAspect(macro_tile_mode);
    }
    std::span<const u32> code;
    switch (info.num_bits) {
    case 8:
        code = is_macro ? std::span<const u32>{TILING_MACRO_8_COMP} : std::span<const u32>{TILING_MICRO_8_COMP};
        break;
    case 16:
        code = is_macro ? std::span<const u32>{TILING_MACRO_16_COMP} : std::span<const u32>{TILING_MICRO_16_COMP};
        break;
    case 32:
        code = is_macro ? std::span<const u32>{TILING_MACRO_32_COMP} : std::span<const u32>{TILING_MICRO_32_COMP};
        break;
    case 64:
        code = is_macro ? std::span<const u32>{TILING_MACRO_64_COMP} : std::span<const u32>{TILING_MICRO_64_COMP};
        break;
    case 96:
        code = is_macro ? std::span<const u32>{TILING_MACRO_96_COMP} : std::span<const u32>{TILING_MICRO_96_COMP};
        break;
    case 128:
        code = is_macro ? std::span<const u32>{TILING_MACRO_128_COMP} : std::span<const u32>{TILING_MICRO_128_COMP};
        break;
    default:
        UNREACHABLE_MSG("Unsupported tiling pixel width {}", info.num_bits);
    }
    Metal::TranslateOptions options;
    options.slots = {{0, 0, Metal::ResourceKind::Buffer, 0},
                     {0, 1, Metal::ResourceKind::Buffer, 1},
                     {0, 2, Metal::ResourceKind::Buffer, 2}};
    void* raw = Metal::NewComputePipeline(code, spec, options, is_tiler ? "tiler" : "detiler");
    ASSERT_MSG(raw, "Metal tiling pipeline");
    id<MTLComputePipelineState> pso = (__bridge_transfer id<MTLComputePipelineState>)raw;
    pipelines.emplace(key, pso);
    return pso;
}

TilingInfo MakeParams(const ImageInfo& info, u32 num_mips) {
    TilingInfo params{};
    params.bank_swizzle = info.bank_swizzle;
    params.num_slices = info.props.is_volume ? info.size.depth : info.resources.layers;
    params.num_mips = num_mips;
    for (u32 mip = 0; mip < params.num_mips; ++mip) {
        auto& mip_info = params.mips[mip];
        mip_info = info.mips_layout[mip];
        if (info.props.is_block) {
            mip_info.pitch = std::max((mip_info.pitch + 3) / 4, 1U);
            mip_info.height = std::max((mip_info.height + 3) / 4, 1U);
        }
    }
    return params;
}

void Dispatch(Vulkan::Scheduler& scheduler, id<MTLComputePipelineState> pso,
              const Buffer* tiled, u64 tiled_offset, const Buffer* linear, u64 linear_offset,
              const TilingInfo& params, u32 dim_x) {
    char label[64] = "";
    if (Vulkan::MetalScheduler::LabelMode()) {
        std::snprintf(label, sizeof(label), "tile %u groups", dim_x);
    }
    id<MTLComputeCommandEncoder> enc = Vulkan::MetalScheduler::Compute(scheduler, label);
    [enc setComputePipelineState:pso];
    [enc setBuffer:Metal::Buffer(tiled->Handle()) offset:tiled_offset atIndex:0];
    [enc setBuffer:Metal::Buffer(linear->Handle()) offset:linear_offset atIndex:1];
    [enc setBytes:&params length:sizeof(params) atIndex:2];
    [enc dispatchThreadgroups:MTLSizeMake(dim_x, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
}

} // namespace

TileManager::TileManager(const Vulkan::Instance& instance_, Vulkan::Scheduler& scheduler_,
                         Vulkan::Runtime& runtime_, StreamBuffer& stream_buffer_)
    : instance{instance_}, scheduler{scheduler_}, runtime{runtime_}, stream_buffer{stream_buffer_} {}

TileManager::~TileManager() = default;

std::pair<const Buffer*, u64> TileManager::DetileImage(const Buffer* in_buffer, u64 in_offset,
                                                       const ImageInfo& info) {
    if (!info.props.is_tiled) {
        return {in_buffer, in_offset};
    }
    const TilingInfo params = MakeParams(info, info.resources.levels);
    const auto staging = runtime.GetStagingPool().Request(info.guest_size, MemoryType::DeviceLocal);
    const auto dim_x = static_cast<u32>((info.guest_size / (info.num_bits / 8)) / 64);
    Dispatch(scheduler, TilingPipeline(info, false), in_buffer, in_offset, staging.buffer,
             staging.offset, params, dim_x);
    return {staging.buffer, staging.offset};
}

void TileManager::TileImage(Image& in_image, std::span<vk::BufferImageCopy> buffer_copies,
                            const Buffer* out_buffer, u64 out_offset) {
    const auto& info = in_image.info;
    if (!info.props.is_tiled) {
        for (auto& copy : buffer_copies) {
            copy.bufferOffset += out_offset;
        }
        runtime.DownloadImage(&in_image, out_buffer, buffer_copies);
        return;
    }
    const TilingInfo params = MakeParams(info, static_cast<u32>(buffer_copies.size()));
    const auto staging = runtime.GetStagingPool().Request(info.guest_size, MemoryType::DeviceLocal);
    for (auto& copy : buffer_copies) {
        copy.bufferOffset += staging.offset;
    }
    runtime.DownloadImage(&in_image, staging.buffer, buffer_copies);
    const auto dim_x = static_cast<u32>((info.guest_size / (info.num_bits / 8)) / 64);
    Dispatch(scheduler, TilingPipeline(info, true), out_buffer, out_offset, staging.buffer,
             staging.offset, params, dim_x);
    runtime.AccessBuffer(out_buffer, out_offset, info.guest_size,
                         vk::PipelineStageFlagBits2::eComputeShader,
                         vk::AccessFlagBits2::eShaderWrite);
}

// The blit helper reinterprets color as MSAA depth and copies between MSAA images: not used by
// the Metal runtime yet (it logs those cases).
BlitHelper::BlitHelper(const Vulkan::Instance& instance_, Vulkan::Scheduler& scheduler_)
    : instance{instance_}, scheduler{scheduler_} {}

BlitHelper::~BlitHelper() = default;

} // namespace VideoCore
