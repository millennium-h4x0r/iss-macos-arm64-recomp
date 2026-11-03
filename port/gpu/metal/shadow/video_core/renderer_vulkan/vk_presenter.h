// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: presentation. PrepareFrame (GPU command thread) copies the guest's display
// buffer into a frame texture on the draw queue; Present (VideoOut present thread) scales it into
// the window's CAMetalLayer drawable with the overlay on top.

#pragma once

#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

#include "core/libraries/videoout/buffer.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_runtime.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"
#include "video_core/texture_cache/texture_cache.h"

namespace Frontend {
class WindowSDL;
}

namespace AmdGpu {
struct Liverpool;
}

namespace Vulkan {

namespace HostPasses {
struct PostProcessingSettings {
    float gamma = 1.0f;
    u32 hdr = 0;
};
} // namespace HostPasses

struct Frame {
    u32 width = 0;
    u32 height = 0;
    void* texture = nullptr; ///< id<MTLTexture>, retained
    u64 ready_tick = 0;      ///< draw queue tick that wrote it
    bool is_hdr = false;
    bool blank = false;      ///< nothing to show (black)
    u8 id{};
};

class Rasterizer;

class Presenter {
public:
    Presenter(Frontend::WindowSDL& window, AmdGpu::Liverpool* liverpool);
    ~Presenter();

    HostPasses::PostProcessingSettings& GetPPSettingsRef() {
        return pp_settings;
    }
    Frontend::WindowSDL& GetWindow() const {
        return window;
    }
    Rasterizer& GetRasterizer() const {
        return *rasterizer;
    }
    bool IsHDRSupported() const {
        return false;
    }
    void SetHDR(bool) {}

    VideoCore::Image& RegisterVideoOutSurface(
        const Libraries::VideoOut::BufferAttributeGroup& attribute, VAddr cpu_address);

    Frame* PrepareFrame(const Libraries::VideoOut::BufferAttributeGroup& attribute,
                        VAddr cpu_address);
    Frame* PrepareBlankFrame(bool present_thread);
    void Present(Frame* frame, bool is_reusing_frame = false, bool is_game_frame = true);
    void PresentLoadingFrame();
    Frame* PrepareLastFrame();

private:
    Frame* GetRenderFrame();
    void EnsureFrameSize(Frame* frame, u32 width, u32 height);

    Frontend::WindowSDL& window;
    AmdGpu::Liverpool* liverpool;
    HostPasses::PostProcessingSettings pp_settings{};
    Instance instance;
    Scheduler draw_scheduler;
    Scheduler present_scheduler;
    Runtime runtime;
    std::unique_ptr<Rasterizer> rasterizer;
    VideoCore::TextureCache& texture_cache;
    void* layer = nullptr;         ///< CAMetalLayer, borrowed
    void* blit_pipeline = nullptr; ///< id<MTLRenderPipelineState>: frame -> drawable (gamma)
    void* copy_pipeline = nullptr; ///< id<MTLRenderPipelineState>: display buffer -> frame
    void* sampler = nullptr;       ///< id<MTLSamplerState>
    std::vector<Frame> frames;
    std::deque<Frame*> free_queue;
    Frame* last_submit_frame = nullptr;
    std::mutex free_mutex;
    std::condition_variable free_cv;
    std::vector<VAddr> vo_buffers_addr;
    int dump_index = 0;
    int dump_left = 0;
};

} // namespace Vulkan
