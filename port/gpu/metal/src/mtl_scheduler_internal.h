// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: scheduler helpers for the renderer's Objective-C++ sources.

#pragma once

#include <cstdlib>

#include "video_core/renderer_vulkan/vk_scheduler.h"

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

namespace Vulkan::MetalScheduler {

/// The open encoder writes guest memory (the untracked buffer): the next encoder waits for it.
void NoteUntrackedWrite(Scheduler& scheduler);

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
inline id<MTLComputeCommandEncoder> Compute(Scheduler& s, const char* label) {
    if (!LabelMode()) {
        return Compute(s);
    }
    s.EndEncoding();
    id<MTLComputeCommandEncoder> enc = Compute(s);
    enc.label = [NSString stringWithUTF8String:label];
    return enc;
}
inline id<MTLBlitCommandEncoder> Blit(Scheduler& s) {
    return (__bridge id<MTLBlitCommandEncoder>)s.BlitEncoder();
}
inline id<MTLRenderCommandEncoder> Render(Scheduler& s) {
    return (__bridge id<MTLRenderCommandEncoder>)s.CurrentRenderEncoder();
}
#endif

} // namespace Vulkan::MetalScheduler
