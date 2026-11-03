// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the overlay's ImGui Metal backend.

#include "imgui.h"
#include "imgui_impl_metal.h"
#include "mtl_objc.h"
#include "mtl_overlay.h"

namespace TlgOverlayMetal {

namespace {
MTLRenderPassDescriptor* g_pass = nil;
}

bool Init(void* device) {
    return ImGui_ImplMetal_Init((__bridge id<MTLDevice>)device);
}

void NewFrame(void*, void* texture) {
    g_pass = [MTLRenderPassDescriptor renderPassDescriptor];
    g_pass.colorAttachments[0].texture = (__bridge id<MTLTexture>)texture;
    g_pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    g_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    ImGui_ImplMetal_NewFrame(g_pass);
}

void RenderDrawData(void* cmdbuf, ImDrawData* draw_data) {
    if (!g_pass || !draw_data) {
        return;
    }
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cmdbuf;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:g_pass];
    enc.label = @"Overlay";
    ImGui_ImplMetal_RenderDrawData(draw_data, cb, enc);
    [enc endEncoding];
    g_pass = nil;
}

} // namespace TlgOverlayMetal
