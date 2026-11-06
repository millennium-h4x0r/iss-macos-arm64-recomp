// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: pipelines. The shader recompiler turns guest shaders into SPIR-V (as for
// the Vulkan renderer); SPIRV-Cross translates that to MSL and Metal compiles it. Resource slots
// follow the binding order the recompiler gives each stage: buffers, then images (textures),
// then samplers, each numbered from 0 in its Metal argument table. Push data (Shader::PushData)
// is buffer 30 of every stage, buffer sizes (for runtime array lengths) buffer 29, and vertex
// buffers follow a vertex stage's own buffers.

#pragma once

#include <array>
#include <condition_variable>
#include <mutex>
#include <memory>
#include <optional>
#include <unordered_map>
#include <vector>

#include "common/types.h"
#include "shader_recompiler/frontend/fetch_shader.h"
#include "shader_recompiler/info.h"
#include "shader_recompiler/profile.h"
#include "shader_recompiler/runtime_info.h"
#include "video_core/amdgpu/regs.h"
#include "video_core/renderer_vulkan/vk_common.h"

namespace AmdGpu {
struct Liverpool;
}

namespace Vulkan {

class Instance;
class Scheduler;

constexpr u32 MaxShaderStages = static_cast<u32>(Shader::SwStage::Compute) + 1;
constexpr u32 PushDataBufferIndex = 30;
constexpr u32 BufferSizesBufferIndex = 29;

/// One compiled stage.
struct MetalStage {
    const Shader::Info* info = nullptr;
    void* function = nullptr; ///< id<MTLFunction>, owned by the program's module
    u32 num_buffers = 0;
    u32 num_textures = 0;
    u32 num_samplers = 0;
    bool uses_buffer_sizes = false;
};

struct GraphicsPipelineKey {
    std::array<u64, MaxShaderStages> stage_hashes{};
    std::array<Shader::PsColorBuffer, AmdGpu::NUM_COLOR_BUFFERS> color_buffers{};
    std::array<AmdGpu::BlendControl, AmdGpu::NUM_COLOR_BUFFERS> blend_controls{};
    std::array<u8, AmdGpu::NUM_COLOR_BUFFERS> write_masks{};
    std::array<u8, AmdGpu::NUM_COLOR_BUFFERS> color_samples{};
    std::array<vk::Format, 32> vertex_formats{};
    std::array<u32, 32> vertex_strides{};
    AmdGpu::DepthBuffer::ZFormat z_format{};
    AmdGpu::DepthBuffer::StencilFormat stencil_format{};
    AmdGpu::PrimitiveType prim_type{};
    u32 mrt_mask = 0;
    u32 num_color_attachments = 0;
    u32 num_samples = 1;
    u32 depth_samples = 1;
    u32 cb_shader_mask = 0;
    bool alpha_to_coverage = false;
    u32 step_rate_0 = 0; ///< instanced vertex attributes (in the vertex descriptor)
    u32 step_rate_1 = 0;

    bool operator==(const GraphicsPipelineKey& other) const {
        return std::memcmp(this, &other, sizeof(*this)) == 0;
    }
};

/// tlg: a render pipeline Metal builds on another thread (encoder thread on): the command
/// processor records its draws meanwhile and the encoder thread waits for it (Wait) when it sets
/// the pipeline, so a burst of new pipelines builds in parallel instead of one by one.
struct DeferredPso {
    void* Wait() {
        std::unique_lock lock{mutex};
        cv.wait(lock, [this] { return done; });
        return pso;
    }
    bool Ready() {
        std::lock_guard lock{mutex};
        return done;
    }
    void Set(void* p) {
        {
            std::lock_guard lock{mutex};
            pso = p;
            done = true;
        }
        cv.notify_all();
    }
    void* pso = nullptr; ///< retained (null: failed); the pipeline takes it once Ready
private:
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
};

class GraphicsPipeline {
public:
    GraphicsPipelineKey key;
    std::array<MetalStage, MaxShaderStages> stages{};
    std::optional<Shader::Gcn::FetchShaderData> fetch_shader;
    void* pso = nullptr; ///< id<MTLRenderPipelineState>, retained
    std::shared_ptr<DeferredPso> deferred; ///< building (pso null meanwhile)
    /// Vertex attribute i reads buffer (vertex_buffer_base + i).
    u32 vertex_buffer_base = 0;

    const Shader::Info* Stage(Shader::SwStage stage) const {
        return stages[static_cast<u32>(stage)].info;
    }
    const GraphicsPipelineKey& GetGraphicsKey() const {
        return key;
    }
};

class ComputePipeline {
public:
    u64 hash = 0;
    MetalStage stage{};
    void* pso = nullptr; ///< id<MTLComputePipelineState>, retained
    std::array<u32, 3> workgroup_size{1, 1, 1};
};

/// Indirect draws: the vertex shader reads base vertex/instance from the draw instead of these
/// user SGPRs.
struct DrawIndirectParams {
    u16 vertex_sgpr_offset = 0;
    u16 instance_sgpr_offset = 0;
    bool is_indirect = false;
};

class PipelineCache {
public:
    explicit PipelineCache(const Instance& instance, Scheduler& scheduler,
                           AmdGpu::Liverpool* liverpool);
    ~PipelineCache();

    using IndirectParams = DrawIndirectParams;
    /// The pipeline of the current registers, or null (not supported, or failed).
    const GraphicsPipeline* GetGraphicsPipeline(IndirectParams params = {});
    const ComputePipeline* GetComputePipeline();

    /// Statistics line every few seconds (VideoOut driver).
    void ReportCompilerStats();

    const Shader::Profile& GetProfile() const {
        return profile;
    }

    struct Impl;
    Impl* impl_() noexcept {
        return impl.get();
    }

private:
    Shader::Profile profile{};
    std::unique_ptr<Impl> impl;
};

} // namespace Vulkan
