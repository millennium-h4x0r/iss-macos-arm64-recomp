// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: Vulkan formats (the texture cache's vocabulary) to Metal pixel formats.

#pragma once

#include "common/types.h"
#include "video_core/renderer_vulkan/vk_common.h"

namespace Metal {

struct FormatInfo {
    u32 metal = 0;       ///< MTLPixelFormat (0 = MTLPixelFormatInvalid)
    u32 block_width = 1; ///< texels per block (4 for BC)
    u32 block_height = 1;
    u32 block_bytes = 0; ///< bytes per block (per texel when not compressed)
    bool depth = false;
    bool stencil = false;
    bool compressed = false;
    bool srgb = false;
    bool renderable = true;
    bool writable = true; ///< shader writes (MTLTextureUsageShaderWrite)
};

/// Metal equivalent of a Vulkan format; .metal is 0 when Metal has none.
const FormatInfo& GetFormat(vk::Format format);

/// Bytes of one row of `width` texels (whole blocks).
inline u64 RowBytes(const FormatInfo& f, u32 width) {
    return u64((width + f.block_width - 1) / f.block_width) * f.block_bytes;
}

/// Rows of blocks in `height` texels.
inline u32 BlockRows(const FormatInfo& f, u32 height) {
    return (height + f.block_height - 1) / f.block_height;
}

} // namespace Metal
