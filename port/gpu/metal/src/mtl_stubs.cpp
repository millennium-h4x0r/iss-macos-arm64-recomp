// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: statistics the VideoOut driver reads (Vulkan renderer counters; the Metal
// renderer fills the ones that apply).

#include <atomic>

#include "common/types.h"

namespace Vulkan {
std::atomic<u64> g_tlg_compile_ns{0};
std::atomic<u32> g_tlg_compiles{0};
std::atomic<u64> g_tlg_capture_ns{0}, g_tlg_async_ns{0}, g_tlg_compile_wait_ns{0};
std::atomic<u64> g_tlg_snapshot_ns{0}, g_tlg_guest_wait_ns{0};
std::atomic<u32> g_tlg_pending_draws{0};
std::atomic<u64> g_tlg_frames_ahead_wait_ns{0}, g_tlg_free_frame_wait_ns{0};
std::atomic<u64> g_tlg_present_lock_wait_ns{0};
std::atomic<int> g_tlg_recorder_cpu_clock{0};
std::atomic<u32> g_tlg_recorder_cpu_tid{0};
std::atomic<u64> g_tlg_recorder_spin_ns{0};
} // namespace Vulkan
