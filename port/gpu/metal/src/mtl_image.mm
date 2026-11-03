// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: images (MTLTextures), their MSAA backings, views and samplers.

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>

#include "common/assert.h"
#include "mtl_format.h"
#include "mtl_image.h"
#include "mtl_objc.h"
#include "video_core/amdgpu/tlg_block1d.h"
#include "video_core/renderer_vulkan/liverpool_to_vk.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_runtime.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"
#include "video_core/texture_cache/image.h"
#include "video_core/texture_cache/image_view.h"
#include "video_core/texture_cache/sampler.h"

namespace Metal {

namespace {

void Log(const char* fmt, auto... args) {
    static std::atomic<u32> count{0};
    if (count.fetch_add(1) < 64) {
        std::printf(fmt, args...);
    }
}

MTLPixelFormat RawFormat(u32 bytes) {
    switch (bytes) {
    case 1:
        return MTLPixelFormatR8Uint;
    case 2:
        return MTLPixelFormatR16Uint;
    case 8:
        return MTLPixelFormatRG32Uint;
    case 16:
        return MTLPixelFormatRGBA32Uint;
    default:
        return MTLPixelFormatR32Uint;
    }
}

MTLPixelFormat PixelFormatOf(vk::Format format) {
    const FormatInfo& f = GetFormat(format);
    if (f.metal) {
        return static_cast<MTLPixelFormat>(f.metal);
    }
    Log("GPU (Metal): no Metal format for %s, using raw %u-byte texels\n",
        vk::to_string(format).c_str(), f.block_bytes);
    return RawFormat(f.block_bytes);
}

id<MTLTexture> NewTexture(const VideoCore::Image& image, u32 samples) {
    const auto& info = image.info;
    const FormatInfo& f = GetFormat(info.pixel_format);
    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.pixelFormat = PixelFormatOf(info.pixel_format);
    const bool is_3d = info.type == AmdGpu::ImageType::Color3D && !info.props.is_host_2d;
    desc.width = std::max(info.size.width, 1u);
    desc.height = std::max(info.size.height, 1u);
    desc.depth = is_3d ? std::max(info.size.depth, 1u) : 1;
    const u32 layers = is_3d ? 1 : std::max<u32>(info.resources.layers, 1);
    if (samples > 1) {
        if (![Device() supportsTextureSampleCount:samples]) {
            samples = 4;
        }
        desc.textureType = layers > 1 ? MTLTextureType2DMultisampleArray
                                      : MTLTextureType2DMultisample;
        desc.sampleCount = samples;
        desc.mipmapLevelCount = 1;
    } else {
        desc.textureType = is_3d ? MTLTextureType3D
                                 : (layers > 1 ? MTLTextureType2DArray : MTLTextureType2D);
        const u32 max_dim = std::max({desc.width, desc.height, desc.depth});
        const u32 max_levels = 32 - __builtin_clz(max_dim);
        desc.mipmapLevelCount = std::clamp<u32>(info.resources.levels, 1, max_levels);
    }
    desc.arrayLength = layers;
    desc.storageMode = MTLStorageModePrivate;
    MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    if (f.renderable || f.depth || f.stencil) {
        usage |= MTLTextureUsageRenderTarget;
    }
    if (f.writable && samples <= 1) {
        usage |= MTLTextureUsageShaderWrite;
    }
    desc.usage = usage;
    id<MTLTexture> texture = [Device() newTextureWithDescriptor:desc];
    if (!texture) {
        Log("GPU (Metal): could not create a %ux%ux%u %s texture (%u layers, %u mips, %u "
            "samples)\n",
            u32(desc.width), u32(desc.height), u32(desc.depth),
            vk::to_string(info.pixel_format).c_str(), layers, u32(desc.mipmapLevelCount),
            samples);
    }
    return texture;
}

MTLTextureSwizzle Swizzle(vk::ComponentSwizzle s, MTLTextureSwizzle identity) {
    switch (s) {
    case vk::ComponentSwizzle::eZero:
        return MTLTextureSwizzleZero;
    case vk::ComponentSwizzle::eOne:
        return MTLTextureSwizzleOne;
    case vk::ComponentSwizzle::eR:
        return MTLTextureSwizzleRed;
    case vk::ComponentSwizzle::eG:
        return MTLTextureSwizzleGreen;
    case vk::ComponentSwizzle::eB:
        return MTLTextureSwizzleBlue;
    case vk::ComponentSwizzle::eA:
        return MTLTextureSwizzleAlpha;
    default:
        return identity;
    }
}

bool IsArrayType(MTLTextureType type) {
    return type == MTLTextureType2DArray || type == MTLTextureType2DMultisampleArray ||
           type == MTLTextureTypeCubeArray || type == MTLTextureType1DArray;
}

} // namespace

vk::UniqueImageView CreateImageView(const VideoCore::Image& image,
                                    const VideoCore::ImageViewInfo& info, vk::Format format,
                                    vk::ImageAspectFlags aspect, vk::ImageViewType view_type) {
    id<MTLTexture> base = Texture(image.GetImage());
    if (!base) {
        return {};
    }
    MTLPixelFormat pixel_format = PixelFormatOf(format);
    const bool depth_stencil = base.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
    if (depth_stencil) {
        pixel_format = aspect == vk::ImageAspectFlagBits::eStencil
                           ? MTLPixelFormatX32_Stencil8
                           : MTLPixelFormatDepth32Float_Stencil8;
    } else if (GetFormat(format).depth != GetFormat(image.info.pixel_format).depth) {
        // Depth sampled as color or color as depth: Metal cannot view one as the other.
        pixel_format = base.pixelFormat;
    }
    MTLTextureType type;
    const bool ms = base.sampleCount > 1;
    switch (view_type) {
    case vk::ImageViewType::e3D:
        type = MTLTextureType3D;
        break;
    case vk::ImageViewType::e2DArray:
    case vk::ImageViewType::e1DArray:
        type = ms ? MTLTextureType2DMultisampleArray : MTLTextureType2DArray;
        break;
    case vk::ImageViewType::eCube:
        type = MTLTextureTypeCube;
        break;
    case vk::ImageViewType::eCubeArray:
        type = MTLTextureTypeCubeArray;
        break;
    default:
        type = ms ? MTLTextureType2DMultisample : MTLTextureType2D;
        break;
    }
    if (base.textureType == MTLTextureType3D && type != MTLTextureType3D) {
        type = MTLTextureType3D; // 2D views of 3D images are not supported by Metal
    }
    const u32 levels = static_cast<u32>(base.mipmapLevelCount);
    const u32 base_level = std::min<u32>(info.range.base.level, levels - 1);
    const u32 level_count = std::clamp<u32>(info.range.extent.levels, 1, levels - base_level);
    const u32 slices = base.textureType == MTLTextureType3D ? 1 : static_cast<u32>(base.arrayLength);
    const u32 base_slice = std::min<u32>(info.range.base.layer, slices - 1);
    u32 slice_count = std::clamp<u32>(info.range.extent.layers, 1, slices - base_slice);
    if (!IsArrayType(type) && type != MTLTextureType3D) {
        slice_count = 1;
    }
    static const bool no_swizzle_all = std::getenv("TLG_METAL_NO_SWIZZLE") != nullptr;
    static const bool no_bgra = std::getenv("TLG_METAL_NO_BGRA_SWIZZLE") != nullptr;
    const bool no_swizzle = no_swizzle_all ||
                            (no_bgra && info.mapping.r == vk::ComponentSwizzle::eB &&
                             info.mapping.b == vk::ComponentSwizzle::eR);
    const MTLTextureSwizzleChannels swizzle = no_swizzle ? MTLTextureSwizzleChannelsDefault : MTLTextureSwizzleChannelsMake(
        Swizzle(info.mapping.r, MTLTextureSwizzleRed), Swizzle(info.mapping.g, MTLTextureSwizzleGreen),
        Swizzle(info.mapping.b, MTLTextureSwizzleBlue), Swizzle(info.mapping.a, MTLTextureSwizzleAlpha));
    const bool identity = swizzle.red == MTLTextureSwizzleRed &&
                          swizzle.green == MTLTextureSwizzleGreen &&
                          swizzle.blue == MTLTextureSwizzleBlue &&
                          swizzle.alpha == MTLTextureSwizzleAlpha;
    id<MTLTexture> view;
    if (identity && pixel_format == base.pixelFormat && type == base.textureType &&
        base_level == 0 && level_count == levels && base_slice == 0 &&
        (slice_count == slices || !IsArrayType(type))) {
        view = base;
    } else {
        view = [base newTextureViewWithPixelFormat:pixel_format
                                       textureType:type
                                            levels:NSMakeRange(base_level, level_count)
                                            slices:NSMakeRange(base_slice, slice_count)
                                           swizzle:swizzle];
        if (!view) {
            Log("GPU (Metal): view %s of %s texture failed, using the texture\n",
                vk::to_string(format).c_str(), vk::to_string(image.info.pixel_format).c_str());
            view = base;
        }
    }
    vk::UniqueImageView handle{MtlOwn<vk::ImageView>(view)};
    return handle;
}

void DestroyImageView(vk::UniqueImageView& view) {
    vk::ImageView raw = view.release();
    MtlFree(raw);
}

} // namespace Metal

namespace VideoCore {

Common::IncrementalIdProvider<u64> Image::global_image_uid{};

UniqueImage::~UniqueImage() {
    Destroy();
}

void UniqueImage::Destroy() {
    Metal::MtlFree(image);
}

void UniqueImage::Create(const vk::ImageCreateInfo& ci) {
    image_ci = ci;
}

Image::Image(const Vulkan::Instance&, Vulkan::Runtime& runtime_,
             Common::SlotVector<ImageView>& slot_image_views_, const ImageInfo& info_)
    : guest_begin{info_.guest_address}, guest_end{info_.guest_address + info_.guest_size},
      info{info_}, runtime{&runtime_}, slot_image_views{&slot_image_views_} {
    if (info.pixel_format == vk::Format::eUndefined) {
        return;
    }
    image_uid = global_image_uid.Next();
    mip_hashes.resize(info.resources.levels);
    const Metal::FormatInfo& f = Metal::GetFormat(info.pixel_format);
    usage_flags = vk::ImageUsageFlagBits::eTransferSrc | vk::ImageUsageFlagBits::eTransferDst |
                  vk::ImageUsageFlagBits::eSampled;
    if (f.depth || f.stencil) {
        usage_flags |= vk::ImageUsageFlagBits::eDepthStencilAttachment;
        aspect_mask = f.depth ? vk::ImageAspectFlagBits::eDepth : vk::ImageAspectFlags{};
        if (f.stencil) {
            aspect_mask |= vk::ImageAspectFlagBits::eStencil;
        }
    } else if (f.renderable) {
        usage_flags |= vk::ImageUsageFlagBits::eColorAttachment;
    }
    if (f.writable) {
        usage_flags |= vk::ImageUsageFlagBits::eStorage;
    }
    supported_samples = vk::SampleCountFlagBits::e1 | vk::SampleCountFlagBits::e2 |
                        vk::SampleCountFlagBits::e4 | vk::SampleCountFlagBits::e8;

    backing = &backing_images.emplace_back();
    backing->num_samples = info.num_samples;
    id<MTLTexture> texture = Metal::NewTexture(*this, info.num_samples);
    backing->image.image = Metal::MtlOwn<vk::Image>(texture);
    backing->image.size_bytes = texture ? texture.allocatedSize : 0;
    if (texture) {
        texture.label = [NSString stringWithFormat:@"Image %ux%ux%u %s %#llx", info.size.width,
                                                   info.size.height, info.size.depth,
                                                   vk::to_string(info.pixel_format).c_str(),
                                                   (unsigned long long)info.guest_address];
    }
}

Image::~Image() = default;

ImageView& Image::FindView(const ImageViewInfo& view_info, bool ensure_guest_samples) {
    if (ensure_guest_samples && (backing->num_samples > 1) != (info.num_samples > 1)) {
        runtime->SetBackingSamples(this, info.num_samples);
    }
    const auto& view_infos = backing->image_view_infos;
    if (backing->last_view < view_infos.size() && view_infos[backing->last_view] == view_info) {
        return (*slot_image_views)[backing->image_view_ids[backing->last_view]];
    }
    const auto it = std::ranges::find(view_infos, view_info);
    if (it != view_infos.end()) {
        backing->last_view = static_cast<u32>(std::distance(view_infos.begin(), it));
        return (*slot_image_views)[backing->image_view_ids[backing->last_view]];
    }
    const auto view_id = slot_image_views->insert(runtime->GetInstance(), view_info, *this);
    backing->image_view_infos.emplace_back(view_info);
    backing->image_view_ids.emplace_back(view_id);
    backing->last_view = static_cast<u32>(backing->image_view_ids.size() - 1);
    return (*slot_image_views)[view_id];
}

void Image::GetBarriers(Barriers&, vk::ImageLayout dst_layout, vk::AccessFlags2 dst_mask,
                        vk::PipelineStageFlags2 dst_stage, std::optional<SubresourceRange>) {
    backing->state.layout = dst_layout;
    backing->state.access_mask = dst_mask;
    backing->state.pl_stage = dst_stage;
}

// Samplers.

namespace {

MTLSamplerAddressMode AddressMode(vk::SamplerAddressMode mode) {
    switch (mode) {
    case vk::SamplerAddressMode::eRepeat:
        return MTLSamplerAddressModeRepeat;
    case vk::SamplerAddressMode::eMirroredRepeat:
        return MTLSamplerAddressModeMirrorRepeat;
    case vk::SamplerAddressMode::eClampToBorder:
        return MTLSamplerAddressModeClampToBorderColor;
    case vk::SamplerAddressMode::eMirrorClampToEdge:
        return MTLSamplerAddressModeMirrorClampToEdge;
    default:
        return MTLSamplerAddressModeClampToEdge;
    }
}

MTLCompareFunction CompareFunction(vk::CompareOp op) {
    switch (op) {
    case vk::CompareOp::eNever:
        return MTLCompareFunctionNever;
    case vk::CompareOp::eLess:
        return MTLCompareFunctionLess;
    case vk::CompareOp::eEqual:
        return MTLCompareFunctionEqual;
    case vk::CompareOp::eLessOrEqual:
        return MTLCompareFunctionLessEqual;
    case vk::CompareOp::eGreater:
        return MTLCompareFunctionGreater;
    case vk::CompareOp::eNotEqual:
        return MTLCompareFunctionNotEqual;
    case vk::CompareOp::eGreaterOrEqual:
        return MTLCompareFunctionGreaterEqual;
    default:
        return MTLCompareFunctionAlways;
    }
}

} // namespace

Sampler::Sampler(const Vulkan::Instance& instance, const AmdGpu::Sampler& sampler,
                 const AmdGpu::BorderColorBuffer border_color_base, const bool is_depth, float) {
    using namespace Vulkan;
    MTLSamplerDescriptor* desc = [MTLSamplerDescriptor new];
    desc.magFilter = LiverpoolToVK::Filter(sampler.xy_mag_filter) == vk::Filter::eLinear
                         ? MTLSamplerMinMagFilterLinear
                         : MTLSamplerMinMagFilterNearest;
    desc.minFilter = LiverpoolToVK::Filter(sampler.xy_min_filter) == vk::Filter::eLinear
                         ? MTLSamplerMinMagFilterLinear
                         : MTLSamplerMinMagFilterNearest;
    desc.mipFilter = LiverpoolToVK::MipFilter(sampler.mip_filter) == vk::SamplerMipmapMode::eLinear
                         ? MTLSamplerMipFilterLinear
                         : MTLSamplerMipFilterNearest;
    desc.sAddressMode = AddressMode(LiverpoolToVK::ClampMode(sampler.clamp_x));
    desc.tAddressMode = AddressMode(LiverpoolToVK::ClampMode(sampler.clamp_y));
    desc.rAddressMode = AddressMode(LiverpoolToVK::ClampMode(sampler.clamp_z));
    const bool aniso = AmdGpu::IsAnisoFilter(sampler.xy_mag_filter) ||
                       AmdGpu::IsAnisoFilter(sampler.xy_min_filter);
    desc.maxAnisotropy =
        aniso ? NSUInteger(std::clamp(sampler.MaxAniso(), 1.0f, instance.MaxSamplerAnisotropy()))
              : 1;
    if (is_depth) {
        desc.compareFunction = CompareFunction(LiverpoolToVK::DepthCompare(sampler.depth_compare_func));
    }
    desc.lodMinClamp = sampler.MinLod();
    desc.lodMaxClamp = std::max(sampler.MaxLod(), sampler.MinLod());
    {
        static std::atomic<u32> logged{0};
        const auto bc = LiverpoolToVK::BorderColor(sampler.border_color_type);
        if (bc == vk::BorderColor::eFloatCustomEXT && logged.fetch_add(1) < 8) {
            const auto* colors = border_color_base.Address<std::array<float, 4>*>();
            const auto c = colors ? colors[sampler.border_color_ptr.Value()] : std::array<float, 4>{};
            std::printf("GPU (Metal): custom border color %.2f %.2f %.2f %.2f (compare %d)\n", c[0],
                        c[1], c[2], c[3], int(is_depth));
        }
    }
    switch (LiverpoolToVK::BorderColor(sampler.border_color_type)) {
    case vk::BorderColor::eFloatOpaqueWhite:
    case vk::BorderColor::eIntOpaqueWhite:
        desc.borderColor = MTLSamplerBorderColorOpaqueWhite;
        break;
    case vk::BorderColor::eFloatOpaqueBlack:
    case vk::BorderColor::eIntOpaqueBlack:
        desc.borderColor = MTLSamplerBorderColorOpaqueBlack;
        break;
    default:
        desc.borderColor = MTLSamplerBorderColorTransparentBlack;
        break;
    }
    desc.normalizedCoordinates = YES;
    desc.supportArgumentBuffers = YES;
    id<MTLSamplerState> state = [Metal::Device() newSamplerStateWithDescriptor:desc];
    ASSERT_MSG(state, "Metal sampler creation failed");
    handle = vk::UniqueSampler{Metal::MtlOwn<vk::Sampler>(state)};
}

Sampler::~Sampler() {
    vk::Sampler raw = handle.release();
    Metal::MtlFree(raw);
}

} // namespace VideoCore

namespace Vulkan {

void Runtime::SetBackingSamples(VideoCore::Image* image, u32 num_samples, bool) {
    if (image->backing->num_samples == num_samples) {
        return;
    }
    for (auto& backing : image->backing_images) {
        if (backing.num_samples == num_samples) {
            image->backing = &backing;
            return;
        }
    }
    static std::atomic<u32> logged{0};
    if (logged.fetch_add(1) < 16) {
        std::printf("GPU (Metal): %u-sample backing for a %u-sample image (contents not "
                    "converted)\n",
                    num_samples, image->info.num_samples);
    }
    auto& backing = image->backing_images.emplace_back();
    backing.num_samples = num_samples;
    backing.state = image->backing->state;
    id<MTLTexture> texture = Metal::NewTexture(*image, num_samples);
    backing.image.image = Metal::MtlOwn<vk::Image>(texture);
    backing.image.size_bytes = texture ? texture.allocatedSize : 0;
    image->backing = &backing;
}

} // namespace Vulkan
