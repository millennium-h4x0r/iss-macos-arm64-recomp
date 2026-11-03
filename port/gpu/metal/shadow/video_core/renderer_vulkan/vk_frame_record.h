// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: frame recording (Vulkan renderer diagnostics) is not available.
#pragma once
#include "common/types.h"
namespace Vulkan::FrameRecord {
inline bool Active() {
    return false;
}
inline bool IsRecording() {
    return false;
}
template <typename... Args>
inline void Packet(Args&&...) {}
template <typename... Args>
inline void OnFlip(Args&&...) {}
} // namespace Vulkan::FrameRecord
