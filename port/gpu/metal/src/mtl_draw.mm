// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: draws and dispatches. Per draw: the pipeline (pipeline cache), render
// targets and resources from the texture cache, then the render pass (kept open while the targets
// stay the same), state and the draw itself. Textures are hazard-tracked by Metal; guest memory
// written by shaders orders later encoders through the scheduler's fence.

#include <algorithm>
#include <map>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <cstdlib>
#include <unordered_map>
#include <chrono>
#include <atomic>

#include "common/alignment.h"
#include "common/assert.h"
#include "core/memory.h"
#include "mtl_draw.h"
#include "mtl_format.h"
#include "mtl_objc.h"
#include "mtl_scheduler_internal.h"
#include "mtl_stencil.h"
#include "shader_recompiler/info.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/renderer_vulkan/liverpool_to_vk.h"
#include "video_core/renderer_vulkan/vk_depth_stencil_state.h"
#include "video_core/renderer_vulkan/vk_instance.h"

namespace Vulkan {

namespace {
// Profiling labels (TLG_METAL_LABEL=1), GPU thread only.
u32 label_pass_draws = 0;
u64 label_pass_verts = 0;
} // namespace


namespace {

using Shader::SwStage;

MTLCompareFunction Compare(vk::CompareOp op) {
    switch (op) {
    case vk::CompareOp::eNever: return MTLCompareFunctionNever;
    case vk::CompareOp::eLess: return MTLCompareFunctionLess;
    case vk::CompareOp::eEqual: return MTLCompareFunctionEqual;
    case vk::CompareOp::eLessOrEqual: return MTLCompareFunctionLessEqual;
    case vk::CompareOp::eGreater: return MTLCompareFunctionGreater;
    case vk::CompareOp::eNotEqual: return MTLCompareFunctionNotEqual;
    case vk::CompareOp::eGreaterOrEqual: return MTLCompareFunctionGreaterEqual;
    default: return MTLCompareFunctionAlways;
    }
}

MTLStencilOperation Stencil(vk::StencilOp op) {
    switch (op) {
    case vk::StencilOp::eZero: return MTLStencilOperationZero;
    case vk::StencilOp::eReplace: return MTLStencilOperationReplace;
    case vk::StencilOp::eIncrementAndClamp: return MTLStencilOperationIncrementClamp;
    case vk::StencilOp::eDecrementAndClamp: return MTLStencilOperationDecrementClamp;
    case vk::StencilOp::eInvert: return MTLStencilOperationInvert;
    case vk::StencilOp::eIncrementAndWrap: return MTLStencilOperationIncrementWrap;
    case vk::StencilOp::eDecrementAndWrap: return MTLStencilOperationDecrementWrap;
    default: return MTLStencilOperationKeep;
    }
}

/// Metal primitive of a guest primitive type, or false when it needs emulation.
bool Primitive(AmdGpu::PrimitiveType type, MTLPrimitiveType& out) {
    using P = AmdGpu::PrimitiveType;
    switch (type) {
    case P::QuadList: out = MTLPrimitiveTypeTriangle; return true; // converted indices
    case P::PointList: out = MTLPrimitiveTypePoint; return true;
    case P::LineList: out = MTLPrimitiveTypeLine; return true;
    case P::LineStrip: out = MTLPrimitiveTypeLineStrip; return true;
    case P::TriangleList: out = MTLPrimitiveTypeTriangle; return true;
    case P::TriangleStrip: out = MTLPrimitiveTypeTriangleStrip; return true;
    default: return false;
    }
}

struct AttachmentKey {
    void* texture = nullptr;
    u32 level = 0;
    u32 slice = 0;
};

} // namespace

/// A render pass's attachments: the recording side fills it, the encoding side builds the
/// MTLRenderPassDescriptor (textures unretained: the texture cache frees them only once the
/// tick has completed).
struct PassDesc {
    struct Color {
        void* texture = nullptr;
        u32 level = 0, slice = 0;
        bool is_3d = false, clear = false;
        float clear_color[4]{};
    };
    std::array<Color, 8> colors{};
    void* depth = nullptr;
    u32 depth_slice = 0;
    bool has_depth = false, has_stencil = false, depth_clear = false, stencil_clear = false;
    float clear_depth = 0;
    u32 clear_stencil = 0;
    bool no_attachments = false;
    u32 width = 1, height = 1, samples = 1;

    MTLRenderPassDescriptor* Build() const {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        for (u32 cb = 0; cb < colors.size(); ++cb) {
            const Color& c = colors[cb];
            if (!c.texture) {
                continue;
            }
            auto* att = rp.colorAttachments[cb];
            att.texture = (__bridge id<MTLTexture>)c.texture;
            att.level = c.level;
            if (c.is_3d) {
                att.depthPlane = c.slice;
            } else {
                att.slice = c.slice;
            }
            att.loadAction = c.clear ? MTLLoadActionClear : MTLLoadActionLoad;
            if (c.clear) {
                att.clearColor = MTLClearColorMake(c.clear_color[0], c.clear_color[1], c.clear_color[2],
                                                   c.clear_color[3]);
            }
            att.storeAction = MTLStoreActionStore;
        }
        if (depth) {
            id<MTLTexture> t = (__bridge id<MTLTexture>)depth;
            if (has_depth) {
                rp.depthAttachment.texture = t;
                rp.depthAttachment.slice = depth_slice;
                rp.depthAttachment.loadAction = depth_clear ? MTLLoadActionClear : MTLLoadActionLoad;
                rp.depthAttachment.clearDepth = clear_depth;
                rp.depthAttachment.storeAction = MTLStoreActionStore;
            }
            if (has_stencil) {
                rp.stencilAttachment.texture = t;
                rp.stencilAttachment.slice = depth_slice;
                rp.stencilAttachment.loadAction = stencil_clear ? MTLLoadActionClear : MTLLoadActionLoad;
                rp.stencilAttachment.clearStencil = clear_stencil;
                rp.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        }
        if (no_attachments) {
            rp.renderTargetWidth = width;
            rp.renderTargetHeight = height;
            rp.defaultRasterSampleCount = samples;
        }
        return rp;
    }
};

struct Rasterizer::DrawState::Impl {
    id<MTLTexture> dummy_2d = nil;
    id<MTLTexture> dummy_2d_array = nil;
    id<MTLTexture> dummy_3d = nil;
    id<MTLSamplerState> dummy_sampler = nil;
    id<MTLBuffer> dummy_buffer = nil;
    std::unordered_map<u64, id<MTLDepthStencilState>> depth_states;
    id<MTLComputePipelineState> clamp_pipeline = nil;
    id<MTLComputePipelineState> quad_pipeline = nil;
    id<MTLComputePipelineState> copy_pipeline = nil;
    id<MTLBuffer> quad_indices = nil;
    u32 quad_count = 0;
    std::array<AttachmentKey, 9> pass{}; ///< attachments of the open render pass
    u32 pass_width = 0, pass_height = 0;
    bool pass_open = false;
    u32 since_commit = 0; ///< draws recorded since the command buffer was last committed

    /// tlg: the state set on the current render encoder, so a draw only sets what changed
    /// (every draw set ~20 states: a third of the command processor thread is in Metal). Valid
    /// for one encoder (pointer and the scheduler's encoder count). TLG_METAL_STATE_CACHE=0: off.
    struct EncCache {
        u64 count = ~0ull;
        void* pso = nullptr;
        void* buf[2][32]{};
        u64 off[2][32]{};
        void* tex[2][128]{};
        void* smp[2][16]{};
        u32 sizes[2][32]{};
        bool sizes_valid[2]{};
        Shader::PushData push[2]{};
        bool push_valid[2]{};
        MTLViewport viewport{};
        bool viewport_valid = false;
        MTLScissorRect scissor{};
        bool scissor_valid = false;
        int cull = -1, winding = -1, fill = -1, clip = -1;
        float bias[3]{};
        bool bias_valid = false;
        float blend[4]{};
        bool blend_valid = false;
        void* ds = nullptr;
        u32 sref[2]{};
        bool sref_valid = false;
    } ec;
};

namespace {
id<MTLTexture> Dummy(MTLTextureType type) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor new];
    d.textureType = type;
    d.pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.width = d.height = 1;
    d.depth = 1;
    d.arrayLength = 1;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> t = [Metal::Device() newTextureWithDescriptor:d];
    // Transparent black, as Vulkan's null descriptors read.
    const u8 zero[4] = {};
    [t replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 slice:0 withBytes:zero
         bytesPerRow:4 bytesPerImage:4];
    return t;
}
} // namespace

Rasterizer::DrawState::DrawState(const Instance& instance, Scheduler&, Runtime&)
    : impl{std::make_unique<Impl>()} {
    gds = std::make_unique<VideoCore::Buffer>(instance, 0, 64_KB,
                                              VideoCore::MemoryType::DeviceLocal, "GDS");
    std::memset(gds->mapped_data.data(), 0, gds->mapped_data.size());
    impl->dummy_2d = Dummy(MTLTextureType2D);
    impl->dummy_2d_array = Dummy(MTLTextureType2DArray);
    impl->dummy_3d = Dummy(MTLTextureType3D);
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    impl->dummy_sampler = [Metal::Device() newSamplerStateWithDescriptor:sd];
    impl->dummy_buffer = [Metal::Device() newBufferWithLength:64 * 1024
                                                     options:MTLResourceStorageModeShared];
    std::memset(impl->dummy_buffer.contents, 0, 64 * 1024);
}

Rasterizer::DrawState::~DrawState() = default;

namespace {
const char* kClampSource = R"(
#include <metal_stdlib>
using namespace metal;
// Copies indirect draw arguments, zeroing the draws at and past the count.
kernel void clamp_args(const device uint* src [[buffer(0)]], const device uint* count [[buffer(1)]],
                       device uint* dst [[buffer(2)]], constant uint2& p [[buffer(3)]],
                       uint i [[thread_position_in_grid]]) {
    const uint words = p.x / 4u;
    if (i >= p.y * words) {
        return;
    }
    const uint draw = i / words;
    dst[i] = draw < count[0] ? src[i] : 0u;
}
)";
} // namespace

namespace {
const char* kQuadSource = R"(
#include <metal_stdlib>
using namespace metal;
struct P { uint stride; uint max_count; uint indexed; uint is16; uint max_quads; };
// One thread per indirect draw: indexed triangle-list arguments for its quads; for indexed draws
// also the triangle indices (0 1 2 0 2 3 of each quad).
kernel void quad_args(const device uint* src [[buffer(0)]], device uint* dst [[buffer(1)]],
                      const device uchar* indices [[buffer(2)]], device uint* out_indices [[buffer(3)]],
                      constant P& p [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.max_count) {
        return;
    }
    const device uint* a = src + i * (p.stride / 4u);
    device uint* d = dst + i * 5u;
    if (p.indexed == 0u) {
        // vertexCount, instanceCount, vertexStart, baseInstance
        const uint quads = min(a[0] / 4u, p.max_quads);
        d[0] = quads * 6u; d[1] = a[1]; d[2] = 0u; d[3] = a[2]; d[4] = a[3];
        return;
    }
    // indexCount, instanceCount, indexStart, baseVertex, baseInstance
    const uint quads = min(a[0] / 4u, p.max_quads);
    const uint base = i * p.max_quads * 6u;
    for (uint q = 0u; q < quads; ++q) {
        uint v[4];
        for (uint k = 0u; k < 4u; ++k) {
            const uint at = a[2] + q * 4u + k;
            v[k] = p.is16 != 0u ? uint(((const device ushort*)indices)[at]) : ((const device uint*)indices)[at];
        }
        device uint* o = out_indices + base + q * 6u;
        o[0] = v[0]; o[1] = v[1]; o[2] = v[2]; o[3] = v[0]; o[4] = v[2]; o[5] = v[3];
    }
    d[0] = quads * 6u; d[1] = a[1]; d[2] = base; d[3] = a[3]; d[4] = a[4];
}
)";
} // namespace

id<MTLBuffer> Rasterizer::DrawState::QuadIndices(u32 quads) {
    if (impl->quad_indices && impl->quad_count >= quads) {
        return impl->quad_indices;
    }
    impl->quad_count = std::max<u32>(quads, 65536);
    impl->quad_indices = [Metal::Device() newBufferWithLength:u64(impl->quad_count) * 6 * 4
                                                      options:MTLResourceStorageModeShared];
    u32* o = static_cast<u32*>(impl->quad_indices.contents);
    for (u32 q = 0; q < impl->quad_count; ++q) {
        const u32 b = q * 4;
        o[q * 6 + 0] = b; o[q * 6 + 1] = b + 1; o[q * 6 + 2] = b + 2;
        o[q * 6 + 3] = b; o[q * 6 + 4] = b + 2; o[q * 6 + 5] = b + 3;
    }
    return impl->quad_indices;
}

void Rasterizer::DrawState::ConvertQuadIndirect(Scheduler& scheduler, id<MTLBuffer> args,
                                                u64 args_offset, u32 stride, u32 max_count,
                                                bool indexed, id<MTLBuffer> indices,
                                                u64 indices_offset, bool is16, u32 max_quads,
                                                id<MTLBuffer> out_args, u64 out_args_offset,
                                                id<MTLBuffer> out_indices, u64 out_indices_offset) {
    if (!impl->quad_pipeline) {
        NSError* error = nil;
        id<MTLLibrary> lib = [Metal::Device() newLibraryWithSource:[NSString stringWithUTF8String:kQuadSource]
                                                           options:nil
                                                             error:&error];
        ASSERT_MSG(lib, "quad_args: {}", error.localizedDescription.UTF8String);
        impl->quad_pipeline = [Metal::Device()
            newComputePipelineStateWithFunction:[lib newFunctionWithName:@"quad_args"]
                                          error:&error];
    }
    id<MTLComputePipelineState> pso = impl->quad_pipeline;
    id<MTLBuffer> in_indices = indices ? indices : impl->dummy_buffer;
    const u64 in_indices_offset = indices ? indices_offset : 0;
    const u64 out_idx_offset = indexed ? out_indices_offset : 0;
    const std::array<u32, 5> p = {stride, max_count, indexed ? 1u : 0u, is16 ? 1u : 0u, max_quads};
    MetalScheduler::RecordCompute(scheduler, "quad_args", [=](id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:pso];
        [enc setBuffer:args offset:args_offset atIndex:0];
        [enc setBuffer:out_args offset:out_args_offset atIndex:1];
        [enc setBuffer:in_indices offset:in_indices_offset atIndex:2];
        [enc setBuffer:out_indices offset:out_idx_offset atIndex:3];
        [enc setBytes:p.data() length:sizeof(p) atIndex:4];
        [enc dispatchThreads:MTLSizeMake(max_count, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    });
}

namespace {
const char* kCopySource = R"(
#include <metal_stdlib>
using namespace metal;
kernel void copy_bytes(const device uchar* src [[buffer(0)]], device uchar* dst [[buffer(1)]],
                       constant uint& n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i < n) {
        dst[i] = src[i];
    }
}
)";
} // namespace

namespace FrameLog {
u64 g_draws = 0;
namespace {
struct Cs {
    u32 count = 0;
    u64 groups = 0;
    u32 indirect = 0;
};
std::map<u64, Cs> g_cs;
u64 g_frame = 0;
bool Enabled() {
    static const bool on = std::getenv("TLG_METAL_FRAME_CS") != nullptr;
    return on;
}
void NoteDispatch(u64 hash, u64 groups, bool indirect) {
    auto& c = g_cs[hash];
    ++c.count;
    c.groups += groups;
    c.indirect += indirect;
}
} // namespace
void EndFrame(bool dumped) {
    if (!Enabled()) {
        return;
    }
    // "d": the dumped frames only.
    static const bool dumped_only = std::getenv("TLG_METAL_FRAME_CS")[0] == 'd';
    static const u64 first = std::strtoull(std::getenv("TLG_METAL_FRAME_CS"), nullptr, 0);
    if (dumped_only ? dumped : (g_frame >= first && g_frame < first + 200)) {
        std::string line;
        for (const auto& [h, c] : g_cs) {
            char b[64];
            std::snprintf(b, sizeof(b), " %s%llx:%u/%llu%s", h >> 63 ? "p" : "",
                          (unsigned long long)(h & ~(1ull << 63)), c.count,
                          (unsigned long long)c.groups, c.indirect ? "i" : "");
            line += b;
        }
        static auto last = std::chrono::steady_clock::now();
        const auto now = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(now - last).count();
        last = now;
        std::printf("frame %llu%s: %.1f ms %llu draws, cs%s\n", (unsigned long long)g_frame,
                    dumped ? " DUMPED" : "", ms, (unsigned long long)g_draws, line.c_str());
    }
    ++g_frame;
    g_cs.clear();
    g_draws = 0;
}
} // namespace FrameLog

namespace NanScan {
namespace {
constexpr u32 MaxSlots = 8192;
const char* kNanSource = R"(
#include <metal_stdlib>
using namespace metal;
kernel void nan_scan(texture2d<float, access::read> t [[texture(0)]],
                     device atomic_uint* out [[buffer(0)]], constant uint& slot [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= t.get_width() || gid.y >= t.get_height()) return;
    const float4 v = t.read(gid);
    const bool n = any(isnan(v)), i = any(isinf(v));
    if (!n && !i) return;
    device atomic_uint* o = out + slot * 4;
    if (n) atomic_fetch_add_explicit(&o[0], 1u, memory_order_relaxed);
    if (i) atomic_fetch_add_explicit(&o[1], 1u, memory_order_relaxed);
    const uint mask = (isnan(v.x) ? 1u : 0u) | (isnan(v.y) ? 2u : 0u) | (isnan(v.z) ? 4u : 0u) |
                      (isnan(v.w) ? 8u : 0u) | (isinf(v.x) ? 16u : 0u) | (isinf(v.y) ? 32u : 0u) |
                      (isinf(v.z) ? 64u : 0u) | (isinf(v.w) ? 128u : 0u);
    atomic_fetch_or_explicit(&o[0], mask << 24, memory_order_relaxed);
    atomic_fetch_min_explicit(&o[2], (gid.y << 16) | gid.x, memory_order_relaxed);
    atomic_fetch_max_explicit(&o[3], (gid.y << 16) | gid.x, memory_order_relaxed);
}
)";
struct State {
    bool active = false;
    id<MTLComputePipelineState> pso = nil;
    id<MTLBuffer> counts = nil;
    std::vector<std::string> labels;
    std::vector<id<MTLTexture>> pass_targets;
    std::vector<u32> pass_cbs;
    std::vector<u64> pass_ps;
    u64 pass_draw = 0;
    u64 frame = 0;
};
State g;

bool IsFloat(MTLPixelFormat pf) {
    switch (pf) {
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG16Float: case MTLPixelFormatR16Float:
    case MTLPixelFormatRGBA32Float: case MTLPixelFormatRG32Float: case MTLPixelFormatR32Float:
    case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float:
        return true;
    default:
        return false;
    }
}

void Scan(Scheduler& scheduler, id<MTLTexture> tex, const std::string& label) {
    if (!tex || tex.textureType != MTLTextureType2D || !IsFloat(tex.pixelFormat) ||
        !(tex.usage & MTLTextureUsageShaderRead) || g.labels.size() >= MaxSlots) {
        return;
    }
    if (!g.pso) {
        NSError* error = nil;
        id<MTLLibrary> lib = [Metal::Device() newLibraryWithSource:[NSString stringWithUTF8String:kNanSource]
                                                           options:nil
                                                             error:&error];
        g.pso = [Metal::Device() newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nan_scan"]
                                                               error:&error];
        ASSERT_MSG(g.pso, "NaN scan pipeline");
    }
    if (!g.counts) {
        g.counts = [Metal::Device() newBufferWithLength:MaxSlots * 16 options:MTLResourceStorageModeShared];
        u32* c = static_cast<u32*>(g.counts.contents);
        for (u32 i = 0; i < MaxSlots; ++i) {
            c[i * 4] = c[i * 4 + 1] = c[i * 4 + 3] = 0;
            c[i * 4 + 2] = 0xFFFFFFFFu;
        }
    }
    const u32 slot = u32(g.labels.size());
    g.labels.push_back(label);
    id<MTLComputePipelineState> pso = g.pso;
    id<MTLBuffer> counts = g.counts;
    MetalScheduler::RecordCompute(scheduler, "nan_scan", [=](id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:pso];
        [enc setTexture:tex atIndex:0];
        [enc setBuffer:counts offset:0 atIndex:0];
        [enc setBytes:&slot length:sizeof(slot) atIndex:1];
        [enc dispatchThreads:MTLSizeMake(tex.width, tex.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    });
}

/// Scans the targets of the pass that just ended.
void FlushPass(Scheduler& scheduler) {
    std::string ps;
    for (const u64 h : g.pass_ps) {
        char b[40];
        char b2[40];
        std::snprintf(b2, sizeof(b2), "%s%08x", ps.empty() ? "" : ",", u32(h));
        if (h >> 32) {
            std::snprintf(b2, sizeof(b2), "%s%08x/vs%08x", ps.empty() ? "" : ",", u32(h), u32(h >> 32));
        }
        std::snprintf(b, sizeof(b), "%s", b2);
        ps += b;
    }
    for (size_t i = 0; i < g.pass_targets.size(); ++i) {
        id<MTLTexture> t = g.pass_targets[i];
        char label[256];
        std::snprintf(label, sizeof(label), "pass@draw%llu cb%u %ux%u fmt%u ps[%s]",
                      (unsigned long long)g.pass_draw, g.pass_cbs[i], u32(t.width), u32(t.height),
                      u32(t.pixelFormat), ps.c_str());
        Scan(scheduler, t, label);
    }
    g.pass_targets.clear();
    g.pass_cbs.clear();
    g.pass_ps.clear();
}
} // namespace

bool Enabled() {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_NAN_SCAN");
        return v && (*v == '1' || *v == '2' || *v == '3');
    }();
    return on;
}

/// TLG_METAL_NAN_SCAN=3: every frame (no dump needed), only the frames with hits are printed.
static bool EveryFrame() {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_NAN_SCAN");
        return v && *v == '3';
    }();
    return on;
}

bool Active() {
    return g.active;
}

bool PerDraw() {
    static const bool on = [] {
        const char* v = std::getenv("TLG_METAL_NAN_SCAN");
        return v && *v == '2';
    }();
    return on;
}

void BeginPass(Scheduler& scheduler, u64 draw, const id<MTLTexture>* targets, u32 count) {
    FlushPass(scheduler);
    g.pass_draw = draw;
    for (u32 i = 0; i < count; ++i) {
        if (targets[i]) {
            g.pass_targets.push_back(targets[i]);
            g.pass_cbs.push_back(i);
        }
    }
}

void NoteDraw(u64 ps_hash) {
    if (g.pass_ps.size() < 8 && std::find(g.pass_ps.begin(), g.pass_ps.end(), ps_hash) == g.pass_ps.end()) {
        g.pass_ps.push_back(ps_hash);
    }
}

void AfterDispatch(Scheduler& scheduler, u64 cs_hash, const id<MTLTexture>* textures, u32 count) {
    FlushPass(scheduler);
    for (u32 i = 0; i < count; ++i) {
        char label[96];
        std::snprintf(label, sizeof(label), "cs %016llx t%u", (unsigned long long)cs_hash, i);
        Scan(scheduler, textures[i], label);
    }
}

void EndFrame(Scheduler& scheduler, bool next_active) {
    if (g.active) {
        FlushPass(scheduler);
        scheduler.EndEncoding();
        if (g.counts) {
            id<MTLBuffer> counts = g.counts;
            auto labels = std::make_shared<std::vector<std::string>>(std::move(g.labels));
            const u64 frame = g.frame;
            scheduler.SignalOnCompletion([counts, labels, frame] {
                const u32* c = static_cast<const u32*>(counts.contents);
                u32 hits = 0;
                for (size_t i = 0; i < labels->size(); ++i) {
                    if (c[i * 4] || c[i * 4 + 1]) {
                        ++hits;
                        std::printf("NaN scan frame %llu #%zu %s: nan %u inf %u (channels nan %x inf %x) first %u,%u last %u,%u\n",
                                    (unsigned long long)frame, i, (*labels)[i].c_str(), c[i * 4] & 0xFFFFFF,
                                    c[i * 4 + 1], (c[i * 4] >> 24) & 15, c[i * 4] >> 28,
                                    c[i * 4 + 2] & 0xFFFF, c[i * 4 + 2] >> 16,
                                    c[i * 4 + 3] & 0xFFFF, c[i * 4 + 3] >> 16);
                    }
                }
                if (hits || !EveryFrame() || frame % 600 == 0) {
                    static const auto t0 = std::chrono::steady_clock::now();
                    std::printf("NaN scan frame %llu (t=%.2f): %zu scans, %u with NaN/Inf\n",
                                (unsigned long long)frame,
                                std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(),
                                labels->size(), hits);
                }
            });
        }
        g.counts = nil;
        g.labels.clear();
    }
    ++g.frame;
    g.active = next_active || EveryFrame();
}
} // namespace NanScan

void Rasterizer::DrawState::CopyBytes(Scheduler& scheduler, id<MTLBuffer> src, u64 src_offset,
                                      id<MTLBuffer> dst, u64 dst_offset, u64 size) {
    if (!impl->copy_pipeline) {
        NSError* error = nil;
        id<MTLLibrary> lib = [Metal::Device() newLibraryWithSource:[NSString stringWithUTF8String:kCopySource]
                                                           options:nil
                                                             error:&error];
        impl->copy_pipeline = [Metal::Device()
            newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copy_bytes"]
                                          error:&error];
    }
    id<MTLComputePipelineState> pso = impl->copy_pipeline;
    const u32 n = u32(size);
    MetalScheduler::RecordCompute(scheduler, "copy_bytes", [=](id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:pso];
        [enc setBuffer:src offset:src_offset atIndex:0];
        [enc setBuffer:dst offset:dst_offset atIndex:1];
        [enc setBytes:&n length:sizeof(n) atIndex:2];
        [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    });
}

void Rasterizer::DrawState::ClampIndirect(Scheduler& scheduler, id<MTLBuffer> src, u64 src_offset,
                                          id<MTLBuffer> count, u64 count_offset, id<MTLBuffer> dst,
                                          u64 dst_offset, u32 stride, u32 max_count) {
    if (!impl->clamp_pipeline) {
        NSError* error = nil;
        id<MTLLibrary> lib = [Metal::Device() newLibraryWithSource:[NSString stringWithUTF8String:kClampSource]
                                                           options:nil
                                                             error:&error];
        impl->clamp_pipeline = [Metal::Device()
            newComputePipelineStateWithFunction:[lib newFunctionWithName:@"clamp_args"]
                                          error:&error];
    }
    id<MTLComputePipelineState> pso = impl->clamp_pipeline;
    const std::array<u32, 2> p = {stride, max_count};
    const u32 n = stride / 4 * max_count;
    MetalScheduler::RecordCompute(scheduler, "clamp_args", [=](id<MTLComputeCommandEncoder> enc) {
        [enc setComputePipelineState:pso];
        [enc setBuffer:src offset:src_offset atIndex:0];
        [enc setBuffer:count offset:count_offset atIndex:1];
        [enc setBuffer:dst offset:dst_offset atIndex:2];
        [enc setBytes:p.data() length:sizeof(p) atIndex:3];
        [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    });
}

void Rasterizer::DrawState::OnSubmit() {
    const auto now = std::chrono::steady_clock::now();
    if (now - last_report < std::chrono::seconds(5)) {
        return;
    }
    last_report = now;
    std::printf("GPU (Metal): %llu draws (%llu skipped: %llu no pipeline, %llu primitive), %llu "
                "dispatches (%llu skipped), %llu passes in 5 s\n",
                (unsigned long long)draws, (unsigned long long)skipped_draws,
                (unsigned long long)no_pipeline, (unsigned long long)unsupported_primitive,
                (unsigned long long)dispatches, (unsigned long long)skipped_dispatches,
                (unsigned long long)passes);
    if (MetalScheduler::PassStatsEnabled()) {
        std::printf("GPU (Metal): render passes ended by%s; %llu draws without effect skipped\n",
                    MetalScheduler::TakeRenderBreaks().c_str(), (unsigned long long)noop_draws);
    }
    std::string prims;
    for (u32 i = 0; i < 32; ++i) {
        if (prim_counts[i]) {
            prims += " " + std::to_string(i) + ":" + std::to_string(prim_counts[i]);
        }
    }
    if (unaligned_vertex_buffers) {
        std::printf("GPU (Metal): %llu unaligned vertex buffers copied in 5 s\n",
                    (unsigned long long)unaligned_vertex_buffers);
        unaligned_vertex_buffers = 0;
    }
    if (!prims.empty() || indirect_draws) {
        std::printf("GPU (Metal): skipped primitives (type:count)%s; indirect draws %llu "
                    "(%llu quads as strips), indirect dispatches %llu, draw barriers %llu\n",
                    prims.c_str(), (unsigned long long)indirect_draws, (unsigned long long)quad_strips,
                    (unsigned long long)indirect_dispatches, (unsigned long long)draw_barriers);
    }
    quad_strips = 0;
    prim_counts = {};
    indirect_draws = indirect_dispatches = draw_barriers = 0;
    draws = skipped_draws = dispatches = skipped_dispatches = 0;
    no_pipeline = unsupported_primitive = passes = noop_draws = 0;
}

/// Resources of one stage, ready to bind. Unretained: the caches own every object for the
/// draw and the encoder retains what it binds. Strong arrays cost ~30% of the command
/// processor thread (1056 ARC slots set and released per draw).
/// Only the first num_* entries are set (no zeroing: ~10 KB per draw); sizes past num_buffers
/// are never read by the shaders.
struct StageBindings {
    std::array<__unsafe_unretained id<MTLBuffer>, 32> buffers;
    std::array<u64, 32> offsets;
    std::array<u32, 32> sizes;
    std::array<__unsafe_unretained id<MTLTexture>, 128> textures;
    std::array<__unsafe_unretained id<MTLSamplerState>, 16> samplers;
    u32 num_buffers = 0, num_textures = 0, num_samplers = 0;
    bool writes_memory = false;
    bool writes_images = false; ///< binds a storage image
};

// tlg: a texture binding's ImageDesc (ImageInfo with its mip layout, ImageViewInfo) depends only
// on the T# and the shader's resource flags; built for every texture of every draw it was ~6% of
// the command processor thread. A direct-mapped memo of the last ones (BindStage runs on the
// command processor thread only). TLG_METAL_IMAGE_DESC_MEMO=0: off.
static VideoCore::TextureCache::ImageDesc CachedImageDesc(const AmdGpu::Image& tsharp,
                                                          const Shader::ImageResource& res) {
    static const bool enabled = [] {
        const char* v = std::getenv("TLG_METAL_IMAGE_DESC_MEMO");
        return !v || v[0] != '0';
    }();
    if (!enabled) {
        return VideoCore::TextureCache::ImageDesc{tsharp, res};
    }
    static_assert(sizeof(AmdGpu::Image) == 32);
    const u32 flags = u32(res.is_depth) | u32(res.is_atomic) << 1 | u32(res.is_array) << 2 |
                      u32(res.is_written) << 3 | u32(res.is_r128) << 4 | u32(res.needs_native) << 5 |
                      u32(res.constant_mip_index) << 8 | u32(res.mip_fallback_mode) << 16 |
                      u32(res.post_op) << 24;
    struct Entry {
        u64 sharp[4];
        u32 flags;
        bool valid;
        VideoCore::TextureCache::ImageDesc desc;
    };
    static Entry entries[256];
    u64 words[4];
    std::memcpy(words, &tsharp, sizeof(words));
    u64 h = (words[0] ^ words[1] * 0x9E3779B97F4A7C15ull ^ words[2] * 0xC2B2AE3D27D4EB4Full ^
             words[3] * 0x165667B19E3779F9ull ^ flags) * 0xFF51AFD7ED558CCDull;
    Entry& e = entries[h >> 56];
    if (e.valid && e.flags == flags && std::memcmp(e.sharp, words, sizeof(words)) == 0) {
        return e.desc;
    }
    e.desc = VideoCore::TextureCache::ImageDesc{tsharp, res};
    std::memcpy(e.sharp, words, sizeof(words));
    e.flags = flags;
    e.valid = true;
    return e.desc;
}

/// Collects the resources of `stage` (texture cache and buffer cache work happens here, before
/// any render pass is opened).
bool Rasterizer::BindStage(const MetalStage& stage, Shader::Backend::Bindings& binding,
                           Shader::PushData& push_data, StageBindings& out) {
    const auto& info = *stage.info;
    auto& d = *draw_state->impl;
    info.PushUd(binding, push_data);
    // Buffers.
    u32 slot = 0;
    for (u32 i = 0; i < info.buffers.size() && slot < 28; ++i, ++slot) {
        const auto& desc = info.buffers[i];
        // Unretained (as StageBindings): the caches own them; ARC traffic was ~3% of the
        // command processor thread.
        __unsafe_unretained id<MTLBuffer> buffer = d.dummy_buffer;
        u64 offset = 0;
        u32 size = 64 * 1024;
        if (desc.IsSpecial()) {
            if (desc.buffer_type == Shader::BufferType::GdsBuffer) {
                // Diagnosis: TLG_METAL_LOG_GDS=1: the shaders that bind GDS (each once).
                if (static const bool log_gds = std::getenv("TLG_METAL_LOG_GDS") != nullptr; log_gds) {
                    static std::mutex m;
                    static std::vector<u64> seen;
                    std::scoped_lock lk{m};
                    if (std::find(seen.begin(), seen.end(), info.pgm_hash) == seen.end()) {
                        seen.push_back(info.pgm_hash);
                        std::printf("GDS user: shader %016llx stage %u\n", (unsigned long long)info.pgm_hash,
                                    u32(info.hw_stage));
                    }
                }
                buffer = (__bridge id<MTLBuffer>)Metal::Raw(draw_state->gds->Handle());
                size = u32(draw_state->gds->SizeBytes());
            } else if (desc.buffer_type == Shader::BufferType::Flatbuf) {
                auto& stream = buffer_cache.GetStreamBuffer();
                const u32 ubo_size = u32(info.FlatUserData().size() * sizeof(u32));
                offset = stream.Copy(info.FlatUserData().data(), std::max<u32>(ubo_size, 4), 16);
                buffer = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
                size = ubo_size;
            } else if (desc.buffer_type == Shader::BufferType::ClipPlanes) {
                auto& stream = buffer_cache.GetStreamBuffer();
                std::array<float, AmdGpu::NUM_CLIP_PLANES * 4> planes{};
                for (u32 p = 0; p < AmdGpu::NUM_CLIP_PLANES; ++p) {
                    const auto& plane = liverpool->regs.clip_user_data[p];
                    planes[p * 4 + 0] = std::bit_cast<float>(plane.data_x);
                    planes[p * 4 + 1] = std::bit_cast<float>(plane.data_y);
                    planes[p * 4 + 2] = std::bit_cast<float>(plane.data_z);
                    planes[p * 4 + 3] = std::bit_cast<float>(plane.data_w);
                }
                offset = stream.Copy(planes.data(), sizeof(planes), 16);
                buffer = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
                size = sizeof(planes);
            } else if (desc.buffer_type == Shader::BufferType::SharedMemory) {
                auto& stream = buffer_cache.GetStreamBuffer();
                const auto& cs = liverpool->GetCsRegs();
                const u32 lds_size = cs.SharedMemSize() * cs.NumWorkgroups();
                const auto [data, off] = stream.Map(std::max<u32>(lds_size, 16), 16);
                std::memset(data, 0, lds_size);
                stream.Commit();
                buffer = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
                offset = off;
                size = lds_size;
            }
            // BDA page table and fault buffer: not used by the Metal profile.
        } else {
            const auto vsharp = desc.GetSharp(info);
            if (vsharp.base_address != 0 && vsharp.GetSize() != 0) {
                const u64 bytes = memory->ClampRangeSize(vsharp.base_address, vsharp.GetSize());
                const auto [vb, voff] =
                    buffer_cache.ObtainBuffer(vsharp.base_address, bytes, desc.is_written);
                // Diagnosis: TLG_METAL_WATCH_ADDR=<hex guest address>: the shaders that bind a
                // written buffer covering it (first 400).
                static const u64 watch = [] {
                    const char* v = std::getenv("TLG_METAL_WATCH_ADDR");
                    return v ? std::strtoull(v, nullptr, 16) : 0ull;
                }();
                if (watch && desc.is_written && watch >= vsharp.base_address &&
                    watch < vsharp.base_address + bytes) {
                    static std::atomic<u32> watched{0};
                    if (watched.fetch_add(1) < 400) {
                        std::printf("watch %#llx: shader %016llx stage %u buffer %u base %#llx size %llu (+%llu)\n",
                                    (unsigned long long)watch, (unsigned long long)info.pgm_hash, u32(info.hw_stage), i,
                                    (unsigned long long)vsharp.base_address, (unsigned long long)bytes,
                                    (unsigned long long)(watch - vsharp.base_address));
                    }
                }
                static int buffer_logs = 0;
                static const int max_buffer_logs = [] {
                    const char* v = std::getenv("TLG_METAL_LOG_BUFFERS");
                    return v ? std::atoi(v) : 0;
                }();
                if (buffer_logs < max_buffer_logs) {
                    ++buffer_logs;
                    const float* f = reinterpret_cast<const float*>(vsharp.base_address);
                    id<MTLBuffer> mb = (__bridge id<MTLBuffer>)Metal::Raw(vb->Handle());
                    const float* g = reinterpret_cast<const float*>(static_cast<const u8*>(mb.contents) + voff);
                    std::printf("  buffer %u: %#llx size %llu -> mtl %p (cpu %#llx len %llu) off %llu: "
                                "guest %g %g %g %g mtl %g %g %g %g\n",
                                i, (unsigned long long)vsharp.base_address, (unsigned long long)bytes,
                                (__bridge void*)mb, (unsigned long long)vb->CpuAddr(),
                                (unsigned long long)mb.length, (unsigned long long)voff, f[0], f[1],
                                f[2], f[3], g[0], g[1], g[2], g[3]);
                }
                const u64 aligned = voff & ~u64(3);
                push_data.AddOffset(binding.buffer, u32(voff - aligned));
                buffer = (__bridge id<MTLBuffer>)Metal::Raw(vb->Handle());
                offset = aligned;
                size = u32(bytes + (voff - aligned));
                if (desc.is_written) {
                    texture_cache.InvalidateMemoryFromGPU(vsharp.base_address, bytes);
                    out.writes_memory = true;
                }
            }
        }
        out.buffers[slot] = buffer;
        out.offsets[slot] = offset;
        out.sizes[slot] = size;
        ++binding.buffer;
        ++binding.unified;
    }
    out.num_buffers = slot;
    // Images.
    u32 tslot = 0;
    for (const auto& image_desc : info.images) {
        const auto tsharp = image_desc.GetSharp(info);
        const u32 num_bindings = image_desc.NumBindings(info);
        for (u32 n = 0; n < num_bindings && tslot < out.textures.size(); ++n, ++tslot) {
            __unsafe_unretained id<MTLTexture> texture = nil;
            if (tsharp.Address() != 0 &&
                tsharp.GetDataFmt() != AmdGpu::DataFormat::FormatInvalid &&
                memory->IsValidGpuMapping(tsharp.Address(), 0)) {
                VideoCore::TextureCache::ImageDesc desc = CachedImageDesc(tsharp, image_desc);
                if (image_desc.mip_fallback_mode == Shader::MipStorageFallbackMode::ConstantIndex) {
                    desc.view_info.range.base.level += image_desc.constant_mip_index;
                    desc.view_info.range.extent.levels = 1;
                } else if (image_desc.mip_fallback_mode ==
                           Shader::MipStorageFallbackMode::DynamicIndex) {
                    desc.view_info.range.base.level += n;
                    desc.view_info.range.extent.levels = 1;
                }
                auto image_id = texture_cache.FindImage(desc);
                auto* image = &texture_cache.GetImage(image_id);
                if (auto depth_id = texture_cache.GetAssociatedDepth(*image)) {
                    image_id = depth_id;
                    image = &texture_cache.GetImage(image_id);
                }
                image->binding.is_bound = 1u;
                bound_images.push_back(image_id);
                auto& view = texture_cache.FindTexture(image_id, desc);
                static const bool log_formats = std::getenv("TLG_METAL_LOG_FORMATS") != nullptr;
                if (log_formats) {
                    static std::mutex m;
                    static std::unordered_map<u64, u32> seen;
                    std::scoped_lock lk{m};
                    const u64 k = (u64(image->info.pixel_format) << 32) | u64(desc.view_info.format) << 1 |
                                  u64(desc.type == VideoCore::TextureCache::BindingType::Storage);
                    if (seen[k]++ == 0) {
                        std::printf("Texture format: image %s view %s %s type %u swz %u%u%u%u dfmt %u nfmt %u\n",
                                    vk::to_string(image->info.pixel_format).c_str(),
                                    vk::to_string(desc.view_info.format).c_str(),
                                    desc.type == VideoCore::TextureCache::BindingType::Storage ? "storage" : "sampled",
                                    u32(image->info.type), u32(desc.view_info.mapping.r), u32(desc.view_info.mapping.g),
                                    u32(desc.view_info.mapping.b), u32(desc.view_info.mapping.a),
                                    u32(tsharp.GetDataFmt()), u32(tsharp.GetNumberFmt()));
                    }
                }
                // Debugging: the images a given shader binds (TLG_METAL_LOG_PS=<hex pgm hash>).
                static const u64 log_ps = [] {
                    const char* v = std::getenv("TLG_METAL_LOG_PS");
                    return v ? std::strtoull(v, nullptr, 16) : 0ull;
                }();
                if (log_ps && info.pgm_hash == log_ps) {
                    static std::atomic<u32> ps_logs{0};
                    if (ps_logs.fetch_add(1) < 4000) {
                        const auto& ii = image->info;
                        std::printf("PS %016llx image %u: addr %#llx size %u %ux%u pitch %u bits %u tile %u "
                                    "array %u fmt %s mips %u flags %#x tsharp tile %u pitch %u type %u %ux%u view %u tex %ux%u type %u\n",
                                    (unsigned long long)info.pgm_hash, n, (unsigned long long)ii.guest_address,
                                    ii.guest_size, ii.size.width, ii.size.height, ii.pitch, ii.num_bits,
                                    u32(ii.tile_mode), u32(ii.array_mode), vk::to_string(ii.pixel_format).c_str(),
                                    ii.resources.levels, u32(image->flags), u32(tsharp.tiling_index),
                                    u32(tsharp.Pitch()), u32(tsharp.GetType()), u32(tsharp.width + 1),
                                    u32(tsharp.height + 1), u32(tsharp.GetHostViewType(image_desc.is_array)),
                                    0u, 0u, 0u);
                    }
                }
                const bool storage = desc.type == VideoCore::TextureCache::BindingType::Storage;
                out.writes_images |= storage;
                image->usage.storage |= storage;
                image->usage.texture |= !storage;
                texture = (__bridge id<MTLTexture>)Metal::Raw(*view.image_view);
            }
            if (!texture) {
                static std::atomic<u32> dummy_logs{0};
                if (std::getenv("TLG_METAL_LOG_DUMMY") && dummy_logs.fetch_add(1) < 40) {
                    std::printf("Dummy texture: shader %016llx image %u addr %#llx dfmt %u nfmt %u "
                                "valid_mapping %d\n",
                                (unsigned long long)info.pgm_hash, n, (unsigned long long)tsharp.Address(),
                                u32(tsharp.GetDataFmt()), u32(tsharp.GetNumberFmt()),
                                int(tsharp.Address() && memory->IsValidGpuMapping(tsharp.Address(), 0)));
                }
                const auto type = tsharp.GetViewType(image_desc.is_array);
                texture = type == AmdGpu::ImageType::Color3D ? d.dummy_3d
                          : (type == AmdGpu::ImageType::Color2DArray ||
                             type == AmdGpu::ImageType::Color1DArray)
                              ? d.dummy_2d_array
                              : d.dummy_2d;
            }
            out.textures[tslot] = texture;
        }
        binding.unified += num_bindings;
    }
    out.num_textures = tslot;
    // Samplers.
    u32 sslot = 0;
    for (const auto& sampler : info.samplers) {
        const auto ssharp = sampler.GetSharp(info);
        vk::Sampler vk_sampler = texture_cache.GetSampler(ssharp, liverpool->regs.ta_bc_base,
                                                          sampler.is_depth, 0.0f);
        if (sslot < out.samplers.size()) {
            __unsafe_unretained id<MTLSamplerState> s = (__bridge id<MTLSamplerState>)Metal::Raw(vk_sampler);
            out.samplers[sslot++] = s ? s : d.dummy_sampler;
        }
        ++binding.unified;
    }
    out.num_samplers = sslot;
    return true;
}

void Rasterizer::ResetBindings() {
    for (const auto image_id : bound_images) {
        texture_cache.GetImage(image_id).binding = {};
    }
    bound_images.clear();
}

namespace {
bool DebugFlag(const char* name) {
    const char* v = std::getenv(name);
    return v && *v == '1';
}
} // namespace

void Rasterizer::Draw(bool is_indexed, u32 index_offset, const PreparedDraw*) {
    DrawImpl(is_indexed, index_offset, nullptr);
}

void Rasterizer::DrawIndirect(bool is_indexed, VAddr arg_address, u32 offset, u32 stride,
                              u32 max_count, VAddr count_address, u16 vertex_sgpr_offset,
                              u16 instance_sgpr_offset) {
    ++draw_state->indirect_draws;
    if (max_count == 0) {
        return;
    }
    const IndirectArgs indirect{arg_address + offset, count_address, stride, max_count,
                                vertex_sgpr_offset, instance_sgpr_offset};
    DrawImpl(is_indexed, 0, &indirect);
}

void Rasterizer::DrawImpl(bool is_indexed, u32 index_offset, const IndirectArgs* indirect) {
    static const bool no_cull = DebugFlag("TLG_METAL_NOCULL");
    static const bool no_depth = DebugFlag("TLG_METAL_NODEPTH");
    static const int log_draws = [] {
        const char* v = std::getenv("TLG_METAL_LOG_DRAWS");
        return v ? std::atoi(v) : 0;
    }();
    static int logged_draws = 0;
    static const bool debug_clear = DebugFlag("TLG_METAL_DEBUG_CLEAR");
    static const bool skip_calls = DebugFlag("TLG_METAL_SKIP_CALLS");
    ++draw_state->draws;
    ++FrameLog::g_draws;
    // Diagnosis: TLG_METAL_DRAW_DELAY_NS: busy-waits that long per draw (a slower command processor).
    if (static const long delay_ns = [] {
            const char* v = std::getenv("TLG_METAL_DRAW_DELAY_NS");
            return v ? std::atol(v) : 0L;
        }();
        delay_ns > 0) {
        const auto until = std::chrono::steady_clock::now() + std::chrono::nanoseconds(delay_ns);
        while (std::chrono::steady_clock::now() < until) {
        }
    }
    scheduler.PopPendingOperations();
    const auto& regs = liverpool->regs;
    using Mode = AmdGpu::ColorControl::OperationMode;
    if (regs.color_control.mode == Mode::EliminateFastClear ||
        regs.color_control.mode == Mode::FmaskDecompress ||
        regs.color_control.mode == Mode::Resolve ||
        regs.primitive_type == AmdGpu::PrimitiveType::None) {
        ++draw_state->skipped_draws;
        return;
    }
    MTLPrimitiveType primitive;
    if (!Primitive(regs.primitive_type, primitive)) {
        ++draw_state->skipped_draws;
        ++draw_state->unsupported_primitive;
        ++draw_state->prim_counts[u32(regs.primitive_type) & 31];
        static int prim_logs = 0;
        if (prim_logs < log_draws) {
            ++prim_logs;
            const auto& cb0 = regs.color_buffers[0];
            std::printf("Skipped prim %u: n %u inst %u idx %d cb0 %#llx %ux%u stage_enable %#x\n",
                        u32(regs.primitive_type), regs.num_indices,
                        regs.num_instances.NumInstances(), int(is_indexed),
                        (unsigned long long)(cb0 ? cb0.Address() : 0),
                        cb0 ? cb0.Pitch() : 0, cb0 ? cb0.Height() : 0, regs.stage_enable.raw);
        }
        return;
    }
    const GraphicsPipeline* pipeline = pipeline_cache.GetGraphicsPipeline(
        indirect ? PipelineCache::IndirectParams{indirect->vertex_sgpr_offset,
                                                 indirect->instance_sgpr_offset, true}
                 : PipelineCache::IndirectParams{});
    if (!pipeline) {
        ++draw_state->skipped_draws;
        ++draw_state->no_pipeline;
        return;
    }
    const auto& key = pipeline->key;
    auto& d = *draw_state->impl;

    // Render targets (before resources: both may record transfers).
    struct Target {
        __unsafe_unretained id<MTLTexture> texture = nil; ///< unretained: the caches own it
        u32 level = 0, slice = 0;
        bool clear = false;
        vk::ClearValue clear_value{};
    };
    std::array<Target, AmdGpu::NUM_COLOR_BUFFERS> colors{};
    Target depth{};
    bool depth_clear = false, stencil_clear = false;
    u32 width = 16384, height = 16384;
    const bool skip_cb = regs.color_control.mode == Mode::Disable;
    for (u32 cb = 0; cb < key.num_color_attachments && !skip_cb; ++cb) {
        const auto& col_buf = regs.color_buffers[cb];
        if (!col_buf || !regs.color_target_mask.GetMask(cb) || !(key.mrt_mask & (1u << cb))) {
            continue;
        }
        VideoCore::TextureCache::ImageDesc desc{col_buf, liverpool->last_cb_extent[cb]};
        auto image_id = texture_cache.FindImage(desc);
        auto* image = &texture_cache.GetImage(image_id);
        image->binding.is_target = 1u;
        bound_images.push_back(image_id);
        texture_cache.UpdateImage(image_id);
        runtime.SetBackingSamples(image, std::max<u32>(key.color_samples[cb], 1));
        auto& view = texture_cache.FindRenderTarget(image_id, desc);
        const u32 slice = view.info.range.base.layer;
        const u32 mip = view.info.range.base.level;
        auto& t = colors[cb];
        t.clear = texture_cache.IsMetaCleared(col_buf.CmaskAddress(), slice);
        texture_cache.TouchMeta(col_buf.CmaskAddress(), slice, false);
        if (t.clear) {
            t.clear_value = LiverpoolToVK::ColorBufferClearValue(col_buf);
        }
        // The view (its format is the color buffer's); a real view starts at its level/slice.
        t.texture = (__bridge id<MTLTexture>)Metal::Raw(*view.image_view);
        const bool is_view = t.texture.parentTexture != nil;
        t.level = is_view ? 0 : mip;
        t.slice = is_view ? 0 : slice;
        image->usage.render_target = 1u;
        image->flags |= VideoCore::ImageFlagBits::GpuModified;
        width = std::min(width, std::max(image->info.size.width >> mip, 1u));
        height = std::min(height, std::max(image->info.size.height >> mip, 1u));
    }
    const auto ds_state = GetEffectiveDepthStencilState(regs);
    if (ds_state.needs_attachment) {
        const auto htile = regs.depth_htile_data_base.GetAddress();
        VideoCore::TextureCache::ImageDesc desc{regs.depth_buffer, regs.depth_view,
                                                regs.depth_control, htile,
                                                liverpool->last_db_extent};
        auto image_id = texture_cache.FindImage(desc);
        auto& image = texture_cache.GetImage(image_id);
        image.binding.is_target = 1u;
        bound_images.push_back(image_id);
        texture_cache.UpdateImage(image_id);
        auto& view = texture_cache.FindDepthTarget(image_id, desc);
        const u32 slice = view.info.range.base.layer;
        depth_clear = (regs.depth_render_control.depth_clear_enable &&
                       regs.depth_control.depth_enable && regs.depth_control.depth_write_enable) ||
                      texture_cache.IsMetaCleared(htile, slice);
        stencil_clear = regs.depth_render_control.stencil_clear_enable;
        texture_cache.TouchMeta(htile, slice, false);
        depth.texture = (__bridge id<MTLTexture>)Metal::Raw(*view.image_view);
        depth.slice = depth.texture.parentTexture != nil ? 0 : slice;
        image.usage.depth_target = true;
        image.flags |= VideoCore::ImageFlagBits::GpuModified;
        width = std::min(width, image.info.size.width);
        height = std::min(height, image.info.size.height);
    }

    // Resources.
    Shader::PushData push_data{};
    push_data.xoffset = regs.viewport_control.xoffset_enable ? regs.viewports[0].xoffset : 0.f;
    push_data.xscale = regs.viewport_control.xscale_enable ? regs.viewports[0].xscale : 1.f;
    push_data.yoffset = regs.viewport_control.yoffset_enable ? regs.viewports[0].yoffset : 0.f;
    push_data.yscale = regs.viewport_control.yscale_enable ? regs.viewports[0].yscale : 1.f;
    Shader::Backend::Bindings binding{};
    std::array<StageBindings, MaxShaderStages> stage_bindings;
    bool writes_memory = false;
    bool writes_images = false;
    for (u32 i = 0; i < MaxShaderStages; ++i) {
        if (pipeline->stages[i].info) {
            BindStage(pipeline->stages[i], binding, push_data, stage_bindings[i]);
            writes_memory |= stage_bindings[i].writes_memory;
            writes_images |= stage_bindings[i].writes_images;
        }
    }

    // Vertex buffers.
    struct VertexBinding {
        __unsafe_unretained id<MTLBuffer> buffer = nil;
        u64 offset = 0;
    };
    std::array<VertexBinding, 32> vertex_buffers{};
    u32 num_vertex_buffers = 0;
    const auto* vs_info = pipeline->Stage(SwStage::Vertex);
    if (pipeline->fetch_shader && vs_info) {
        for (const auto& attrib : pipeline->fetch_shader->attributes) {
            if (num_vertex_buffers >= vertex_buffers.size()) {
                break;
            }
            const auto sharp = attrib.GetSharp(*vs_info);
            auto& vb = vertex_buffers[num_vertex_buffers++];
            if (sharp.base_address != 0 && sharp.GetSize() != 0) {
                const u64 bytes = memory->ClampRangeSize(sharp.base_address, sharp.GetSize());
                const auto [buffer, offset] = buffer_cache.ObtainBuffer(sharp.base_address, bytes, false);
                vb.buffer = (__bridge id<MTLBuffer>)Metal::Raw(buffer->Handle());
                vb.offset = offset;
                // The skinned characters use 2-byte aligned vertex buffer offsets. Metal's
                // validation wants 4, but Apple GPUs fetch vertices in shader code and read them
                // correctly; the copy (TLG_METAL_UNALIGNED_VB=0) splits the render pass.
                static const bool direct_unaligned = [] {
                    const char* env = std::getenv("TLG_METAL_UNALIGNED_VB");
                    return !(env && env[0] == '0');
                }();
                if (offset % 4 != 0 && !direct_unaligned) {
                    // Metal wants 4-byte aligned vertex buffer offsets (the game uses 2-byte
                    // ones): an aligned copy, made on the GPU (the data may be GPU-written).
                    auto& stream = buffer_cache.GetStreamBuffer();
                    const auto [data, copy_offset] = stream.Map(Common::AlignUp(bytes, 4) + 4, 16);
                    stream.Commit();
                    id<MTLBuffer> copy = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
                    draw_state->CopyBytes(scheduler, vb.buffer, offset, copy, copy_offset, bytes);
                    vb.buffer = copy;
                    vb.offset = copy_offset;
                    ++draw_state->unaligned_vertex_buffers;
                }
            } else {
                vb.buffer = d.dummy_buffer;
            }
        }
    }
    // Debugging (TLG_METAL_DUMP_TARGETS, frame dumps): the textures of skinned draws (vertex
    // streams at 2-byte offsets, the characters).
    {
        bool skinned = false;
        if (collect_targets && pipeline->fetch_shader && vs_info) {
            for (const auto& attrib : pipeline->fetch_shader->attributes) {
                const auto sharp = attrib.GetSharp(*vs_info);
                skinned |= (sharp.base_address & 3) != 0;
            }
        }
        static const bool all_textures = DebugFlag("TLG_METAL_DUMP_ALL_TEX");
        static const bool no_textures = DebugFlag("TLG_METAL_DUMP_NO_TEX"); // pass snapshots only
        if (!no_textures && (skinned || (collect_targets && all_textures)) && frame_targets.size() < 200) {
            const auto& fs = stage_bindings[u32(SwStage::Fragment)];
            for (u32 t = 0; t < fs.num_textures; ++t) {
                id<MTLTexture> tex = fs.textures[t];
                if (!tex || tex.textureType != MTLTextureType2D || tex.width < 8) {
                    continue;
                }
                void* raw = (__bridge void*)tex;
                if (std::any_of(frame_targets.begin(), frame_targets.end(),
                                [&](const FrameTarget& f) { return f.label.find("tex") == 0 && f.texture == raw; })) {
                    continue;
                }
                char label[96];
                std::snprintf(label, sizeof(label), "tex_ps%08x_t%u_fmt%u",
                              u32(pipeline->Stage(SwStage::Fragment) ? pipeline->Stage(SwStage::Fragment)->pgm_hash : 0),
                              t, u32(tex.pixelFormat));
                frame_targets.push_back({(__bridge_retained void*)tex, label});
            }
        }
    }

    // Index buffer.
    __unsafe_unretained id<MTLBuffer> index_buffer = nil;
    u64 index_buffer_offset = 0;
    MTLIndexType index_type = MTLIndexTypeUInt16;
    if (is_indexed) {
        const bool is16 = regs.index_buffer_type.index_type == AmdGpu::IndexType::Index16;
        index_type = is16 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
        const u32 index_size = is16 ? 2 : 4;
        const VAddr address = regs.index_base_address.Address<VAddr>() + index_offset * index_size;
        const auto [buffer, offset] =
            buffer_cache.ObtainBuffer(address, u64(regs.num_indices) * index_size, false);
        index_buffer = (__bridge id<MTLBuffer>)Metal::Raw(buffer->Handle());
        index_buffer_offset = offset;
        static const bool copy_indices = [] {
            const char* env = std::getenv("TLG_METAL_COPY_INDICES");
            return env && env[0] == '1';
        }();
        if (offset % 4 != 0 || copy_indices) {
            // Metal wants 4-byte aligned index buffer offsets.
            auto& stream = buffer_cache.GetStreamBuffer();
            const u64 bytes = u64(regs.num_indices) * index_size;
            index_buffer_offset =
                stream.Copy(reinterpret_cast<const void*>(address), std::max<u64>(bytes, 4), 4);
            index_buffer = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
        }
    }

    // Indirect arguments (guest memory); a draw count clamps them into a copy first.
    __unsafe_unretained id<MTLBuffer> args_buffer = nil;
    u64 args_offset = 0;
    if (indirect) {
        const u64 bytes = u64(indirect->stride) * indirect->max_count;
        const auto [buffer, offset] = buffer_cache.ObtainBuffer(indirect->args, bytes, false);
        args_buffer = (__bridge id<MTLBuffer>)Metal::Raw(buffer->Handle());
        args_offset = offset;
        if (indirect->count) {
            const auto [count_buffer, count_offset] = buffer_cache.ObtainBuffer(indirect->count, 4, false);
            auto& stream = buffer_cache.GetStreamBuffer();
            const auto [data, copy_offset] = stream.Map(bytes, 16);
            stream.Commit();
            id<MTLBuffer> copy = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
            draw_state->ClampIndirect(scheduler, args_buffer, args_offset,
                                      (__bridge id<MTLBuffer>)Metal::Raw(count_buffer->Handle()), count_offset, copy,
                                      copy_offset, indirect->stride, indirect->max_count);
            args_buffer = copy;
            args_offset = copy_offset;
        }
    }

    // Indirect quad lists: triangle-list indices and indexed arguments made on the GPU.
    bool quad_indirect = false;
    // Experiment: TLG_METAL_SKIP_QUAD_INDIRECT=1 drops indirect quad draws (cost of the conversion).
    if (static const bool skip_qi = std::getenv("TLG_METAL_SKIP_QUAD_INDIRECT") != nullptr;
        skip_qi && indirect && regs.primitive_type == AmdGpu::PrimitiveType::QuadList) {
        ResetBindings();
        return;
    }
    // tlg: indexed indirect quads of one quad per instance (inFAMOUS's particles: guest
    // arguments {4, instances, 0, 0, 0}, the GPU writes the instance count) are drawn from the
    // guest's arguments as they are (the same layout as Metal's) as triangle strips of the
    // quad's 4 indices reordered 0 1 3 2. The conversion kernel otherwise ended the render pass
    // before each such draw (~90 per frame on the burning road: the attachments stored and
    // loaded again each time). Checked on the arguments as the CPU sees them now; anything else
    // is converted. TLG_METAL_QUAD_STRIPS=0: always convert.
    bool quad_strip = false;
    if (static const bool strips = [] {
            const char* v = std::getenv("TLG_METAL_QUAD_STRIPS");
            return !v || v[0] != '0';
        }();
        strips && indirect && is_indexed && regs.primitive_type == AmdGpu::PrimitiveType::QuadList &&
        indirect->stride >= 20 && regs.num_indices >= 4) {
        quad_strip = true;
        for (u32 i = 0; i < indirect->max_count && quad_strip; ++i) {
            const u32* a = reinterpret_cast<const u32*>(indirect->args + u64(i) * indirect->stride);
            quad_strip = a[0] == 4 && a[2] == 0;
        }
        if (quad_strip) {
            const bool is16 = index_type == MTLIndexTypeUInt16;
            const u32 index_size = is16 ? 2 : 4;
            const VAddr address = regs.index_base_address.Address<VAddr>() + index_offset * index_size;
            u32 strip[4];
            u8 bytes[16]{};
            for (u32 k = 0; k < 4; ++k) {
                strip[k] = is16 ? u32(reinterpret_cast<const u16*>(address)[k]) : reinterpret_cast<const u32*>(address)[k];
            }
            const u32 order[4] = {strip[0], strip[1], strip[3], strip[2]};
            for (u32 k = 0; k < 4; ++k) {
                if (is16) {
                    reinterpret_cast<u16*>(bytes)[k] = u16(order[k]);
                } else {
                    reinterpret_cast<u32*>(bytes)[k] = order[k];
                }
            }
            auto& stream = buffer_cache.GetStreamBuffer();
            index_buffer_offset = stream.Copy(bytes, 4 * index_size, 4);
            index_buffer = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
            primitive = MTLPrimitiveTypeTriangleStrip;
            ++draw_state->quad_strips;
        }
    }
    if (!quad_strip && indirect && regs.primitive_type == AmdGpu::PrimitiveType::QuadList) {
        const u32 max_count = indirect->max_count;
        const u32 max_quads = is_indexed ? std::max<u32>(regs.num_indices / 4, 1) : 65536;
        auto& stream = buffer_cache.GetStreamBuffer();
        const auto [args_data, new_args_offset] = stream.Map(max_count * 20, 16);
        stream.Commit();
        __unsafe_unretained id<MTLBuffer> new_args = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
        __unsafe_unretained id<MTLBuffer> new_indices = nil;
        u64 new_indices_offset = 0;
        if (is_indexed) {
            const auto [idx_data, idx_offset] = stream.Map(u64(max_quads) * 6 * 4 * max_count, 16);
            stream.Commit();
            new_indices = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
            new_indices_offset = idx_offset;
        } else {
            new_indices = draw_state->QuadIndices(max_quads);
        }
        draw_state->ConvertQuadIndirect(scheduler, args_buffer, args_offset, indirect->stride,
                                        max_count, is_indexed, index_buffer, index_buffer_offset,
                                        index_type == MTLIndexTypeUInt16, max_quads, new_args,
                                        new_args_offset, new_indices, new_indices_offset);
        // Diagnosis: TLG_METAL_LOG_INDIRECT=<ps hash>: the guest and converted arguments of that
        // shader's indirect quad draws, read back when the GPU is done (200 at most).
        static const u64 log_ind = [] {
            const char* v = std::getenv("TLG_METAL_LOG_INDIRECT");
            return v ? std::strtoull(v, nullptr, 16) : 0ull;
        }();
        if (log_ind && pipeline->Stage(SwStage::Fragment) &&
            u32(pipeline->Stage(SwStage::Fragment)->pgm_hash) == u32(log_ind)) {
            static std::atomic<u32> logged{0};
            if (logged.fetch_add(1) < 5000) {
                id<MTLBuffer> src = args_buffer, dst = new_args;
                const u64 so = args_offset, dof = new_args_offset;
                const u32 stride = indirect->stride, n = max_count;
                const u32 vsgpr = indirect->vertex_sgpr_offset, isgpr = indirect->instance_sgpr_offset;
                const bool idx = is_indexed;
                const u64 guest_args = indirect->args;
                scheduler.SignalOnCompletion([src, dst, so, dof, stride, n, vsgpr, isgpr, idx, guest_args] {
                    for (u32 i = 0; i < n && i < 4; ++i) {
                        const u32* a = reinterpret_cast<const u32*>(static_cast<const u8*>(src.contents) + so + u64(i) * stride);
                        const u32* d = reinterpret_cast<const u32*>(static_cast<const u8*>(dst.contents) + dof + u64(i) * 20);
                        static std::atomic<u32> printed{0};
                        if (a[1] == 0 && printed.fetch_add(1) >= 20) {
                            continue;
                        }
                        std::printf("indirect quad @%#llx %u/%u idx %d stride %u sgpr v%u i%u: guest %u %u %u %u %u -> %u %u %u %u %u\n",
                                    (unsigned long long)guest_args, i, n, idx, stride, vsgpr, isgpr, a[0], a[1], a[2], a[3], stride >= 20 ? a[4] : 0,
                                    d[0], d[1], d[2], d[3], d[4]);
                    }
                });
            }
        }
        args_buffer = new_args;
        args_offset = new_args_offset;
        index_buffer = new_indices;
        index_buffer_offset = new_indices_offset;
        index_type = MTLIndexTypeUInt32;
        quad_indirect = true;
    }

    // The render pass: kept open while the attachments are the same and nothing is cleared.
    std::array<AttachmentKey, 9> pass{};
    bool any_clear = depth_clear || stencil_clear;
    for (u32 cb = 0; cb < colors.size(); ++cb) {
        pass[cb] = {(__bridge void*)colors[cb].texture, colors[cb].level, colors[cb].slice};
        any_clear |= colors[cb].clear;
    }
    pass[8] = {(__bridge void*)depth.texture, 0, depth.slice};
    // tlg: a draw with no attachments that writes no memory and no storage image has no
    // visible effect (occlusion queries are not counted on Metal): not recorded. Each was a render pass of its own and
    // ended the pass around it (~9 a frame in the cannery, ~2 encoders each).
    // TLG_METAL_KEEP_NOOP_DRAWS=1 records them.
    static const bool keep_noop = DebugFlag("TLG_METAL_KEEP_NOOP_DRAWS");
    if (!keep_noop && !writes_memory && !writes_images && !any_clear &&
        std::all_of(pass.begin(), pass.end(), [](const AttachmentKey& a) { return !a.texture; })) {
        ++draw_state->noop_draws;
        ResetBindings();
        return;
    }
    // The open render encoder is this draw path's (key 1), as recorded.
    const bool pass_is_open = scheduler.OpenKind() == Scheduler::Kind::Render && scheduler.RenderPassKey() == 1;
    const bool same_pass = pass_is_open && d.pass_open && !any_clear &&
                           std::memcmp(pass.data(), d.pass.data(), sizeof(pass)) == 0;
    // tlg: commit at a pass boundary once enough draws were recorded, so the GPU starts on
    // them while the command processor records the rest of the frame (the game waits for each
    // frame's end-of-pipe label: GPU and recording time used to add up). Only between passes:
    // splitting one would store and reload its tiles. TLG_METAL_COMMIT_DRAWS (0 = off).
    static const u32 commit_draws = [] {
        const char* env = std::getenv("TLG_METAL_COMMIT_DRAWS");
        return env ? u32(std::strtoul(env, nullptr, 0)) : 400u;
    }();
    if (!same_pass && commit_draws && d.since_commit >= commit_draws) {
        scheduler.Flush();
        d.since_commit = 0;
    }
    ++d.since_commit;
    if (!same_pass && pass_is_open && MetalScheduler::PassStatsEnabled()) {
        if (any_clear) {
            MetalScheduler::NoteRenderBreak(scheduler, "draw_clear");
        } else {
            // Which attachments changed: colour, depth, both; a subset (the new draw binds
            // fewer of the open pass's attachments) or a superset; only a level/slice.
            bool color_diff = false, depth_diff = false, subset = true, superset = true,
                 same_textures = true;
            for (u32 i = 0; i < 9; ++i) {
                const auto& a = d.pass[i];
                const auto& b = pass[i];
                const bool diff = a.texture != b.texture || a.level != b.level || a.slice != b.slice;
                (i == 8 ? depth_diff : color_diff) |= diff;
                same_textures &= a.texture == b.texture;
                if (diff && b.texture) {
                    subset = false;
                }
                if (diff && a.texture) {
                    superset = false;
                }
            }
            bool none = true;
            for (u32 i = 0; i < 9; ++i) {
                none &= pass[i].texture == nullptr;
            }
            const char* why = none ? (writes_memory ? "draw_no_targets_writes" : "draw_no_targets")
                              : same_textures ? "draw_targets_levelslice"
                              : subset      ? "draw_targets_subset"
                              : superset    ? "draw_targets_superset"
                              : color_diff && depth_diff ? "draw_targets_both"
                              : color_diff               ? "draw_targets_color"
                                                         : "draw_targets_depth";
            MetalScheduler::NoteRenderBreak(scheduler, why);
        }
    }
    if (!same_pass) {
        if (NanScan::Active()) {
            std::array<id<MTLTexture>, 8> nan_targets{};
            for (u32 cb = 0; cb < colors.size() && cb < 8; ++cb) {
                nan_targets[cb] = colors[cb].texture;
            }
            NanScan::BeginPass(scheduler, draw_state->draws, nan_targets.data(), 8);
        }
        // TLG_METAL_DUMP_PASS_FROM=<n>: skip the first n passes of the frame (late passes:
        // particles, transparency); 96 snapshots at most.
        static const u32 pass_from = [] {
            const char* v = std::getenv("TLG_METAL_DUMP_PASS_FROM");
            return v ? u32(std::strtoul(v, nullptr, 0)) : 0u;
        }();
        static u32 frame_pass = 0;
        if (!collect_targets) {
            frame_pass = 0;
        } else {
            ++frame_pass;
        }
        static const size_t pass_max = [] {
            const char* v = std::getenv("TLG_METAL_DUMP_PASS_MAX");
            return v ? size_t(std::strtoul(v, nullptr, 0)) : size_t(96);
        }();
        if (collect_targets && frame_pass > pass_from && frame_targets.size() < pass_max) {
            // Debugging: copies of the targets of each pass (taken before this pass).
            scheduler.EndEncoding();
            for (u32 cb = 0; cb < colors.size(); ++cb) {
                if (!colors[cb].texture || colors[cb].texture.textureType != MTLTextureType2D) {
                    continue;
                }
                id<MTLTexture> src = colors[cb].texture;
                MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                              width:src.width
                                                                                             height:src.height
                                                                                          mipmapped:NO];
                td.usage = MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModePrivate;
                id<MTLTexture> snap = [Metal::Device() newTextureWithDescriptor:td];
                snapshots_pending.push_back({(__bridge_retained void*)src, (__bridge_retained void*)snap,
                                             cb, draw_state->draws});
            }
            if (depth.texture && depth.texture.textureType == MTLTextureType2D &&
                depth.texture.pixelFormat == MTLPixelFormatDepth32Float) {
                id<MTLTexture> src = depth.texture;
                MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                              width:src.width
                                                                                             height:src.height
                                                                                          mipmapped:NO];
                td.usage = MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModePrivate;
                id<MTLTexture> snap = [Metal::Device() newTextureWithDescriptor:td];
                snapshots_pending.push_back({(__bridge_retained void*)src, (__bridge_retained void*)snap,
                                             8, draw_state->draws});
            }
        }
        // Copies of the previous pass's targets are taken now (their content is final).
        if (!snapshots_pending.empty()) {
            for (auto& p : snapshots_pending) {
                if (p.draw == draw_state->draws) {
                    continue;
                }
                id<MTLTexture> src = (__bridge_transfer id<MTLTexture>)p.src;
                id<MTLTexture> snap = (__bridge id<MTLTexture>)p.snap;
                scheduler.EndEncoding();
                MetalScheduler::RecordBlit(scheduler, "snapshot", [src, snap](id<MTLBlitCommandEncoder> blit) {
                    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
                             sourceOrigin:MTLOriginMake(0, 0, 0)
                               sourceSize:MTLSizeMake(src.width, src.height, 1)
                                toTexture:snap destinationSlice:0
                         destinationLevel:0
                        destinationOrigin:MTLOriginMake(0, 0, 0)];
                });
                char label[96];
                std::snprintf(label, sizeof(label), "pass%llu_cb%u_%u", (unsigned long long)p.draw, p.cb,
                              u32(src.pixelFormat));
                frame_targets.push_back({p.snap, label});
                p.src = nullptr;
            }
            std::erase_if(snapshots_pending, [](const PendingSnap& p) { return p.src == nullptr; });
            scheduler.EndEncoding();
        }
        PassDesc pd{};
        for (u32 cb = 0; cb < colors.size() && cb < pd.colors.size(); ++cb) {
            const auto& t = colors[cb];
            if (!t.texture) {
                continue;
            }
            auto& c = pd.colors[cb];
            c.texture = (__bridge void*)t.texture;
            c.level = t.level;
            c.slice = t.slice;
            c.is_3d = t.texture.textureType == MTLTextureType3D;
            c.clear = t.clear || debug_clear;
            if (debug_clear) {
                c.clear_color[0] = 1, c.clear_color[1] = 0, c.clear_color[2] = 1, c.clear_color[3] = 1;
            } else if (t.clear) {
                const auto& v = t.clear_value.color.float32;
                c.clear_color[0] = v[0], c.clear_color[1] = v[1], c.clear_color[2] = v[2], c.clear_color[3] = v[3];
            }
        }
        if (depth.texture) {
            const MTLPixelFormat pf = depth.texture.pixelFormat;
            pd.depth = (__bridge void*)depth.texture;
            pd.depth_slice = depth.slice;
            pd.has_depth = pf != MTLPixelFormatStencil8;
            pd.has_stencil = pf == MTLPixelFormatDepth32Float_Stencil8 || pf == MTLPixelFormatStencil8;
            pd.depth_clear = depth_clear;
            pd.stencil_clear = stencil_clear;
            pd.clear_depth = regs.depth_clear;
            pd.clear_stencil = regs.stencil_clear;
        }
        if (!depth.texture && std::none_of(colors.begin(), colors.end(),
                                           [](const Target& t) { return t.texture != nil; })) {
            // No attachments (pixel shader side effects only).
            pd.no_attachments = true;
            pd.width = width == 16384 ? 1 : width;
            pd.height = height == 16384 ? 1 : height;
            pd.samples = std::max<u32>(key.num_samples, 1);
        }
        MetalScheduler::BeginRender(scheduler, 1, [pd] { return pd.Build(); });
        d.pass = pass;
        d.pass_open = true;
        d.pass_width = width == 16384 ? 1 : width;
        d.pass_height = height == 16384 ? 1 : height;
        ++draw_state->passes;
        label_pass_draws = 0;
        label_pass_verts = 0;
    }
    if (MetalScheduler::LabelMode()) {
        // Profiling: the pass's size, attachment formats, draws and vertices so far.
        label_pass_draws += 1;
        label_pass_verts += u64(regs.num_indices) * std::max<u32>(regs.num_instances.NumInstances(), 1);
        char label[160];
        std::snprintf(label, sizeof(label), "rp %ux%u c%u d%u draws=%u verts=%llu", d.pass_width,
                      d.pass_height, colors[0].texture ? u32(colors[0].texture.pixelFormat) : 0,
                      depth.texture ? u32(depth.texture.pixelFormat) : 0, label_pass_draws,
                      (unsigned long long)label_pass_verts);
        MetalScheduler::RecordRender(scheduler, [name = std::string(label)](id<MTLRenderCommandEncoder> enc) {
            enc.label = [NSString stringWithUTF8String:name.c_str()];
        });
    }

    // State (only what changed on this encoder: d.ec).
    static const bool state_cache = [] {
        const char* v = std::getenv("TLG_METAL_STATE_CACHE");
        return !v || v[0] != '0';
    }();
    auto& ec = d.ec;
    if (!state_cache || ec.count != scheduler.EncoderCount()) {
        ec = {};
        ec.count = scheduler.EncoderCount();
    }
    if (ec.pso != pipeline->pso) {
        void* const pso = pipeline->pso;
        MetalScheduler::RecordRender(scheduler, [pso](id<MTLRenderCommandEncoder> enc) {
            [enc setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)pso];
        });
        ec.pso = pipeline->pso;
    }
    const auto set_buffer = [&](int st, __unsafe_unretained id<MTLBuffer> buffer, u64 offset, u32 index) {
        if (index < 32 && ec.buf[st][index] == (__bridge void*)buffer && ec.off[st][index] == offset) {
            return;
        }
        void* const raw = (__bridge void*)buffer;
        if (st == 0) {
            MetalScheduler::RecordRender(scheduler, [raw, offset, index](id<MTLRenderCommandEncoder> enc) {
                [enc setVertexBuffer:(__bridge id<MTLBuffer>)raw offset:offset atIndex:index];
            });
        } else {
            MetalScheduler::RecordRender(scheduler, [raw, offset, index](id<MTLRenderCommandEncoder> enc) {
                [enc setFragmentBuffer:(__bridge id<MTLBuffer>)raw offset:offset atIndex:index];
            });
        }
        if (index < 32) {
            ec.buf[st][index] = (__bridge void*)buffer;
            ec.off[st][index] = offset;
        }
        if (index == BufferSizesBufferIndex) {
            ec.sizes_valid[st] = false;
        } else if (index == PushDataBufferIndex) {
            ec.push_valid[st] = false;
        }
    };
    const auto bind = [&](const StageBindings& b, bool vertex) {
        const int st = vertex ? 0 : 1;
        for (u32 i = 0; i < b.num_buffers; ++i) {
            set_buffer(st, b.buffers[i], b.offsets[i], i);
        }
        if (b.num_textures &&
            std::memcmp(ec.tex[st], b.textures.data(), sizeof(void*) * b.num_textures) != 0) {
            const u32 n = b.num_textures;
            MetalScheduler::RecordRenderWith(scheduler, b.textures.data(), sizeof(void*) * n,
                                             [vertex, n](id<MTLRenderCommandEncoder> enc, const void* copy) {
                const auto* textures = static_cast<__unsafe_unretained id<MTLTexture> const*>(copy);
                if (vertex) {
                    [enc setVertexTextures:textures withRange:NSMakeRange(0, n)];
                } else {
                    [enc setFragmentTextures:textures withRange:NSMakeRange(0, n)];
                }
            });
            std::memcpy(ec.tex[st], b.textures.data(), sizeof(void*) * b.num_textures);
        }
        if (b.num_samplers &&
            std::memcmp(ec.smp[st], b.samplers.data(), sizeof(void*) * b.num_samplers) != 0) {
            const u32 n = b.num_samplers;
            MetalScheduler::RecordRenderWith(scheduler, b.samplers.data(), sizeof(void*) * n,
                                             [vertex, n](id<MTLRenderCommandEncoder> enc, const void* copy) {
                const auto* samplers = static_cast<__unsafe_unretained id<MTLSamplerState> const*>(copy);
                if (vertex) {
                    [enc setVertexSamplerStates:samplers withRange:NSMakeRange(0, n)];
                } else {
                    [enc setFragmentSamplerStates:samplers withRange:NSMakeRange(0, n)];
                }
            });
            std::memcpy(ec.smp[st], b.samplers.data(), sizeof(void*) * b.num_samplers);
        }
        if (!ec.sizes_valid[st] || std::memcmp(ec.sizes[st], b.sizes.data(), sizeof(u32) * 32) != 0) {
            MetalScheduler::RecordRenderWith(scheduler, b.sizes.data(), sizeof(u32) * 32,
                                             [vertex](id<MTLRenderCommandEncoder> enc, const void* copy) {
                if (vertex) {
                    [enc setVertexBytes:copy length:sizeof(u32) * 32 atIndex:BufferSizesBufferIndex];
                } else {
                    [enc setFragmentBytes:copy length:sizeof(u32) * 32 atIndex:BufferSizesBufferIndex];
                }
            });
            std::memcpy(ec.sizes[st], b.sizes.data(), sizeof(u32) * 32);
            ec.sizes_valid[st] = true;
            ec.buf[st][BufferSizesBufferIndex] = nullptr;
        }
        if (!ec.push_valid[st] || std::memcmp(&ec.push[st], &push_data, sizeof(push_data)) != 0) {
            MetalScheduler::RecordRenderWith(scheduler, &push_data, sizeof(push_data),
                                             [vertex](id<MTLRenderCommandEncoder> enc, const void* copy) {
                if (vertex) {
                    [enc setVertexBytes:copy length:sizeof(Shader::PushData) atIndex:PushDataBufferIndex];
                } else {
                    [enc setFragmentBytes:copy length:sizeof(Shader::PushData) atIndex:PushDataBufferIndex];
                }
            });
            std::memcpy(&ec.push[st], &push_data, sizeof(push_data));
            ec.push_valid[st] = true;
            ec.buf[st][PushDataBufferIndex] = nullptr;
        }
    };
    bind(stage_bindings[u32(SwStage::Vertex)], true);
    if (pipeline->stages[u32(SwStage::Fragment)].info) {
        bind(stage_bindings[u32(SwStage::Fragment)], false);
    }
    for (u32 i = 0; i < num_vertex_buffers; ++i) {
        set_buffer(0, vertex_buffers[i].buffer, vertex_buffers[i].offset,
                   pipeline->vertex_buffer_base + i);
    }

    // Viewport and scissor.
    {
        const auto& vp = regs.viewports[0];
        const auto& vp_ctl = regs.viewport_control;
        MTLViewport viewport;
        const float zoffset = vp_ctl.zoffset_enable ? vp.zoffset : 0.f;
        const float zscale = vp_ctl.zscale_enable ? vp.zscale : 1.f;
        if (regs.clipper_control.clip_space == AmdGpu::ClipSpace::MinusWToW) {
            viewport.znear = zoffset - zscale;
            viewport.zfar = zoffset + zscale;
        } else {
            viewport.znear = zoffset;
            viewport.zfar = zoffset + zscale;
        }
        viewport.znear = std::clamp(viewport.znear, 0.0, 1.0);
        viewport.zfar = std::clamp(viewport.zfar, 0.0, 1.0);
        if (regs.IsClipDisabled() || vp.xscale == 0) {
            // Clip disabled: positions are screen coordinates over [0, 16384) (y down).
            viewport.originX = 0;
            viewport.originY = 16384;
            viewport.width = 16384;
            viewport.height = -16384;
        } else {
            const float xoffset = vp_ctl.xoffset_enable ? vp.xoffset : 0.f;
            const float xscale = vp_ctl.xscale_enable ? vp.xscale : 1.f;
            const float yoffset = vp_ctl.yoffset_enable ? vp.yoffset : 0.f;
            const float yscale = vp_ctl.yscale_enable ? vp.yscale : 1.f;
            // Vulkan maps clip y = -1 to the top (vy), Metal maps +1 to the top: the same window
            // positions need originY = vy + vh and height = -vh. The PS4's negative y scale
            // gives a positive height.
            const float vy = yoffset - yscale;
            const float vh = yscale * 2.0f;
            viewport.originX = xoffset - xscale;
            viewport.width = xscale * 2.0f;
            viewport.originY = vy + vh;
            viewport.height = -vh;
        }
        if (!ec.viewport_valid || std::memcmp(&ec.viewport, &viewport, sizeof(viewport)) != 0) {
            MetalScheduler::RecordRender(scheduler, [viewport](id<MTLRenderCommandEncoder> enc) {
                [enc setViewport:viewport];
            });
            ec.viewport = viewport;
            ec.viewport_valid = true;
        }

        const auto tl = [](s16 scr, s16 win, s16 gen, s16 off) {
            return std::max({scr, s16(win + off), s16(gen + off)});
        };
        const auto br = [](s16 scr, s16 win, s16 gen, s16 off) {
            return std::min({scr, s16(win + off), s16(gen + off)});
        };
        const bool offset = !regs.window_scissor.window_offset_disable;
        const s16 ox = offset ? regs.window_offset.window_x_offset : 0;
        const s16 oy = offset ? regs.window_offset.window_y_offset : 0;
        s32 x0 = tl(regs.screen_scissor.top_left_x, s16(regs.window_scissor.top_left_x),
                    s16(regs.generic_scissor.top_left_x), ox);
        s32 y0 = tl(regs.screen_scissor.top_left_y, s16(regs.window_scissor.top_left_y),
                    s16(regs.generic_scissor.top_left_y), oy);
        s32 x1 = br(regs.screen_scissor.bottom_right_x, regs.window_scissor.bottom_right_x,
                    regs.generic_scissor.bottom_right_x, ox);
        s32 y1 = br(regs.screen_scissor.bottom_right_y, regs.window_scissor.bottom_right_y,
                    regs.generic_scissor.bottom_right_y, oy);
        if (regs.mode_control.vport_scissor_enable) {
            x0 = std::max<s32>(x0, regs.viewport_scissors[0].top_left_x);
            y0 = std::max<s32>(y0, regs.viewport_scissors[0].top_left_y);
            x1 = std::min<s32>(x1, regs.viewport_scissors[0].bottom_right_x);
            y1 = std::min<s32>(y1, regs.viewport_scissors[0].bottom_right_y);
        }
        x0 = std::clamp<s32>(x0, 0, d.pass_width);
        y0 = std::clamp<s32>(y0, 0, d.pass_height);
        x1 = std::clamp<s32>(x1, x0, d.pass_width);
        y1 = std::clamp<s32>(y1, y0, d.pass_height);
        static int scissor_logs = 0;
        if (scissor_logs < log_draws) {
            ++scissor_logs;
            std::printf("  scissor %d,%d-%d,%d pass %ux%u viewport %.1f,%.1f %.1fx%.1f z %.2f-%.2f "
                        "screen %d,%d-%d,%d window %d,%d-%d,%d generic %d,%d-%d,%d\n",
                        x0, y0, x1, y1, d.pass_width, d.pass_height, viewport.originX,
                        viewport.originY, viewport.width, viewport.height, viewport.znear,
                        viewport.zfar, regs.screen_scissor.top_left_x, regs.screen_scissor.top_left_y,
                        regs.screen_scissor.bottom_right_x, regs.screen_scissor.bottom_right_y,
                        regs.window_scissor.top_left_x, regs.window_scissor.top_left_y,
                        regs.window_scissor.bottom_right_x, regs.window_scissor.bottom_right_y,
                        regs.generic_scissor.top_left_x, regs.generic_scissor.top_left_y,
                        regs.generic_scissor.bottom_right_x, regs.generic_scissor.bottom_right_y);
        }
        if (x1 <= x0 || y1 <= y0) {
            ResetBindings();
            return; // nothing visible
        }
        const MTLScissorRect scissor{NSUInteger(x0), NSUInteger(y0), NSUInteger(x1 - x0),
                                     NSUInteger(y1 - y0)};
        if (!ec.scissor_valid || std::memcmp(&ec.scissor, &scissor, sizeof(scissor)) != 0) {
            MetalScheduler::RecordRender(scheduler, [scissor](id<MTLRenderCommandEncoder> enc) {
                [enc setScissorRect:scissor];
            });
            ec.scissor = scissor;
            ec.scissor_valid = true;
        }
    }

    // Rasterization.
    const bool culled = LiverpoolToVK::IsPrimitiveCulled(regs.primitive_type);
    const auto cull = culled ? LiverpoolToVK::CullMode(regs.polygon_control.CullingMode())
                             : vk::CullModeFlags{};
    if (cull == vk::CullModeFlagBits::eFrontAndBack) {
        ResetBindings();
        return;
    }
    const MTLCullMode cull_mode = no_cull ? MTLCullModeNone
                                  : cull == vk::CullModeFlagBits::eFront ? MTLCullModeFront
                                  : cull == vk::CullModeFlagBits::eBack ? MTLCullModeBack
                                                                         : MTLCullModeNone;
    if (ec.cull != int(cull_mode)) {
        MetalScheduler::RecordRender(scheduler, [cull_mode](id<MTLRenderCommandEncoder> enc) {
            [enc setCullMode:cull_mode];
        });
        ec.cull = int(cull_mode);
    }
    // Window positions match Vulkan's (viewport above), so does the winding.
    const MTLWinding winding = LiverpoolToVK::FrontFace(regs.polygon_control.front_face) ==
                                       vk::FrontFace::eClockwise
                                   ? MTLWindingClockwise
                                   : MTLWindingCounterClockwise;
    if (ec.winding != int(winding)) {
        MetalScheduler::RecordRender(scheduler, [winding](id<MTLRenderCommandEncoder> enc) {
            [enc setFrontFacingWinding:winding];
        });
        ec.winding = int(winding);
    }
    const MTLTriangleFillMode fill = regs.polygon_control.PolyMode() == AmdGpu::PolygonMode::Fill
                                         ? MTLTriangleFillModeFill
                                         : MTLTriangleFillModeLines;
    if (ec.fill != int(fill)) {
        MetalScheduler::RecordRender(scheduler, [fill](id<MTLRenderCommandEncoder> enc) {
            [enc setTriangleFillMode:fill];
        });
        ec.fill = int(fill);
    }
    const bool clamp = !regs.depth_render_override.disable_viewport_clamp;
    const MTLDepthClipMode clip = (!regs.clipper_control.ZclipEnable() && clamp) ? MTLDepthClipModeClamp
                                                                                 : MTLDepthClipModeClip;
    if (ec.clip != int(clip)) {
        MetalScheduler::RecordRender(scheduler, [clip](id<MTLRenderCommandEncoder> enc) {
            [enc setDepthClipMode:clip];
        });
        ec.clip = int(clip);
    }
    float bias[3] = {0, 0, 0};
    if (regs.polygon_control.NeedsBias()) {
        const bool front = regs.polygon_control.enable_polygon_offset_front;
        const float slope = front ? regs.poly_offset.front_scale : regs.poly_offset.back_scale;
        const float constant = front ? regs.poly_offset.front_offset : regs.poly_offset.back_offset;
        bias[0] = constant;
        bias[1] = slope / 16.f;
        bias[2] = regs.poly_offset.depth_bias;
    }
    if (!ec.bias_valid || std::memcmp(ec.bias, bias, sizeof(bias)) != 0) {
        const std::array<float, 3> bv = {bias[0], bias[1], bias[2]};
        MetalScheduler::RecordRender(scheduler, [bv](id<MTLRenderCommandEncoder> enc) {
            [enc setDepthBias:bv[0] slopeScale:bv[1] clamp:bv[2]];
        });
        std::memcpy(ec.bias, bias, sizeof(bias));
        ec.bias_valid = true;
    }
    const float blend[4] = {regs.blend_constants[0], regs.blend_constants[1],
                            regs.blend_constants[2], regs.blend_constants[3]};
    if (!ec.blend_valid || std::memcmp(ec.blend, blend, sizeof(blend)) != 0) {
        const std::array<float, 4> bc = {blend[0], blend[1], blend[2], blend[3]};
        MetalScheduler::RecordRender(scheduler, [bc](id<MTLRenderCommandEncoder> enc) {
            [enc setBlendColorRed:bc[0] green:bc[1] blue:bc[2] alpha:bc[3]];
        });
        std::memcpy(ec.blend, blend, sizeof(blend));
        ec.blend_valid = true;
    }

    // Depth and stencil.
    {
        const bool depth_test = ds_state.depth_test_enable && depth.texture && !no_depth;
        const bool depth_write = ds_state.depth_write_enable && depth.texture &&
                                 !regs.depth_render_control.depth_clear_enable;
        const bool stencil = ds_state.stencil_test_enable && depth.texture;
        const auto& sc = regs.stencil_control;
        const auto front = regs.stencil_ref_front;
        const auto back = regs.depth_control.backface_enable ? regs.stencil_ref_back : front;
        const bool stencil_clear_now = regs.depth_render_control.stencil_clear_enable;
        const u32 front_write = stencil_clear_now ? 0u : front.stencil_write_mask;
        const u32 back_write = stencil_clear_now ? 0u : back.stencil_write_mask;
        const auto back_func = regs.depth_control.backface_enable ? regs.depth_control.stencil_bf_func
                                                                  : regs.depth_control.stencil_ref_func;
        const auto back_fail = regs.depth_control.backface_enable ? sc.stencil_fail_back : sc.stencil_fail_front;
        const auto back_zpass = regs.depth_control.backface_enable ? sc.stencil_zpass_back : sc.stencil_zpass_front;
        const auto back_zfail = regs.depth_control.backface_enable ? sc.stencil_zfail_back : sc.stencil_zfail_front;
        struct Face {
            MTLStencilOperation fail, pass, zfail;
            MTLCompareFunction func;
            u32 reference, read_mask, write_mask;
        };
        const auto setup = [](AmdGpu::CompareFunc func, const AmdGpu::StencilRefMask& ref,
                              u32 write_mask, AmdGpu::StencilFunc fail, AmdGpu::StencilFunc zpass,
                              AmdGpu::StencilFunc zfail) {
            Face f{};
            f.func = Compare(LiverpoolToVK::CompareOp(func));
            f.read_mask = ref.stencil_mask;
            f.write_mask = write_mask;
            if (const auto r = ResolveStencilFace(func, ref, write_mask, fail, zpass, zfail)) {
                f.fail = Stencil(r->fail_op);
                f.pass = Stencil(r->pass_op);
                f.zfail = Stencil(r->depth_fail_op);
                f.reference = r->reference;
            } else {
                f.fail = Stencil(LiverpoolToVK::StencilOp(fail));
                f.pass = Stencil(LiverpoolToVK::StencilOp(zpass));
                f.zfail = Stencil(LiverpoolToVK::StencilOp(zfail));
                const bool uses_op_val = fail == AmdGpu::StencilFunc::ReplaceOp ||
                                         zpass == AmdGpu::StencilFunc::ReplaceOp ||
                                         zfail == AmdGpu::StencilFunc::ReplaceOp;
                f.reference = uses_op_val ? ref.stencil_op_val : ref.stencil_test_val;
            }
            return f;
        };
        Face ff{}, bf{};
        if (stencil) {
            ff = setup(regs.depth_control.stencil_ref_func, front, front_write, sc.stencil_fail_front,
                       sc.stencil_zpass_front, sc.stencil_zfail_front);
            bf = regs.depth_control.backface_enable
                     ? setup(back_func, back, back_write, back_fail, back_zpass, back_zfail)
                     : ff;
        }
        u64 ds_key = u64(depth_test) | u64(depth_write) << 1 | u64(stencil) << 2 |
                     u64(regs.depth_control.depth_func) << 3;
        if (stencil) {
            const auto face_bits = [](const Face& f) {
                return u64(f.fail) | u64(f.pass) << 3 | u64(f.zfail) << 6 | u64(f.func) << 9 |
                       u64(f.read_mask & 0xff) << 12 | u64(f.write_mask & 0xff) << 20;
            };
            ds_key |= face_bits(ff) << 6;
            ds_key ^= face_bits(bf) * 0x9E3779B97F4A7C15ull;
            ds_key |= 4;
        }
        auto& ds = d.depth_states[ds_key];
        if (!ds) {
            MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
            dd.depthCompareFunction =
                depth_test ? Compare(LiverpoolToVK::CompareOp(regs.depth_control.depth_func))
                           : MTLCompareFunctionAlways;
            dd.depthWriteEnabled = depth_write;
            if (stencil) {
                const auto make = [](const Face& face) {
                    MTLStencilDescriptor* sdesc = [MTLStencilDescriptor new];
                    sdesc.stencilCompareFunction = face.func;
                    sdesc.stencilFailureOperation = face.fail;
                    sdesc.depthStencilPassOperation = face.pass;
                    sdesc.depthFailureOperation = face.zfail;
                    sdesc.readMask = face.read_mask;
                    sdesc.writeMask = face.write_mask;
                    return sdesc;
                };
                dd.frontFaceStencil = make(ff);
                dd.backFaceStencil = make(bf);
            }
            ds = [Metal::Device() newDepthStencilStateWithDescriptor:dd];
        }
        if (ec.ds != (__bridge void*)ds) {
            void* const raw = (__bridge void*)ds;
            MetalScheduler::RecordRender(scheduler, [raw](id<MTLRenderCommandEncoder> enc) {
                [enc setDepthStencilState:(__bridge id<MTLDepthStencilState>)raw];
            });
            ec.ds = (__bridge void*)ds;
        }
        if (stencil && (!ec.sref_valid || ec.sref[0] != ff.reference || ec.sref[1] != bf.reference)) {
            const u32 fr = ff.reference, br = bf.reference;
            MetalScheduler::RecordRender(scheduler, [fr, br](id<MTLRenderCommandEncoder> enc) {
                [enc setStencilFrontReferenceValue:fr backReferenceValue:br];
            });
            ec.sref[0] = ff.reference;
            ec.sref[1] = bf.reference;
            ec.sref_valid = true;
        }
    }

    // Diagnosis: TLG_METAL_DRAW_HIST=1 prints, once a second, the draws of each vs/ps pair in that
    // second (i: indirect), to find the effects drawn at a given moment at full speed.
    if (static const bool hist = std::getenv("TLG_METAL_DRAW_HIST") != nullptr; hist) {
        static std::unordered_map<u64, std::pair<u32, u32>> counts;
        static auto t0 = std::chrono::steady_clock::now();
        static int last_sec = 0;
        const u64 vsh = pipeline->Stage(SwStage::Vertex) ? u32(pipeline->Stage(SwStage::Vertex)->pgm_hash) : 0;
        const u64 psh = pipeline->Stage(SwStage::Fragment) ? u32(pipeline->Stage(SwStage::Fragment)->pgm_hash) : 0;
        auto& c = counts[(vsh << 32) | psh];
        ++c.first;
        c.second |= indirect ? 1u : 0u;
        // Characters: vertex streams at 2-byte offsets (skinned meshes), tagged "s".
        if (pipeline->fetch_shader && vs_info) {
            for (const auto& attrib : pipeline->fetch_shader->attributes) {
                if ((attrib.GetSharp(*vs_info).base_address & 3) != 0) {
                    c.second |= 2u;
                    break;
                }
            }
        }
        const int sec = int(std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
        if (sec != last_sec) {
            std::string line;
            for (const auto& [k, v] : counts) {
                char b[64];
                std::snprintf(b, sizeof(b), " %08x/%08x:%u%s%s", u32(k >> 32), u32(k), v.first,
                              (v.second & 1) ? "i" : "", (v.second & 2) ? "s" : "");
                line += b;
            }
            std::printf("draw hist t=%d:%s\n", last_sec, line.c_str());
            counts.clear();
            last_sec = sec;
        }
    }
    if (FrameLog::Enabled() && pipeline->Stage(SwStage::Fragment)) {
        // Draws count under the pixel shader's hash with a "p" prefix (dispatches: none).
        FrameLog::NoteDispatch(pipeline->Stage(SwStage::Fragment)->pgm_hash | (1ull << 63), 0, false);
    }
    if (NanScan::Active() && pipeline->Stage(SwStage::Fragment)) {
        const u64 vs_hash = pipeline->Stage(SwStage::Vertex) ? pipeline->Stage(SwStage::Vertex)->pgm_hash : 0;
        NanScan::NoteDraw(NanScan::PerDraw() ? (vs_hash << 32) | u32(pipeline->Stage(SwStage::Fragment)->pgm_hash)
                                             : pipeline->Stage(SwStage::Fragment)->pgm_hash);
    }
    if (logged_draws < log_draws) {
        ++logged_draws;
        const auto& vp = regs.viewports[0];
        std::printf("Draw %d: cb0 %#llx tex %p vs %016llx ps %016llx prim %u n %u inst %u idx %d rt0 %ux%u fmt %u "
                    "depth %d samples %u vp xo %.1f xs %.1f yo %.1f ys %.1f zs %.2f zo %.2f "
                    "clip_disabled %d cull %u ff %u mrt %#x\n",
                    logged_draws, (unsigned long long)regs.color_buffers[0].Address(),
                    (__bridge void*)colors[0].texture,
                    (unsigned long long)(pipeline->Stage(SwStage::Vertex) ? pipeline->Stage(SwStage::Vertex)->pgm_hash : 0),
                    (unsigned long long)(pipeline->Stage(SwStage::Fragment) ? pipeline->Stage(SwStage::Fragment)->pgm_hash : 0),
                    u32(regs.primitive_type), regs.num_indices, regs.num_instances.NumInstances(),
                    int(is_indexed), colors[0].texture ? u32(colors[0].texture.width) : 0,
                    colors[0].texture ? u32(colors[0].texture.height) : 0,
                    colors[0].texture ? u32(colors[0].texture.pixelFormat) : 0,
                    depth.texture != nil, key.num_samples, vp.xoffset, vp.xscale, vp.yoffset,
                    vp.yscale, vp.zscale, vp.zoffset, int(regs.IsClipDisabled()),
                    u32(regs.polygon_control.CullingMode()), u32(regs.polygon_control.front_face),
                    key.mrt_mask);
        for (u32 c = 0; c < key.num_color_attachments; ++c) {
            const auto& sw = key.color_buffers[c].swizzle;
            std::printf("  cb%u dfmt %u nfmt %u swizzle %u%u%u%u export %u\n", c,
                        u32(key.color_buffers[c].data_format), u32(key.color_buffers[c].num_format),
                        u32(sw.r), u32(sw.g), u32(sw.b), u32(sw.a),
                        u32(key.color_buffers[c].export_format));
        }
        std::printf("  key: wm %#x %#x blend %d num_att %u cdf %u nf %u | pso %p\n",
                    key.write_masks[0], key.write_masks[1], int(key.blend_controls[0].enable),
                    key.num_color_attachments, u32(key.color_buffers[0].data_format),
                    u32(key.color_buffers[0].num_format), pipeline->pso);
    }
    // Quad lists: two triangles per quad (0 1 2, 0 2 3), through an index buffer.
    u32 num_indices = regs.num_indices;
    bool draw_indexed = is_indexed;
    if (regs.primitive_type == AmdGpu::PrimitiveType::QuadList && !indirect) {
        const u32 quads = num_indices / 4;
        auto& stream = buffer_cache.GetStreamBuffer();
        const auto [data, offset] = stream.Map(std::max<u32>(quads * 6 * 4, 4), 4);
        u32* out = reinterpret_cast<u32*>(data);
        const u8* src = is_indexed ? static_cast<const u8*>(index_buffer.contents) + index_buffer_offset
                                   : nullptr;
        const bool is16 = index_type == MTLIndexTypeUInt16;
        const auto index = [&](u32 i) -> u32 {
            if (!src) {
                return i;
            }
            return is16 ? reinterpret_cast<const u16*>(src)[i] : reinterpret_cast<const u32*>(src)[i];
        };
        static constexpr u32 order[6] = {0, 1, 2, 0, 2, 3};
        for (u32 q = 0; q < quads; ++q) {
            for (u32 k = 0; k < 6; ++k) {
                out[q * 6 + k] = index(q * 4 + order[k]);
            }
        }
        stream.Commit();
        index_buffer = (__bridge id<MTLBuffer>)Metal::Raw(stream.Handle());
        index_buffer_offset = offset;
        index_type = MTLIndexTypeUInt32;
        num_indices = quads * 6;
        draw_indexed = true;
    }
    // The draw.
    const u32 num_instances = std::max<u32>(regs.num_instances.NumInstances(), 1);
    u32 vertex_offset = regs.index_offset;
    u32 instance_offset = 0;
    if (pipeline->fetch_shader && vs_info) {
        const auto& fs = *pipeline->fetch_shader;
        if (vertex_offset == 0 && fs.vertex_offset_sgpr != -1) {
            vertex_offset = vs_info->UserData()[fs.vertex_offset_sgpr];
        }
        if (fs.instance_offset_sgpr != -1) {
            instance_offset = vs_info->UserData()[fs.instance_offset_sgpr];
        }
    }
    void* const index_raw = (__bridge void*)index_buffer;
    const u64 ib_offset = index_buffer_offset;
    const MTLIndexType itype = index_type;
    const MTLPrimitiveType prim = primitive;
    if (indirect && !skip_calls) {
        void* const args_raw = (__bridge void*)args_buffer;
        const u64 step = quad_indirect ? 20 : indirect->stride;
        const u32 count = indirect->max_count;
        const bool indexed_args = is_indexed || quad_indirect;
        const u64 first = args_offset;
        MetalScheduler::RecordRender(scheduler, [=](id<MTLRenderCommandEncoder> enc) {
            id<MTLBuffer> args = (__bridge id<MTLBuffer>)args_raw;
            for (u32 i = 0; i < count; ++i) {
                const u64 at = first + u64(i) * step;
                if (indexed_args) {
                    [enc drawIndexedPrimitives:prim
                                     indexType:itype
                                   indexBuffer:(__bridge id<MTLBuffer>)index_raw
                             indexBufferOffset:ib_offset
                                indirectBuffer:args
                          indirectBufferOffset:at];
                } else {
                    [enc drawPrimitives:prim indirectBuffer:args indirectBufferOffset:at];
                }
            }
        });
    } else if (num_indices && !skip_calls) {
        if (draw_indexed) {
            MetalScheduler::RecordRender(scheduler, [=](id<MTLRenderCommandEncoder> enc) {
                [enc drawIndexedPrimitives:prim
                                indexCount:num_indices
                                 indexType:itype
                               indexBuffer:(__bridge id<MTLBuffer>)index_raw
                         indexBufferOffset:ib_offset
                             instanceCount:num_instances
                                baseVertex:s32(vertex_offset)
                              baseInstance:instance_offset];
            });
        } else {
            MetalScheduler::RecordRender(scheduler, [=](id<MTLRenderCommandEncoder> enc) {
                [enc drawPrimitives:prim
                        vertexStart:vertex_offset
                        vertexCount:num_indices
                      instanceCount:num_instances
                       baseInstance:instance_offset];
            });
        }
    }
    if (writes_memory) {
        MetalScheduler::NoteUntrackedWrite(scheduler);
        // tlg: guest memory is untracked: a later draw of this pass that reads what this one
        // wrote (vertex or fragment stage) is otherwise not ordered after it.
        // TLG_METAL_DRAW_BARRIER=0 leaves it out.
        static const bool draw_barrier = [] {
            const char* env = std::getenv("TLG_METAL_DRAW_BARRIER");
            return !(env && env[0] == '0');
        }();
        if (draw_barrier) {
            MetalScheduler::RecordRender(scheduler, [](id<MTLRenderCommandEncoder> enc) {
                [enc memoryBarrierWithScope:MTLBarrierScopeBuffers
                                afterStages:MTLRenderStageVertex | MTLRenderStageFragment
                               beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
            });
            ++draw_state->draw_barriers;
        }
    }
    if (NanScan::Active() && NanScan::PerDraw()) {
        // Every draw its own pass, so the scan names the draw that wrote the first NaN.
        scheduler.EndEncoding();
        d.pass_open = false;
    }
    ResetBindings();
}

void Rasterizer::DispatchDirect() {
    DispatchImpl(0);
}

void Rasterizer::DispatchImpl(VAddr indirect_args) {
    ++draw_state->dispatches;
    scheduler.PopPendingOperations();
    const auto& cs = liverpool->GetCsRegs();
    if (!indirect_args && (cs.dim_x == 0 || cs.dim_y == 0 || cs.dim_z == 0)) {
        return;
    }
    const ComputePipeline* pipeline = pipeline_cache.GetComputePipeline();
    if (!pipeline) {
        ++draw_state->skipped_dispatches;
        return;
    }
    Shader::PushData push_data{};
    Shader::Backend::Bindings binding{};
    StageBindings b;
    BindStage(pipeline->stage, binding, push_data, b);
    char label[96] = "";
    if (MetalScheduler::LabelMode()) {
        std::snprintf(label, sizeof(label), "cs %016llx %ux%ux%u%s",
                      (unsigned long long)pipeline->hash, cs.dim_x, cs.dim_y, cs.dim_z,
                      indirect_args ? " indirect" : "");
    }
    draw_state->impl->pass_open = false;
    const auto& wg = pipeline->workgroup_size;
    const MTLSize threads = MTLSizeMake(std::max(wg[0], 1u), std::max(wg[1], 1u), std::max(wg[2], 1u));
    void* indirect_raw = nullptr;
    u64 indirect_offset = 0;
    if (indirect_args) {
        const auto [buffer, offset] = buffer_cache.ObtainBuffer(indirect_args, 12, false);
        indirect_raw = Metal::Raw(buffer->Handle());
        indirect_offset = offset;
    }
    // Diagnosis: TLG_METAL_LOG_CS=<hex>[,...]: those compute shaders' dispatches (the first 40,
    // then one a second): grid, workgroup size and the first dwords of each buffer as recorded.
    if (static const char* log_cs = std::getenv("TLG_METAL_LOG_CS"); log_cs) {
        char want[24];
        std::snprintf(want, sizeof(want), "%llx", (unsigned long long)pipeline->hash);
        static u32 logged = 0;
        static auto last = std::chrono::steady_clock::now();
        const auto now = std::chrono::steady_clock::now();
        if (std::strstr(log_cs, want) && (logged < 40 || now - last > std::chrono::seconds(1))) {
            ++logged;
            last = now;
            std::string line;
            for (u32 i = 0; i < b.num_buffers && i < 6; ++i) {
                const u8* base = static_cast<const u8*>(b.buffers[i].contents);
                char t[96];
                if (base && b.sizes[i] >= 8) {
                    const u32* w = reinterpret_cast<const u32*>(base + b.offsets[i]);
                    std::snprintf(t, sizeof(t), " b%u[%u]=%u,%u", i, b.sizes[i], w[0], w[1]);
                } else {
                    std::snprintf(t, sizeof(t), " b%u[%u]", i, b.sizes[i]);
                }
                line += t;
            }
            std::printf("cs %s: grid %ux%ux%u%s wg %ux%ux%u%s\n", want, cs.dim_x, cs.dim_y, cs.dim_z,
                        indirect_args ? " (indirect)" : "", pipeline->workgroup_size[0],
                        pipeline->workgroup_size[1], pipeline->workgroup_size[2], line.c_str());
        }
    }
    // Diagnosis: TLG_METAL_CHECK_SORT=1: after each dispatch of inFAMOUS's merge sort (a16fa93a),
    // once the GPU has run it, whether its output (key, value pairs) is sorted.
    if (static const bool check_sort = std::getenv("TLG_METAL_CHECK_SORT") != nullptr;
        check_sort && pipeline->hash == 0xa16fa93aull && b.num_buffers >= 6) {
        const auto ptr = [&](u32 i) { return static_cast<const u8*>(b.buffers[i].contents) + b.offsets[i]; };
        const u8* count_p = ptr(0);
        const u8* widths = ptr(2);
        const u8* a = ptr(3);
        const u8* bb = ptr(4);
        const u32* flat = reinterpret_cast<const u32*>(ptr(5));
        const u32 stride_a = (flat[1] >> 16) & 0x3FFF, stride_b = (flat[5] >> 16) & 0x3FFF;
        const u32 grid = cs.dim_x;
        scheduler.SignalOnCompletion([=] {
            const u32 count = *reinterpret_cast<const u32*>(count_p);
            const u32 w = reinterpret_cast<const u32*>(widths)[0], maxw = reinterpret_cast<const u32*>(widths)[1];
            // The last phase: A -> B for w, then B -> A for 2w, ... up to maxw.
            u32 phases = 0;
            for (u64 x = w; x <= maxw && phases < 64; x *= 2) {
                ++phases;
            }
            const bool in_b = phases % 2 == 1;
            const u8* out = in_b ? bb : a;
            const u32 stride = in_b ? stride_b : stride_a;
            const u64 block = std::min<u64>(u64(maxw), count); // sorted runs of maxw elements
            u32 bad = 0, asc = 0, desc = 0;
            for (u32 i = 1; i < count && stride >= 4; ++i) {
                if (block && i % block == 0) {
                    continue;
                }
                const float k0 = *reinterpret_cast<const float*>(out + u64(i - 1) * stride);
                const float k1 = *reinterpret_cast<const float*>(out + u64(i) * stride);
                asc += k1 >= k0;
                desc += k1 <= k0;
            }
            bad = std::min(count > 1 ? count - 1 - asc : 0u, count > 1 ? count - 1 - desc : 0u);
            static std::atomic<u32> logged{0};
            if (logged.fetch_add(1) < 200) {
                std::printf("sort check: grid %u count %u w %u..%u phases %u out %c stride %u: %u ascending, %u descending pairs, %u out of order\n",
                            grid, count, w, maxw, phases, in_b ? 'B' : 'A', stride, asc, desc, bad);
            }
        });
    }
    if (FrameLog::Enabled()) {
        FrameLog::NoteDispatch(pipeline->hash, u64(cs.dim_x) * cs.dim_y * cs.dim_z, indirect_args != 0);
    }
    // The bindings travel as one block: buffers, offsets, textures, samplers, sizes, push data.
    const u32 nb = b.num_buffers, nt = b.num_textures, ns = b.num_samplers;
    alignas(16) u8 block[sizeof(void*) * 32 + 8 * 32 + sizeof(void*) * 128 + sizeof(void*) * 16 +
                         4 * 32 + sizeof(Shader::PushData)];
    size_t at = 0;
    const auto put = [&](const void* src, size_t n) {
        std::memcpy(block + at, src, n);
        at += n;
    };
    put(b.buffers.data(), sizeof(void*) * nb);
    put(b.offsets.data(), 8 * nb);
    put(b.textures.data(), sizeof(void*) * nt);
    put(b.samplers.data(), sizeof(void*) * ns);
    put(b.sizes.data(), 4 * 32);
    put(&push_data, sizeof(push_data));
    const MTLSize groups = MTLSizeMake(cs.dim_x, cs.dim_y, cs.dim_z);
    void* const pso = pipeline->pso;
    MetalScheduler::detail::UseCompute(scheduler, label[0] ? label : "dispatch");
    Scheduler::Impl* const si = scheduler.impl_();
    const bool barrier = std::exchange(dispatch_barrier, true);
    si->RecordWith(block, at, [si, barrier, nb, nt, ns, threads, groups, pso, indirect_raw, indirect_offset,
                               name = MetalScheduler::LabelMode() ? std::string(label) : std::string()](const void* copy) {
        id<MTLComputeCommandEncoder> enc = MetalScheduler::detail::ComputeFor(*si, name);
        MetalScheduler::BeforeGuestDispatch(*si, enc, barrier);
        const u8* p = static_cast<const u8*>(copy);
        const auto* buffers = reinterpret_cast<__unsafe_unretained id<MTLBuffer> const*>(p);
        p += sizeof(void*) * nb;
        const auto* offsets = reinterpret_cast<const u64*>(p);
        p += 8 * nb;
        const auto* textures = reinterpret_cast<__unsafe_unretained id<MTLTexture> const*>(p);
        p += sizeof(void*) * nt;
        const auto* samplers = reinterpret_cast<__unsafe_unretained id<MTLSamplerState> const*>(p);
        p += sizeof(void*) * ns;
        [enc setComputePipelineState:(__bridge id<MTLComputePipelineState>)pso];
        if (nb) {
            [enc setBuffers:buffers offsets:reinterpret_cast<const NSUInteger*>(offsets) withRange:NSMakeRange(0, nb)];
        }
        if (nt) {
            [enc setTextures:textures withRange:NSMakeRange(0, nt)];
        }
        if (ns) {
            [enc setSamplerStates:samplers withRange:NSMakeRange(0, ns)];
        }
        [enc setBytes:p length:sizeof(u32) * 32 atIndex:BufferSizesBufferIndex];
        p += 4 * 32;
        [enc setBytes:p length:sizeof(Shader::PushData) atIndex:PushDataBufferIndex];
        if (indirect_raw) {
            [enc dispatchThreadgroupsWithIndirectBuffer:(__bridge id<MTLBuffer>)indirect_raw
                                   indirectBufferOffset:indirect_offset
                                  threadsPerThreadgroup:threads];
        } else {
            [enc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
        }
    });
    if (b.writes_memory) {
        MetalScheduler::NoteUntrackedWrite(scheduler);
        NoteGuestWrite();
    }
    last_cs_hash[lane_] = pipeline->hash;
    if (NanScan::Active()) {
        NanScan::AfterDispatch(scheduler, pipeline->hash, b.textures.data(), b.num_textures);
    }
    ResetBindings();
}

void Rasterizer::DispatchIndirect(VAddr address, u32 offset, u32 size) {
    ++draw_state->indirect_dispatches;
    DispatchImpl(address + offset);
}

} // namespace Vulkan
