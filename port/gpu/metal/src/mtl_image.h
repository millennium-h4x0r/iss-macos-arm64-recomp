// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: texture views for the shared image view code.

#pragma once

#include "video_core/renderer_vulkan/vk_common.h"

namespace VideoCore {
struct Image;
struct ImageViewInfo;
} // namespace VideoCore

namespace Metal {

/// A Metal view of `image` (a +1 reference in the returned handle).
vk::UniqueImageView CreateImageView(const VideoCore::Image& image,
                                    const VideoCore::ImageViewInfo& info, vk::Format format,
                                    vk::ImageAspectFlags aspect, vk::ImageViewType view_type);
void DestroyImageView(vk::UniqueImageView& view);

} // namespace Metal
