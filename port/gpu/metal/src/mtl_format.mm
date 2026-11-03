// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: Vulkan format -> Metal pixel format table (MoltenVK's mapping where
// Metal has the format; scaled formats as their integer forms; formats Metal lacks are 0).

#include <array>
#include <mutex>
#include <unordered_map>

#include "mtl_format.h"
#include "mtl_objc.h"

namespace Metal {

namespace {

struct Entry {
    vk::Format vk;
    MTLPixelFormat mtl;
    u32 bw, bh, bytes;
    bool depth = false, stencil = false;
};

#define C(vkf, mtlf, bytes) {vk::Format::vkf, MTLPixelFormat##mtlf, 1, 1, bytes}
#define B(vkf, mtlf, bytes) {vk::Format::vkf, MTLPixelFormat##mtlf, 4, 4, bytes}
#define D(vkf, mtlf, bytes, s) {vk::Format::vkf, MTLPixelFormat##mtlf, 1, 1, bytes, true, s}

const Entry kEntries[] = {
    C(eR8Unorm, R8Unorm, 1), C(eR8Snorm, R8Snorm, 1), C(eR8Uint, R8Uint, 1),
    C(eR8Sint, R8Sint, 1), C(eR8Srgb, R8Unorm_sRGB, 1), C(eR8Uscaled, R8Uint, 1),
    C(eR8Sscaled, R8Sint, 1),
    C(eR8G8Unorm, RG8Unorm, 2), C(eR8G8Snorm, RG8Snorm, 2), C(eR8G8Uint, RG8Uint, 2),
    C(eR8G8Sint, RG8Sint, 2), C(eR8G8Srgb, RG8Unorm_sRGB, 2), C(eR8G8Uscaled, RG8Uint, 2),
    C(eR8G8Sscaled, RG8Sint, 2),
    C(eR8G8B8A8Unorm, RGBA8Unorm, 4), C(eR8G8B8A8Snorm, RGBA8Snorm, 4),
    C(eR8G8B8A8Uint, RGBA8Uint, 4), C(eR8G8B8A8Sint, RGBA8Sint, 4),
    C(eR8G8B8A8Srgb, RGBA8Unorm_sRGB, 4), C(eR8G8B8A8Uscaled, RGBA8Uint, 4),
    C(eR8G8B8A8Sscaled, RGBA8Sint, 4),
    C(eA8B8G8R8UnormPack32, RGBA8Unorm, 4), C(eA8B8G8R8SnormPack32, RGBA8Snorm, 4),
    C(eA8B8G8R8UintPack32, RGBA8Uint, 4), C(eA8B8G8R8SintPack32, RGBA8Sint, 4),
    C(eA8B8G8R8SrgbPack32, RGBA8Unorm_sRGB, 4), C(eA8B8G8R8UscaledPack32, RGBA8Uint, 4),
    C(eA8B8G8R8SscaledPack32, RGBA8Sint, 4),
    C(eB8G8R8A8Unorm, BGRA8Unorm, 4), C(eB8G8R8A8Srgb, BGRA8Unorm_sRGB, 4),
    C(eB8G8R8A8Snorm, RGBA8Snorm, 4), C(eB8G8R8A8Uint, RGBA8Uint, 4),
    C(eB8G8R8A8Sint, RGBA8Sint, 4), C(eB8G8R8A8Uscaled, RGBA8Uint, 4),
    C(eB8G8R8A8Sscaled, RGBA8Sint, 4),
    C(eA2B10G10R10UnormPack32, RGB10A2Unorm, 4), C(eA2B10G10R10UintPack32, RGB10A2Uint, 4),
    C(eA2B10G10R10SnormPack32, RGB10A2Unorm, 4), C(eA2B10G10R10SintPack32, RGB10A2Uint, 4),
    C(eA2B10G10R10UscaledPack32, RGB10A2Uint, 4), C(eA2B10G10R10SscaledPack32, RGB10A2Uint, 4),
    C(eA2R10G10B10UnormPack32, BGR10A2Unorm, 4), C(eA2R10G10B10UintPack32, RGB10A2Uint, 4),
    C(eA2R10G10B10SnormPack32, BGR10A2Unorm, 4), C(eA2R10G10B10SintPack32, RGB10A2Uint, 4),
    C(eA2R10G10B10UscaledPack32, RGB10A2Uint, 4), C(eA2R10G10B10SscaledPack32, RGB10A2Uint, 4),
    C(eB10G11R11UfloatPack32, RG11B10Float, 4), C(eE5B9G9R9UfloatPack32, RGB9E5Float, 4),
    C(eR16Unorm, R16Unorm, 2), C(eR16Snorm, R16Snorm, 2), C(eR16Uint, R16Uint, 2),
    C(eR16Sint, R16Sint, 2), C(eR16Sfloat, R16Float, 2), C(eR16Uscaled, R16Uint, 2),
    C(eR16Sscaled, R16Sint, 2),
    C(eR16G16Unorm, RG16Unorm, 4), C(eR16G16Snorm, RG16Snorm, 4), C(eR16G16Uint, RG16Uint, 4),
    C(eR16G16Sint, RG16Sint, 4), C(eR16G16Sfloat, RG16Float, 4), C(eR16G16Uscaled, RG16Uint, 4),
    C(eR16G16Sscaled, RG16Sint, 4),
    C(eR16G16B16A16Unorm, RGBA16Unorm, 8), C(eR16G16B16A16Snorm, RGBA16Snorm, 8),
    C(eR16G16B16A16Uint, RGBA16Uint, 8), C(eR16G16B16A16Sint, RGBA16Sint, 8),
    C(eR16G16B16A16Sfloat, RGBA16Float, 8), C(eR16G16B16A16Uscaled, RGBA16Uint, 8),
    C(eR16G16B16A16Sscaled, RGBA16Sint, 8),
    C(eR32Uint, R32Uint, 4), C(eR32Sint, R32Sint, 4), C(eR32Sfloat, R32Float, 4),
    C(eR32G32Uint, RG32Uint, 8), C(eR32G32Sint, RG32Sint, 8), C(eR32G32Sfloat, RG32Float, 8),
    C(eR32G32B32A32Uint, RGBA32Uint, 16), C(eR32G32B32A32Sint, RGBA32Sint, 16),
    C(eR32G32B32A32Sfloat, RGBA32Float, 16),
    // 64-bit channels: raw storage of the same size.
    C(eR64Uint, RG32Uint, 8), C(eR64Sint, RG32Uint, 8), C(eR64Sfloat, RG32Uint, 8),
    C(eR64G64Uint, RGBA32Uint, 16), C(eR64G64Sint, RGBA32Uint, 16),
    C(eR64G64Sfloat, RGBA32Uint, 16),
    C(eB5G6R5UnormPack16, B5G6R5Unorm, 2), C(eR5G6B5UnormPack16, B5G6R5Unorm, 2),
    C(eA1R5G5B5UnormPack16, A1BGR5Unorm, 2), C(eR5G5B5A1UnormPack16, BGR5A1Unorm, 2),
    C(eB5G5R5A1UnormPack16, BGR5A1Unorm, 2),
    C(eR4G4B4A4UnormPack16, ABGR4Unorm, 2), C(eB4G4R4A4UnormPack16, ABGR4Unorm, 2),
    C(eA4R4G4B4UnormPack16, ABGR4Unorm, 2), C(eA4B4G4R4UnormPack16, ABGR4Unorm, 2),
    C(eR4G4UnormPack8, R8Unorm, 1),
    C(eR10X6UnormPack16, R16Unorm, 2), C(eR12X4UnormPack16, R16Unorm, 2),
    C(eR10X6G10X6Unorm2Pack16, RG16Unorm, 4), C(eR12X4G12X4Unorm2Pack16, RG16Unorm, 4),
    B(eBc1RgbUnormBlock, BC1_RGBA, 8), B(eBc1RgbSrgbBlock, BC1_RGBA_sRGB, 8),
    B(eBc1RgbaUnormBlock, BC1_RGBA, 8), B(eBc1RgbaSrgbBlock, BC1_RGBA_sRGB, 8),
    B(eBc2UnormBlock, BC2_RGBA, 16), B(eBc2SrgbBlock, BC2_RGBA_sRGB, 16),
    B(eBc3UnormBlock, BC3_RGBA, 16), B(eBc3SrgbBlock, BC3_RGBA_sRGB, 16),
    B(eBc4UnormBlock, BC4_RUnorm, 8), B(eBc4SnormBlock, BC4_RSnorm, 8),
    B(eBc5UnormBlock, BC5_RGUnorm, 16), B(eBc5SnormBlock, BC5_RGSnorm, 16),
    B(eBc6HUfloatBlock, BC6H_RGBUfloat, 16), B(eBc6HSfloatBlock, BC6H_RGBFloat, 16),
    B(eBc7UnormBlock, BC7_RGBAUnorm, 16), B(eBc7SrgbBlock, BC7_RGBAUnorm_sRGB, 16),
    // Apple GPUs have no 24-bit depth: D24 formats become 32-bit float depth.
    D(eD16Unorm, Depth16Unorm, 2, false), D(eD32Sfloat, Depth32Float, 4, false),
    D(eX8D24UnormPack32, Depth32Float, 4, false),
    D(eD32SfloatS8Uint, Depth32Float_Stencil8, 8, true),
    D(eD24UnormS8Uint, Depth32Float_Stencil8, 8, true),
    D(eD16UnormS8Uint, Depth32Float_Stencil8, 8, true),
    {vk::Format::eS8Uint, MTLPixelFormatStencil8, 1, 1, 1, false, true},
};

#undef C
#undef B
#undef D

/// Bytes per texel of the Vulkan formats Metal lacks (3-component ones), for raw copies.
u32 FallbackBytes(vk::Format format) {
    switch (format) {
    case vk::Format::eR8G8B8Unorm: case vk::Format::eR8G8B8Snorm: case vk::Format::eR8G8B8Uint:
    case vk::Format::eR8G8B8Sint: case vk::Format::eR8G8B8Srgb: case vk::Format::eR8G8B8Uscaled:
    case vk::Format::eR8G8B8Sscaled: case vk::Format::eB8G8R8Unorm: case vk::Format::eB8G8R8Snorm:
    case vk::Format::eB8G8R8Uint: case vk::Format::eB8G8R8Sint: case vk::Format::eB8G8R8Srgb:
    case vk::Format::eB8G8R8Uscaled: case vk::Format::eB8G8R8Sscaled:
        return 3;
    case vk::Format::eR16G16B16Unorm: case vk::Format::eR16G16B16Snorm:
    case vk::Format::eR16G16B16Uint: case vk::Format::eR16G16B16Sint:
    case vk::Format::eR16G16B16Sfloat: case vk::Format::eR16G16B16Uscaled:
    case vk::Format::eR16G16B16Sscaled:
        return 6;
    case vk::Format::eR32G32B32Uint: case vk::Format::eR32G32B32Sint:
    case vk::Format::eR32G32B32Sfloat:
        return 12;
    case vk::Format::eR64G64B64Uint: case vk::Format::eR64G64B64Sint:
    case vk::Format::eR64G64B64Sfloat:
        return 24;
    case vk::Format::eR64G64B64A64Uint: case vk::Format::eR64G64B64A64Sint:
    case vk::Format::eR64G64B64A64Sfloat:
        return 32;
    default:
        return 4;
    }
}

bool IsSrgb(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatR8Unorm_sRGB: case MTLPixelFormatRG8Unorm_sRGB:
    case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatBC1_RGBA_sRGB: case MTLPixelFormatBC2_RGBA_sRGB:
    case MTLPixelFormatBC3_RGBA_sRGB: case MTLPixelFormatBC7_RGBAUnorm_sRGB:
        return true;
    default:
        return false;
    }
}

bool IsRenderable(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatRGB9E5Float: // renderable on Apple GPUs, not writable
        return true;
    case MTLPixelFormatR8Snorm: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRGBA8Snorm:
    case MTLPixelFormatR16Snorm: case MTLPixelFormatRG16Snorm: case MTLPixelFormatRGBA16Snorm:
        return true;
    default:
        return true;
    }
}

} // namespace

const FormatInfo& GetFormat(vk::Format format) {
    static std::mutex mutex;
    static std::unordered_map<u32, FormatInfo> table;
    std::scoped_lock lock{mutex};
    if (table.empty()) {
        for (const Entry& e : kEntries) {
            FormatInfo info{};
            info.metal = static_cast<u32>(e.mtl);
            info.block_width = e.bw;
            info.block_height = e.bh;
            info.block_bytes = e.bytes;
            info.depth = e.depth;
            info.stencil = e.stencil;
            info.compressed = e.bw > 1;
            info.srgb = IsSrgb(e.mtl);
            info.renderable = !info.compressed && IsRenderable(e.mtl);
            info.writable = !info.compressed && !info.depth && !info.stencil && !info.srgb &&
                            e.mtl != MTLPixelFormatRGB9E5Float &&
                            e.mtl != MTLPixelFormatB5G6R5Unorm &&
                            e.mtl != MTLPixelFormatA1BGR5Unorm &&
                            e.mtl != MTLPixelFormatBGR5A1Unorm &&
                            e.mtl != MTLPixelFormatABGR4Unorm;
            table.emplace(static_cast<u32>(e.vk), info);
        }
    }
    if (const auto it = table.find(static_cast<u32>(format)); it != table.end()) {
        return it->second;
    }
    FormatInfo info{};
    info.block_bytes = format == vk::Format::eUndefined ? 0 : FallbackBytes(format);
    info.renderable = false;
    info.writable = false;
    return table.emplace(static_cast<u32>(format), info).first->second;
}

} // namespace Metal

namespace Vulkan {

/// Vertex attribute format of a buffer V# (as a Vulkan format, LiverpoolToVK::SurfaceFormat).
MTLVertexFormat VertexFormat(vk::Format format) {
    switch (format) {
    case vk::Format::eR8Unorm: return MTLVertexFormatUCharNormalized;
    case vk::Format::eR8Snorm: return MTLVertexFormatCharNormalized;
    case vk::Format::eR8Uint: case vk::Format::eR8Uscaled: return MTLVertexFormatUChar;
    case vk::Format::eR8Sint: case vk::Format::eR8Sscaled: return MTLVertexFormatChar;
    case vk::Format::eR8G8Unorm: return MTLVertexFormatUChar2Normalized;
    case vk::Format::eR8G8Snorm: return MTLVertexFormatChar2Normalized;
    case vk::Format::eR8G8Uint: case vk::Format::eR8G8Uscaled: return MTLVertexFormatUChar2;
    case vk::Format::eR8G8Sint: case vk::Format::eR8G8Sscaled: return MTLVertexFormatChar2;
    case vk::Format::eR8G8B8A8Unorm: case vk::Format::eA8B8G8R8UnormPack32: return MTLVertexFormatUChar4Normalized;
    case vk::Format::eR8G8B8A8Snorm: case vk::Format::eA8B8G8R8SnormPack32: return MTLVertexFormatChar4Normalized;
    case vk::Format::eR8G8B8A8Uint: case vk::Format::eR8G8B8A8Uscaled: case vk::Format::eA8B8G8R8UintPack32: return MTLVertexFormatUChar4;
    case vk::Format::eR8G8B8A8Sint: case vk::Format::eR8G8B8A8Sscaled: case vk::Format::eA8B8G8R8SintPack32: return MTLVertexFormatChar4;
    case vk::Format::eB8G8R8A8Unorm: return MTLVertexFormatUChar4Normalized_BGRA;
    case vk::Format::eR16Unorm: return MTLVertexFormatUShortNormalized;
    case vk::Format::eR16Snorm: return MTLVertexFormatShortNormalized;
    case vk::Format::eR16Uint: case vk::Format::eR16Uscaled: return MTLVertexFormatUShort;
    case vk::Format::eR16Sint: case vk::Format::eR16Sscaled: return MTLVertexFormatShort;
    case vk::Format::eR16Sfloat: return MTLVertexFormatHalf;
    case vk::Format::eR16G16Unorm: return MTLVertexFormatUShort2Normalized;
    case vk::Format::eR16G16Snorm: return MTLVertexFormatShort2Normalized;
    case vk::Format::eR16G16Uint: case vk::Format::eR16G16Uscaled: return MTLVertexFormatUShort2;
    case vk::Format::eR16G16Sint: case vk::Format::eR16G16Sscaled: return MTLVertexFormatShort2;
    case vk::Format::eR16G16Sfloat: return MTLVertexFormatHalf2;
    case vk::Format::eR16G16B16A16Unorm: return MTLVertexFormatUShort4Normalized;
    case vk::Format::eR16G16B16A16Snorm: return MTLVertexFormatShort4Normalized;
    case vk::Format::eR16G16B16A16Uint: case vk::Format::eR16G16B16A16Uscaled: return MTLVertexFormatUShort4;
    case vk::Format::eR16G16B16A16Sint: case vk::Format::eR16G16B16A16Sscaled: return MTLVertexFormatShort4;
    case vk::Format::eR16G16B16A16Sfloat: return MTLVertexFormatHalf4;
    case vk::Format::eR32Uint: return MTLVertexFormatUInt;
    case vk::Format::eR32Sint: return MTLVertexFormatInt;
    case vk::Format::eR32Sfloat: return MTLVertexFormatFloat;
    case vk::Format::eR32G32Uint: return MTLVertexFormatUInt2;
    case vk::Format::eR32G32Sint: return MTLVertexFormatInt2;
    case vk::Format::eR32G32Sfloat: return MTLVertexFormatFloat2;
    case vk::Format::eR32G32B32Uint: return MTLVertexFormatUInt3;
    case vk::Format::eR32G32B32Sint: return MTLVertexFormatInt3;
    case vk::Format::eR32G32B32Sfloat: return MTLVertexFormatFloat3;
    case vk::Format::eR32G32B32A32Uint: return MTLVertexFormatUInt4;
    case vk::Format::eR32G32B32A32Sint: return MTLVertexFormatInt4;
    case vk::Format::eR32G32B32A32Sfloat: return MTLVertexFormatFloat4;
    case vk::Format::eA2B10G10R10UnormPack32: return MTLVertexFormatUInt1010102Normalized;
    case vk::Format::eA2B10G10R10SnormPack32: return MTLVertexFormatInt1010102Normalized;
    case vk::Format::eB10G11R11UfloatPack32: return MTLVertexFormatFloatRG11B10;
    case vk::Format::eE5B9G9R9UfloatPack32: return MTLVertexFormatFloatRGB9E5;
    default: return MTLVertexFormatInvalid;
    }
}

} // namespace Vulkan
