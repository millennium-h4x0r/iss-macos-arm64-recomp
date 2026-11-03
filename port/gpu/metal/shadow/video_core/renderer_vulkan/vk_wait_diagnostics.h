// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: wait diagnostics (Vulkan renderer) are not available.
#pragma once
#include "common/types.h"
namespace Vulkan::WaitDiagnostics {
inline bool Enabled() {
    return false;
}
inline void Report() {}
template <typename... Args>
inline void Note(Args&&...) {}
} // namespace Vulkan::WaitDiagnostics
