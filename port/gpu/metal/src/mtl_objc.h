// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: Objective-C++ helpers (only for .mm files).
//
// Metal objects travel through the shared code in Vulkan handle fields (vk::Image holds an
// MTLTexture, vk::ImageView a texture view, vk::Buffer an MTLBuffer, vk::Sampler an
// MTLSamplerState, vk::CommandBuffer an MTLCommandBuffer). A handle owns one retain count:
// MtlOwn() stores a +1 reference in it, MtlFree() drops it, MtlGet() borrows it.

#pragma once

#ifndef __OBJC__
#error "mtl_objc.h is for Objective-C++ sources"
#endif

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "video_core/renderer_vulkan/vk_common.h"

namespace Metal {

template <typename Handle>
inline Handle MtlOwn(id object) {
    using C = typename Handle::CType;
    return Handle{object ? reinterpret_cast<C>((__bridge_retained void*)object) : C{}};
}

template <typename Handle>
inline void MtlFree(Handle& handle) {
    using C = typename Handle::CType;
    if (const C raw = static_cast<C>(handle)) {
        id object = (__bridge_transfer id)reinterpret_cast<void*>(raw);
        (void)object; // released at the end of the scope
        handle = Handle{};
    }
}

template <typename T, typename Handle>
inline T MtlGet(Handle handle) {
    using C = typename Handle::CType;
    const C raw = static_cast<C>(handle);
    return raw ? (__bridge T)reinterpret_cast<void*>(raw) : nil;
}

/// The object of a handle as a plain pointer, for per-draw code: `(__bridge id<...>)Raw(h)`
/// stored in an __unsafe_unretained variable costs no retain/release (the handle's owner keeps
/// the object alive). The typed accessors below return strong references.
template <typename Handle>
inline void* Raw(Handle handle) {
    return reinterpret_cast<void*>(static_cast<typename Handle::CType>(handle));
}

inline id<MTLTexture> Texture(vk::Image image) {
    return MtlGet<id<MTLTexture>>(image);
}
inline id<MTLTexture> Texture(vk::ImageView view) {
    return MtlGet<id<MTLTexture>>(view);
}
inline id<MTLBuffer> Buffer(vk::Buffer buffer) {
    return MtlGet<id<MTLBuffer>>(buffer);
}
inline id<MTLSamplerState> SamplerState(vk::Sampler sampler) {
    return MtlGet<id<MTLSamplerState>>(sampler);
}

/// The renderer's device (Instance creates it).
id<MTLDevice> Device();

} // namespace Metal
