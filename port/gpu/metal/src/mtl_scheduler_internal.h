// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: scheduler helpers for the renderer's Objective-C++ sources.

#pragma once

#include <cstdlib>
#include <string>

#include "video_core/renderer_vulkan/vk_scheduler.h"

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

namespace Vulkan::MetalScheduler {

/// The open encoder writes guest memory (the untracked buffer): the next encoder waits for it.
void NoteUntrackedWrite(Scheduler& scheduler);

/// tlg: compute encoders dispatch concurrently, as a GCN queue runs dispatches that no barrier
/// packet separates (98% of inFAMOUS's ~18000 compute dispatches a second; burning road 20 -> 28
/// FPS, cannery 24 -> 30). TLG_METAL_CONCURRENT_DISPATCH=0: serial, as before. The guest's dispatches wait for the earlier
/// ones only after such a packet (BeforeGuestDispatch); the renderer's own kernels after all
/// earlier work, and the next dispatch after them (BeforeInternalDispatch).
bool ConcurrentDispatch();
#ifdef __OBJC__
void BeforeGuestDispatch(Scheduler& scheduler, id<MTLComputeCommandEncoder> enc, bool guest_barrier);
void BeforeInternalDispatch(Scheduler& scheduler, id<MTLComputeCommandEncoder> enc);
#endif

/// Profiling (TLG_METAL_PASS_STATS=1): counts why render passes end, by `why`; counted only while a render encoder is open.
bool PassStatsEnabled();
void NoteRenderBreak(Scheduler& scheduler, const char* why);
/// The counts since the last call, as " why:count" pairs (most frequent first), then reset.
std::string TakeRenderBreaks();

#ifdef __OBJC__
inline id<MTLCommandBuffer> CommandBuffer(Scheduler& s) {
    return (__bridge id<MTLCommandBuffer>)s.CommandBuffer();
}
inline id<MTLComputeCommandEncoder> Compute(Scheduler& s) {
    return (__bridge id<MTLComputeCommandEncoder>)s.ComputeEncoder();
}
/// Profiling (TLG_METAL_LABEL=1): each compute job gets an encoder of its own named `label`,
/// for Metal System Trace. Returns the encoder to use.
inline bool LabelMode() {
    static const bool on = [] {
        const char* env = std::getenv("TLG_METAL_LABEL");
        return env && env[0] == '1';
    }();
    return on;
}
/// The renderer's own compute work (a barrier before and after it with concurrent dispatch).
inline id<MTLComputeCommandEncoder> ComputeEncoderFor(Scheduler& s, const char* label) {
    if (PassStatsEnabled()) {
        NoteRenderBreak(s, label);
    }
    if (!LabelMode()) {
        return Compute(s);
    }
    s.EndEncoding();
    id<MTLComputeCommandEncoder> enc = Compute(s);
    enc.label = [NSString stringWithUTF8String:label];
    return enc;
}
inline id<MTLComputeCommandEncoder> Compute(Scheduler& s, const char* label) {
    id<MTLComputeCommandEncoder> enc = ComputeEncoderFor(s, label);
    BeforeInternalDispatch(s, enc);
    return enc;
}
/// A guest dispatch: waits for the earlier dispatches only after a guest barrier packet.
inline id<MTLComputeCommandEncoder> ComputeGuest(Scheduler& s, const char* label, bool guest_barrier) {
    id<MTLComputeCommandEncoder> enc = ComputeEncoderFor(s, label);
    BeforeGuestDispatch(s, enc, guest_barrier);
    return enc;
}
inline id<MTLBlitCommandEncoder> Blit(Scheduler& s, const char* label = "blit") {
    if (PassStatsEnabled()) {
        NoteRenderBreak(s, label);
    }
    return (__bridge id<MTLBlitCommandEncoder>)s.BlitEncoder();
}
inline id<MTLRenderCommandEncoder> Render(Scheduler& s) {
    return (__bridge id<MTLRenderCommandEncoder>)s.CurrentRenderEncoder();
}
#endif

} // namespace Vulkan::MetalScheduler
