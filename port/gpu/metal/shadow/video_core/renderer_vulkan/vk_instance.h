// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: the GPU device (MTLDevice) behind the Vulkan renderer's Instance API, as
// far as the shared code (texture cache, overlay, statistics) uses it.

#pragma once

#include <memory>
#include <string>
#include <string_view>

#include "common/types.h"
#include "video_core/renderer_vulkan/vk_common.h"

namespace Frontend {
class WindowSDL;
}

namespace Vulkan {

class Instance {
public:
    explicit Instance(bool enable_validation = false, bool enable_crash_diagnostic = false);
    explicit Instance(Frontend::WindowSDL& window, s32 physical_device_index,
                      bool enable_validation = false, bool enable_crash_diagnostic = false);
    ~Instance();

    Instance(const Instance&) = delete;
    Instance& operator=(const Instance&) = delete;

    /// id<MTLDevice>, borrowed.
    void* MetalDevice() const noexcept {
        return device;
    }

    std::string_view GetModelName() const {
        return model_name;
    }

    bool IsIntegrated() const {
        return true;
    }
    bool CanReportMemoryUsage() const {
        return true;
    }
    /// Bytes the device has allocated (currentAllocatedSize).
    u64 GetDeviceMemoryUsage() const;
    /// The working set the device recommends (recommendedMaxWorkingSetSize).
    u64 GetDeviceMemoryBudgetNow() const;
    u64 GetTotalMemoryBudget() const {
        return total_memory_budget;
    }

    u32 GetMaxSamplerAllocationCount() const {
        return 2048;
    }
    float MaxSamplerLodBias() const {
        return 16.0f;
    }
    float MaxSamplerAnisotropy() const {
        return 16.0f;
    }
    bool IsAnisotropicFilteringSupported() const {
        return true;
    }
    /// Metal border colors are transparent black, opaque black and opaque white only.
    bool IsCustomBorderColorSupported() const {
        return false;
    }
    bool IsImageViewMinLodSupported() const {
        return false;
    }
    bool IsBlockTexelViewSupported() const {
        return false;
    }
    bool IsAttachmentFeedbackLoopLayoutSupported() const {
        return false;
    }
    bool Is2dViewOf3dSupported() const {
        return false;
    }
    bool HasExternalMemoryHost() const {
        return true;
    }

    /// Formats are chosen by the Metal format table (mtl_format.h); the Vulkan format stays the
    /// texture cache's key.
    vk::Format GetSupportedFormat(vk::Format format, vk::FormatFeatureFlags2) const {
        return format;
    }

    u64 UniformMinAlignment() const {
        return 16;
    }
    u64 StorageMinAlignment() const {
        return 4;
    }
    u64 NonCoherentAtomSize() const {
        return 1;
    }
    u64 GetMaxBufferSize() const {
        return max_buffer_size;
    }
    u32 GetMaxViewportWidth() const {
        return 16384;
    }
    u32 GetMaxViewportHeight() const {
        return 16384;
    }
    u32 MaxComputeSharedMemorySize() const {
        return 32768;
    }
    u32 SubgroupSize() const {
        return 32;
    }

private:
    void Create();

    void* device = nullptr; ///< id<MTLDevice>, retained
    std::string model_name;
    u64 total_memory_budget = 0;
    u64 max_buffer_size = 0;
};

} // namespace Vulkan
