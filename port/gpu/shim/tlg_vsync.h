// SPDX-License-Identifier: GPL-2.0-or-later
// tlg: the real display refresh, for the emulated vblank. The PS4's vblank is the display's;
// ours was a free-running 60 Hz timer that drifts against the display, so a flip close to a
// real refresh reached the screen one refresh late now and then (a picture held 3 vblanks, the
// next 1: judder in 30 FPS cutscenes). A presenter that knows when its frames reached the
// screen (Metal: MTLDrawable presentedTime) calls NotePresented; the vblank thread then ticks
// TLG_VSYNC_LEAD_US (default 6000) before a real refresh. Nothing calls it on Vulkan: the
// timer stays as it was. TLG_VSYNC_LOCK=0 turns it off.
#pragma once

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>

namespace TlgVsync {

inline std::atomic<int64_t> last_refresh_ns{0}; ///< steady_clock time of a recent refresh
inline std::atomic<int64_t> refresh_period_ns{0};

inline bool Enabled() {
    static const bool enabled = [] {
        const char* env = std::getenv("TLG_VSYNC_LOCK");
        return !(env && env[0] == '0');
    }();
    return enabled;
}

inline std::chrono::nanoseconds Lead() {
    static const std::chrono::nanoseconds lead = [] {
        const char* env = std::getenv("TLG_VSYNC_LEAD_US");
        return std::chrono::microseconds(env ? std::atol(env) : 6000);
    }();
    return lead;
}

/// A frame reached the screen at `ns` (steady_clock nanoseconds); `period_ns` is the display's
/// refresh period.
inline void NotePresented(int64_t ns, int64_t period_ns) {
    if (ns > 0 && period_ns > 0) {
        refresh_period_ns.store(period_ns, std::memory_order_relaxed);
        last_refresh_ns.store(ns, std::memory_order_relaxed);
    }
}

/// The vblank tick after `previous` for an emulated `period`, `Lead()` before a real refresh;
/// false while no refresh is known (keep the timer).
inline bool NextTick(std::chrono::steady_clock::time_point previous,
                     std::chrono::nanoseconds period, std::chrono::steady_clock::time_point& out) {
    if (!Enabled()) {
        return false;
    }
    const int64_t phase = last_refresh_ns.load(std::memory_order_relaxed);
    const int64_t display = refresh_period_ns.load(std::memory_order_relaxed);
    const int64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(
                            std::chrono::steady_clock::now().time_since_epoch())
                            .count();
    // Stale (window hidden, presents dropped): fall back to the timer.
    if (!phase || !display || now - phase > 2'000'000'000) {
        return false;
    }
    const int64_t lead = Lead().count();
    const int64_t prev = std::chrono::duration_cast<std::chrono::nanoseconds>(
                             previous.time_since_epoch())
                             .count();
    // The real refresh nearest to one emulated period after the previous tick (plus the lead).
    const int64_t desired = prev + period.count() + lead;
    int64_t k = std::llround(double(desired - phase) / double(display));
    int64_t tick = phase + k * display - lead;
    // Never tick twice for one emulated period, and never schedule into the past.
    while (tick < prev + period.count() / 2 || tick < now - display) {
        ++k;
        tick = phase + k * display - lead;
    }
    out = std::chrono::steady_clock::time_point(std::chrono::nanoseconds(tick));
    return true;
}

} // namespace TlgVsync
