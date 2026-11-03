// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the overlay's ImGui Metal backend (tlg_overlay.cpp, TLG_METAL).

#pragma once

struct ImDrawData;

namespace TlgOverlayMetal {

/// device: id<MTLDevice>.
bool Init(void* device);
/// Starts an ImGui frame drawn into `texture` (id<MTLTexture>) on `cmdbuf` (id<MTLCommandBuffer>).
void NewFrame(void* cmdbuf, void* texture);
/// Encodes the frame (a render pass loading the texture).
void RenderDrawData(void* cmdbuf, ImDrawData* draw_data);

} // namespace TlgOverlayMetal
