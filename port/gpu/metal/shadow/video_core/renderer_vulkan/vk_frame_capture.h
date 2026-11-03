// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: frame capture (Vulkan renderer diagnostics) is not available.
#pragma once
#include "common/types.h"
namespace Vulkan::FrameCapture {
inline void Request() {}
template <typename... Args>
inline void AddDisplayBuffer(Args&&...) {}
template <typename... Args>
inline void OnFlip(Args&&...) {}
} // namespace Vulkan::FrameCapture
