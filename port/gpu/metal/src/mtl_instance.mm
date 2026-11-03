// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the device.

#include <cstdio>
#include <cstdlib>

#include "mtl_objc.h"
#include "video_core/amdgpu/tlg_bc_tiny.h"
#include "video_core/amdgpu/tlg_block1d.h"
#include "video_core/renderer_vulkan/vk_instance.h"

// The Vulkan-Hpp dispatcher the shared headers refer to (never loaded: nothing calls Vulkan).
VULKAN_HPP_DEFAULT_DISPATCH_LOADER_DYNAMIC_STORAGE

namespace Metal {

namespace {
id<MTLDevice> g_device = nil;
}

id<MTLDevice> Device() {
    if (!g_device) {
        g_device = MTLCreateSystemDefaultDevice();
    }
    return g_device;
}

} // namespace Metal

namespace Vulkan {

Instance::Instance(bool, bool) {
    Create();
}

Instance::Instance(Frontend::WindowSDL&, s32, bool, bool) {
    Create();
}

Instance::~Instance() {
    if (device) {
        id<MTLDevice> d = (__bridge_transfer id<MTLDevice>)device;
        (void)d;
        device = nullptr;
    }
}

void Instance::Create() {
    // Metal has no mipmapped or block-compressed 1D textures: every 1D image is a 2D image of
    // height 1, for images and shaders alike (set before any image or shader exists).
    AmdGpu::all_1d_as_2d.store(true, std::memory_order_relaxed);
    AmdGpu::block1d_as_2d.store(true, std::memory_order_relaxed);
    if (const char* bc_tiny = std::getenv("TLG_BC_TINY"); bc_tiny && *bc_tiny == '1') {
        AmdGpu::bc_tiny_decode.store(true, std::memory_order_relaxed);
        std::printf("GPU: tiny block-compressed textures decoded on the CPU (TLG_BC_TINY=1)\n");
    }
    id<MTLDevice> d = Metal::Device();
    device = (__bridge_retained void*)d;
    model_name = d.name.UTF8String;
    total_memory_budget = d.recommendedMaxWorkingSetSize;
    max_buffer_size = d.maxBufferLength;
    static bool logged = false;
    if (!logged) {
        logged = true;
        std::printf("GPU: Metal renderer on %s (working set %.1f GB, max buffer %.1f GB)\n",
                    model_name.c_str(), double(total_memory_budget) / (1ull << 30),
                    double(max_buffer_size) / (1ull << 30));
    }
}

u64 Instance::GetDeviceMemoryUsage() const {
    return ((__bridge id<MTLDevice>)device).currentAllocatedSize;
}

u64 Instance::GetDeviceMemoryBudgetNow() const {
    return ((__bridge id<MTLDevice>)device).recommendedMaxWorkingSetSize;
}

} // namespace Vulkan
