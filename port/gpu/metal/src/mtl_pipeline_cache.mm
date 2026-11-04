// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: pipeline cache. Shader selection (runtime info, keys, permutations) follows
// the Vulkan renderer's vk_pipeline_cache.cpp; modules are MSL functions instead of SPIR-V
// modules.

#include <algorithm>
#include <bit>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <atomic>
#include <memory>
#include <vector>
#include <thread>
#include <condition_variable>
#include <utility>

#include <sys/sysctl.h>
#include <unistd.h>

#include <spirv_cross/spirv_msl.hpp>
#include <xxhash.h>

#include "common/assert.h"
#include "common/hash.h"
#include "mtl_format.h"
#include "mtl_objc.h"
#include "tlg_settings.h"
#include "shader_recompiler/backend/spirv/emit_spirv.h"
#include "shader_recompiler/recompiler.h"
#include "shader_recompiler/specialization.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/amdgpu/resource.h"
#include "video_core/amdgpu/tlg_block1d.h"
#include "video_core/renderer_vulkan/liverpool_to_vk.h"
#include "video_core/renderer_vulkan/vk_depth_stencil_state.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_pipeline_cache.h"

namespace Vulkan {

using Shader::HwStage;
using Shader::SwStage;
using Shader::Output;

namespace {

std::atomic<u64> g_compile_ns{0};
std::atomic<u32> g_compiles{0};
std::atomic<u32> g_pipelines{0};
std::atomic<u32> g_failed{0};
std::atomic<u32> g_async_skips{0}, g_async_queued{0}; // tlg: async shaders
std::atomic<u64> g_stage_skips[16]{}; // tlg: draws dropped for their shader stages (GS/tess)
std::atomic<u64> g_stage_ns[4]{}; // tlg: recompile+SPIR-V, SPIRV-Cross, MSL compile, render PSO
inline u64 NsSince(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t).count();
}

u32 MapOutputs(std::span<Shader::OutputMap, 3> outputs, const AmdGpu::VsOutputControl& ctl) {
    u32 num_outputs = 0;
    if (ctl.vs_out_misc_enable) {
        auto& misc_vec = outputs[num_outputs++];
        misc_vec[0] = ctl.use_vtx_point_size ? Output::PointSize : Output::None;
        misc_vec[1] = ctl.use_vtx_edge_flag
                          ? Output::EdgeFlag
                          : (ctl.use_vtx_gs_cut_flag ? Output::GsCutFlag : Output::None);
        misc_vec[2] = ctl.use_vtx_kill_flag
                          ? Output::KillFlag
                          : (ctl.use_vtx_render_target_idx ? Output::RenderTargetIndex
                                                           : Output::None);
        misc_vec[3] = ctl.use_vtx_viewport_idx ? Output::ViewportIndex : Output::None;
    }
    const auto clip_cull = [&](u32 i, Output clip, Output cull) {
        return ctl.IsClipDistEnabled(i) ? clip : (ctl.IsCullDistEnabled(i) ? cull : Output::None);
    };
    if (ctl.vs_out_ccdist0_enable) {
        auto& v = outputs[num_outputs++];
        v[0] = clip_cull(0, Output::ClipDist0, Output::CullDist0);
        v[1] = clip_cull(1, Output::ClipDist1, Output::CullDist1);
        v[2] = clip_cull(2, Output::ClipDist2, Output::CullDist2);
        v[3] = clip_cull(3, Output::ClipDist3, Output::CullDist3);
    }
    if (ctl.vs_out_ccdist1_enable) {
        auto& v = outputs[num_outputs++];
        v[0] = clip_cull(4, Output::ClipDist4, Output::CullDist4);
        v[1] = clip_cull(5, Output::ClipDist5, Output::CullDist5);
        v[2] = clip_cull(6, Output::ClipDist6, Output::CullDist6);
        v[3] = clip_cull(7, Output::ClipDist7, Output::CullDist7);
    }
    return num_outputs;
}

/// Whether the attachment of this depth/stencil state is needed (GetEffectiveDepthStencilState
/// of the Vulkan renderer, simplified: a depth or stencil buffer that is tested or written).
bool DepthAttachmentNeeded(const AmdGpu::Regs& regs) {
    const bool depth = regs.depth_buffer.DepthValid() &&
                       (regs.depth_control.depth_enable || regs.depth_render_control.depth_clear_enable);
    const bool stencil = regs.depth_buffer.StencilValid() &&
                         (regs.depth_control.stencil_enable ||
                          regs.depth_render_control.stencil_clear_enable);
    return depth || stencil;
}

struct Module {
    Shader::StageSpecialization spec;
    id<MTLFunction> function = nil;
    MetalStage meta{};
    bool cold = false; ///< first compiled in this run (not in the MSL cache): async pipeline
};

struct Program {
    Program(HwStage hw, SwStage sw, const Shader::ShaderParams& params) : info{hw, sw, params} {}
    Shader::Info info;
    std::deque<Module> modules; ///< stable addresses: pipelines refer to them
    size_t last_used = 0;
    bool failed = false;
    /// Async shaders: permutations whose MSL compiles in the background (lookup
    /// specialization, MSL source); their draws are skipped meanwhile.
    std::vector<std::pair<Shader::StageSpecialization, std::string>> pending;
    /// The inputs of the last permutation lookup: when a draw repeats them (user data, the
    /// flattened user data, runtime info, binding start and vertex attribute sharps), the
    /// permutation is the same and its specialization is not rebuilt (~15% of the command
    /// processor thread).
    struct LastLookup {
        bool valid = false;
        std::vector<u32> user_data;
        std::vector<u32> flat;
        Shader::RuntimeInfo runtime_info{};
        Shader::Backend::Bindings start{};
        std::vector<AmdGpu::Buffer> attribs;
        size_t module = 0;
    } last;
};

namespace {
bool SameSpan(const std::vector<u32>& a, std::span<const u32> b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), b.size_bytes()) == 0;
}
} // namespace

/// MSL from SPIR-V: resources numbered per kind in binding order.
struct MslResult {
    std::string msl;
    std::string entry;
    std::string error;
    u32 num_buffers = 0, num_textures = 0, num_samplers = 0;
    bool uses_buffer_sizes = false;
    bool cache_hit = false; ///< from the MSL disk cache: compiled in an earlier run
};

MslResult TranslateStage(const std::vector<u32>& spirv, bool flip_y) {
    MslResult out;
    try {
        spirv_cross::CompilerMSL compiler(spirv.data(), spirv.size());
        spirv_cross::CompilerMSL::Options msl;
        msl.platform = spirv_cross::CompilerMSL::Options::macOS;
        msl.set_msl_version(3, 1);
        msl.argument_buffers = false;
        msl.texture_buffer_native = true;
        msl.pad_fragment_output_components = true;
        msl.buffer_size_buffer_index = BufferSizesBufferIndex;
        msl.enable_decoration_binding = false;
        msl.force_native_arrays = false;
        compiler.set_msl_options(msl);
        auto common = compiler.get_common_options();
        common.vertex.flip_vert_y = flip_y;
        common.vertex.fixup_clipspace = false;
        compiler.set_common_options(common);

        const auto model = compiler.get_execution_model();
        const auto resources = compiler.get_shader_resources();
        struct Res {
            u32 binding;
            u32 count;
            spirv_cross::SPIRType::BaseType type;
        };
        std::vector<Res> buffers, textures, samplers;
        const auto count_of = [&](spirv_cross::ID id) {
            const auto& type = compiler.get_type(compiler.get_type_from_variable(id).self);
            u32 n = 1;
            for (u32 d : compiler.get_type_from_variable(id).array) {
                n *= std::max(d, 1u);
            }
            (void)type;
            return n;
        };
        for (const auto& r : resources.storage_buffers) {
            buffers.push_back({compiler.get_decoration(r.id, spv::DecorationBinding), 1,
                               spirv_cross::SPIRType::Struct});
        }
        for (const auto& r : resources.uniform_buffers) {
            buffers.push_back({compiler.get_decoration(r.id, spv::DecorationBinding), 1,
                               spirv_cross::SPIRType::Struct});
        }
        for (const auto& r : resources.separate_images) {
            textures.push_back({compiler.get_decoration(r.id, spv::DecorationBinding), count_of(r.id),
                                spirv_cross::SPIRType::Image});
        }
        for (const auto& r : resources.storage_images) {
            textures.push_back({compiler.get_decoration(r.id, spv::DecorationBinding), count_of(r.id),
                                spirv_cross::SPIRType::Image});
        }
        for (const auto& r : resources.separate_samplers) {
            samplers.push_back({compiler.get_decoration(r.id, spv::DecorationBinding), 1,
                                spirv_cross::SPIRType::Sampler});
        }
        // Several SPIR-V variables may alias one binding (typed views of a buffer).
        const auto assign = [&](std::vector<Res>& list, u32& total, auto&& set_slot) {
            std::sort(list.begin(), list.end(), [](const Res& a, const Res& b) { return a.binding < b.binding; });
            u32 slot = 0;
            u32 last_binding = ~0u;
            u32 last_slot = 0;
            for (const auto& r : list) {
                u32 this_slot;
                if (r.binding == last_binding) {
                    this_slot = last_slot;
                } else {
                    this_slot = slot;
                    slot += r.count;
                }
                last_binding = r.binding;
                last_slot = this_slot;
                spirv_cross::MSLResourceBinding b{};
                b.stage = model;
                b.desc_set = 0;
                b.binding = r.binding;
                b.count = r.count;
                b.basetype = r.type;
                set_slot(b, this_slot);
                compiler.add_msl_resource_binding(b);
            }
            total = slot;
        };
        assign(buffers, out.num_buffers, [](auto& b, u32 s) { b.msl_buffer = s; });
        assign(textures, out.num_textures, [](auto& b, u32 s) { b.msl_texture = s; });
        assign(samplers, out.num_samplers, [](auto& b, u32 s) { b.msl_sampler = s; });

        spirv_cross::MSLResourceBinding push{};
        push.stage = model;
        push.desc_set = spirv_cross::kPushConstDescSet;
        push.binding = spirv_cross::kPushConstBinding;
        push.msl_buffer = PushDataBufferIndex;
        compiler.add_msl_resource_binding(push);

        out.msl = compiler.compile();
        out.uses_buffer_sizes = compiler.needs_buffer_size_buffer();
        const auto entries = compiler.get_entry_points_and_stages();
        out.entry = entries.empty() ? "main0"
                                    : compiler.get_cleansed_entry_point_name(
                                          entries[0].name, entries[0].execution_model);
    } catch (const std::exception& e) {
        out.error = e.what();
    }
    return out;
}

// MSL compile options and source prefix (shared by CompileMsl and the prewarm threads).
// GCN float math is unfused: the shaders compile with contraction off (no fused multiply-add)
// in Metal's safe math mode, which honors inf and NaN. The recompiler's per-operation
// NoContraction (TLG_METAL_FP=decorated) made SPIRV-Cross call an unoptimized
// ([[clang::optnone]]) function for every add and multiply: ~5x slower.
// TLG_METAL_MATH=relaxed|fast for tests.
MTLCompileOptions* MslOptions() {
    static MTLCompileOptions* const options = [] {
        MTLCompileOptions* o = [MTLCompileOptions new];
        o.languageVersion = MTLLanguageVersion3_2;
        const char* env = std::getenv("TLG_METAL_MATH");
        o.mathMode = env && env[0] == 'r'   ? MTLMathModeRelaxed
                     : env && env[0] == 'f' ? MTLMathModeFast
                                            : MTLMathModeSafe;
        o.preserveInvariance = YES;
        return o;
    }();
    return options;
}

std::string MslSource(const std::string& msl) {
    static const bool contract_off = [] {
        const char* env = std::getenv("TLG_METAL_CONTRACT");
        return !(env && env[0] == '1');
    }();
    // Testing: TLG_METAL_COLD_SHADERS=1 makes every source unique to this run, so Metal's own
    // shader cache (keyed by source) misses and each shader compiles as on first sight.
    static const std::string cold = [] {
        const char* env = std::getenv("TLG_METAL_COLD_SHADERS");
        if (!(env && env[0] == '1')) {
            return std::string();
        }
        char tag[64];
        std::snprintf(tag, sizeof(tag), "// cold %d %lld\n", int(getpid()),
                      (long long)std::chrono::steady_clock::now().time_since_epoch().count());
        return std::string(tag);
    }();
    return cold + (contract_off ? std::string("#pragma METAL fp contract(off)\n") : std::string()) + msl;
}

// tlg: Metal compiles each MSL source on the command processor thread, one at a time, when a
// draw first needs it: ~60 ms per shader with a cold system cache (after a macOS update, or
// for an unbundled binary on macOS 27), ~33 s while the cannery loads. The MSL cache below
// knows the shaders of earlier runs, so worker threads compile them all at startup in
// parallel; CompileMsl takes a finished library, waits for one in progress, or compiles itself
// one not reached yet. TLG_METAL_PREWARM=<threads> (0 = off; default: performance cores - 2).
class MslPrewarm {
public:
    static MslPrewarm& Get() {
        static MslPrewarm prewarm;
        return prewarm;
    }

    void Start(std::vector<std::string> sources) {
        u32 threads = 0;
        if (const char* env = std::getenv("TLG_METAL_PREWARM")) {
            threads = u32(std::strtoul(env, nullptr, 0));
        } else {
            u32 cores = 0;
            size_t size = sizeof(cores);
            if (sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nullptr, 0) != 0) {
                cores = 4;
            }
            threads = std::max<u32>(cores, 3) - 2;
        }
        if (!threads) {
            return;
        }
        {
            std::lock_guard lock{mutex};
            for (std::string& source : sources) {
                const u64 key = XXH3_64bits(source.data(), source.size());
                if (slots.emplace(key, Slot{}).second) {
                    queue.emplace_back(key, std::move(source));
                }
            }
        }
        std::printf("GPU (Metal): precompiling %zu cached shaders on %u threads\n", queue.size(),
                    threads);
        start_time = std::chrono::steady_clock::now();
        startup_left = queue.size();
        running = threads;
        for (u32 i = 0; i < threads; ++i) {
            std::thread([this] { Work(); }).detach();
        }
    }

    bool Running() const {
        return running.load(std::memory_order_relaxed) != 0;
    }

    // Async shaders: the finished library for this source without taking it, or nil with
    // `pending` set while it compiles (queued on first ask). nil without `pending`: compile it
    // here (claimed, or already taken).
    id<MTLLibrary> Poll(const std::string& source, bool& pending) {
        const u64 key = XXH3_64bits(source.data(), source.size());
        pending = false;
        {
            std::lock_guard lock{mutex};
            const auto [it, inserted] = slots.emplace(key, Slot{});
            if (inserted) {
                urgent.emplace_back(key, source);
                pending = true;
            } else if (it->second.state == State::Queued) {
                // Still in the startup precompile queue (thousands deep): a draw needs it now.
                if (!it->second.urgent) {
                    it->second.urgent = true;
                    urgent.emplace_back(key, source);
                }
                pending = true;
            } else if (it->second.state == State::Compiling) {
                pending = true;
            } else if (it->second.state == State::Done) {
                return it->second.library;
            }
        }
        if (pending) {
            work_cv.notify_one();
        }
        return nil;
    }

    // A finished library for this source, after waiting for one in progress; nil when the
    // caller should compile it (unknown source, or not started: it is then skipped).
    id<MTLLibrary> Take(const std::string& source) {
        const u64 key = XXH3_64bits(source.data(), source.size());
        std::unique_lock lock{mutex};
        const auto it = slots.find(key);
        if (it == slots.end()) {
            return nil;
        }
        Slot& slot = it->second;
        if (slot.state == State::Queued) {
            slot.state = State::Claimed;
            return nil;
        }
        done_cv.wait(lock, [&] { return slot.state == State::Done || slot.state == State::Claimed; });
        id<MTLLibrary> library = slot.library;
        slot.library = nil;
        if (library) {
            ++taken;
        }
        return library;
    }

private:
    enum class State { Queued, Compiling, Done, Claimed };
    struct Slot {
        State state = State::Queued;
        bool urgent = false;
        id<MTLLibrary> library = nil;
    };

    void Work() {
        for (;;) {
            u64 key;
            std::string source;
            {
                std::unique_lock lock{mutex};
                // tlg: shaders a draw waits for (async) go before the startup precompile queue.
                bool got = false;
                for (;;) {
                    while (!urgent.empty()) {
                        auto item = std::move(urgent.front());
                        urgent.pop_front();
                        if (slots[item.first].state == State::Queued) {
                            key = item.first;
                            source = std::move(item.second);
                            got = true;
                            break;
                        }
                    }
                    if (got) {
                        break;
                    }
                    while (next < queue.size() && slots[queue[next].first].state != State::Queued) {
                        ++next;
                    }
                    if (next < queue.size()) {
                        key = queue[next].first;
                        source = std::move(queue[next].second);
                        ++next;
                        break;
                    }
                    // Workers stay for async shaders (Poll queues more).
                    work_cv.wait(lock);
                }
                slots[key].state = State::Compiling;
            }
            id<MTLLibrary> library;
            @autoreleasepool {
                NSError* error = nil;
                library = [Metal::Device() newLibraryWithSource:[NSString stringWithUTF8String:source.c_str()]
                                                        options:MslOptions()
                                                          error:&error];
            }
            {
                std::lock_guard lock{mutex};
                Slot& slot = slots[key];
                slot.library = library;
                slot.state = State::Done;
                ++compiled;
                if (startup_left && --startup_left == 0) {
                    std::printf("GPU (Metal): precompiled %u shaders in %.1f s (%u used so far)\n",
                                compiled,
                                std::chrono::duration<double>(std::chrono::steady_clock::now() -
                                                              start_time)
                                    .count(),
                                taken);
                }
            }
            done_cv.notify_all();
        }
    }

    std::mutex mutex;
    std::condition_variable done_cv;
    std::condition_variable work_cv;
    size_t startup_left = 0;
    std::unordered_map<u64, Slot> slots;
    std::vector<std::pair<u64, std::string>> queue;
    std::deque<std::pair<u64, std::string>> urgent;
    size_t next = 0;
    u32 compiled = 0, taken = 0;
    std::atomic<u32> running{0};
    std::chrono::steady_clock::time_point start_time;
};

// tlg: SPIRV-Cross is ~75% of a shader compile (~2.5 ms each, ~650 shaders while a level loads),
// and its output depends only on the SPIR-V and the fixed options above. The MSL is kept in an
// append-only file in the user folder, keyed by a hash of the SPIR-V; Metal's own cache then
// makes the MSL compile cheap. Bump kMslCacheVersion when TranslateStage's options or the
// SPIRV-Cross version change. TLG_METAL_NO_MSL_CACHE=1 disables it.
extern "C" const char* runtime_file_user_dir(void);

class MslDiskCache {
public:
    static constexpr u64 kMslCacheVersion = 1;

    static MslDiskCache& Get() {
        static MslDiskCache cache;
        return cache;
    }

    MslResult Translate(const std::vector<u32>& spirv, bool flip_y) {
        if (!enabled) {
            return TranslateStage(spirv, flip_y);
        }
        const u64 key = XXH3_64bits_withSeed(spirv.data(), spirv.size() * sizeof(u32),
                                             kMslCacheVersion * 2 + (flip_y ? 1 : 0));
        {
            std::lock_guard lock{mutex};
            if (auto it = entries.find(key); it != entries.end()) {
                ++hits;
                MslResult r = it->second;
                r.cache_hit = true;
                return r;
            }
        }
        MslResult r = TranslateStage(spirv, flip_y);
        if (!r.error.empty()) {
            return r;
        }
        std::lock_guard lock{mutex};
        if (file) {
            const u32 head[6] = {u32(r.msl.size()), u32(r.entry.size()), r.num_buffers,
                                 r.num_textures, r.num_samplers, r.uses_buffer_sizes ? 1u : 0u};
            std::fwrite(&key, sizeof(key), 1, file);
            std::fwrite(head, sizeof(head), 1, file);
            std::fwrite(r.msl.data(), 1, r.msl.size(), file);
            std::fwrite(r.entry.data(), 1, r.entry.size(), file);
            std::fflush(file);
        }
        entries.emplace(key, r);
        return r;
    }

    u32 TakeHits() {
        std::lock_guard lock{mutex};
        return std::exchange(hits, 0);
    }

private:
    MslDiskCache() {
        const char* off = std::getenv("TLG_METAL_NO_MSL_CACHE");
        enabled = !(off && off[0] == '1');
        if (!enabled) {
            MslPrewarm::Get().Start({}); // the workers also serve async shaders
            return;
        }
        const std::string path = std::string(runtime_file_user_dir()) + "/metal-msl-cache.bin";
        constexpr u64 kMagic = 0x31434c534d474c54ull; // "TLGMSLC1"
        // Load whatever complete records the file has; a torn last record is dropped.
        size_t valid = 0;
        if (FILE* in = std::fopen(path.c_str(), "rb")) {
            u64 magic = 0, version = 0;
            if (std::fread(&magic, 8, 1, in) == 1 && std::fread(&version, 8, 1, in) == 1 &&
                magic == kMagic && version == kMslCacheVersion) {
                valid = 16;
                for (;;) {
                    u64 key;
                    u32 head[6];
                    if (std::fread(&key, 8, 1, in) != 1 || std::fread(head, sizeof(head), 1, in) != 1 ||
                        head[0] > (64u << 20) || head[1] > 4096) {
                        break;
                    }
                    MslResult r;
                    r.msl.resize(head[0]);
                    r.entry.resize(head[1]);
                    if (std::fread(r.msl.data(), 1, head[0], in) != head[0] ||
                        std::fread(r.entry.data(), 1, head[1], in) != head[1]) {
                        break;
                    }
                    r.num_buffers = head[2];
                    r.num_textures = head[3];
                    r.num_samplers = head[4];
                    r.uses_buffer_sizes = head[5] != 0;
                    if (entries.emplace(key, std::move(r)).second) {
                        order.push_back(key);
                    }
                    valid += 8 + sizeof(head) + head[0] + head[1];
                }
            }
            std::fclose(in);
        }
        // Bounded: past kMaxRecords, keep the newest kKeepRecords (records are appended in the
        // order the shaders were first translated; an older one still in use is translated
        // again once and appended anew).
        constexpr size_t kMaxRecords = 4096, kKeepRecords = 3072;
        if (valid >= 16 && order.size() > kMaxRecords) {
            const std::string tmp = path + ".tmp";
            if (FILE* out = std::fopen(tmp.c_str(), "wb")) {
                const u64 head[2] = {kMagic, kMslCacheVersion};
                std::fwrite(head, sizeof(head), 1, out);
                std::vector<u64> kept(order.end() - kKeepRecords, order.end());
                for (const u64 key : kept) {
                    const MslResult& r = entries[key];
                    const u32 rec[6] = {u32(r.msl.size()), u32(r.entry.size()), r.num_buffers,
                                        r.num_textures, r.num_samplers, r.uses_buffer_sizes ? 1u : 0u};
                    std::fwrite(&key, sizeof(key), 1, out);
                    std::fwrite(rec, sizeof(rec), 1, out);
                    std::fwrite(r.msl.data(), 1, r.msl.size(), out);
                    std::fwrite(r.entry.data(), 1, r.entry.size(), out);
                }
                std::fclose(out);
                if (std::rename(tmp.c_str(), path.c_str()) == 0) {
                    std::printf("GPU (Metal): MSL cache compacted: %zu -> %zu shaders\n",
                                order.size(), kept.size());
                    std::unordered_map<u64, MslResult> keep_entries;
                    for (const u64 key : kept) {
                        keep_entries.emplace(key, std::move(entries[key]));
                    }
                    entries = std::move(keep_entries);
                    order = std::move(kept);
                    valid = 0; // reopen for appending below
                    file = std::fopen(path.c_str(), "ab");
                }
            }
        }
        if (file) {
        } else if (valid >= 16) {
            truncate(path.c_str(), off_t(valid));
            file = std::fopen(path.c_str(), "ab");
        } else {
            file = std::fopen(path.c_str(), "wb");
            if (file) {
                const u64 head[2] = {kMagic, kMslCacheVersion};
                std::fwrite(head, sizeof(head), 1, file);
                std::fflush(file);
            }
        }
        std::printf("GPU (Metal): MSL cache %s: %zu shaders\n", path.c_str(), entries.size());
        // Newest records first: the file keeps the shaders of older recompiler versions too.
        std::vector<std::string> sources;
        sources.reserve(order.size());
        for (auto it = order.rbegin(); it != order.rend(); ++it) {
            sources.push_back(MslSource(entries[*it].msl));
        }
        MslPrewarm::Get().Start(std::move(sources));
    }

    bool enabled = false;
    std::mutex mutex;
    std::unordered_map<u64, MslResult> entries;
    std::vector<u64> order; // file order
    FILE* file = nullptr;
    u32 hits = 0;
};

id<MTLFunction> CompileMsl(const MslResult& r, u64 hash, const char* stage) {
    NSError* error = nil;
    const std::string source = MslSource(r.msl);
    id<MTLLibrary> library = MslPrewarm::Get().Take(source);
    if (!library) {
        library = [Metal::Device() newLibraryWithSource:[NSString stringWithUTF8String:source.c_str()]
                                                options:MslOptions()
                                                  error:&error];
    }
    if (!library) {
        if (g_failed.fetch_add(1) < 32) {
            std::printf("GPU (Metal): %s shader %016llx: MSL compile failed: %s\n", stage,
                        (unsigned long long)hash, error.localizedDescription.UTF8String);
        }
        return nil;
    }
    return [library newFunctionWithName:[NSString stringWithUTF8String:r.entry.c_str()]];
}

MTLBlendFactor BlendFactor(AmdGpu::BlendControl::BlendFactor f) {
    using F = AmdGpu::BlendControl::BlendFactor;
    switch (f) {
    case F::Zero: return MTLBlendFactorZero;
    case F::One: return MTLBlendFactorOne;
    case F::SrcColor: return MTLBlendFactorSourceColor;
    case F::OneMinusSrcColor: return MTLBlendFactorOneMinusSourceColor;
    case F::SrcAlpha: return MTLBlendFactorSourceAlpha;
    case F::OneMinusSrcAlpha: return MTLBlendFactorOneMinusSourceAlpha;
    case F::DstAlpha: return MTLBlendFactorDestinationAlpha;
    case F::OneMinusDstAlpha: return MTLBlendFactorOneMinusDestinationAlpha;
    case F::DstColor: return MTLBlendFactorDestinationColor;
    case F::OneMinusDstColor: return MTLBlendFactorOneMinusDestinationColor;
    case F::SrcAlphaSaturate: return MTLBlendFactorSourceAlphaSaturated;
    case F::ConstantColor: return MTLBlendFactorBlendColor;
    case F::OneMinusConstantColor: return MTLBlendFactorOneMinusBlendColor;
    case F::Src1Color: return MTLBlendFactorSource1Color;
    case F::InvSrc1Color: return MTLBlendFactorOneMinusSource1Color;
    case F::Src1Alpha: return MTLBlendFactorSource1Alpha;
    case F::InvSrc1Alpha: return MTLBlendFactorOneMinusSource1Alpha;
    case F::ConstantAlpha: return MTLBlendFactorBlendAlpha;
    case F::OneMinusConstantAlpha: return MTLBlendFactorOneMinusBlendAlpha;
    default: return MTLBlendFactorOne;
    }
}

MTLBlendOperation BlendOp(AmdGpu::BlendControl::BlendFunc f) {
    using F = AmdGpu::BlendControl::BlendFunc;
    switch (f) {
    case F::Add: return MTLBlendOperationAdd;
    case F::Subtract: return MTLBlendOperationSubtract;
    case F::Min: return MTLBlendOperationMin;
    case F::Max: return MTLBlendOperationMax;
    case F::ReverseSubtract: return MTLBlendOperationReverseSubtract;
    default: return MTLBlendOperationAdd;
    }
}

} // namespace

/// Vertex format of a buffer attribute (0 when Metal has none).
MTLVertexFormat VertexFormat(vk::Format format);

struct PipelineCache::Impl {
    const Instance& instance;
    AmdGpu::Liverpool* liverpool;
    Shader::Pools pools;
    std::unordered_map<u64, std::unique_ptr<Program>> programs;
    std::unordered_map<u64, std::unique_ptr<GraphicsPipeline>> graphics;
    // tlg: async shaders: render pipelines Metal still builds (pso null meanwhile; draws skip).
    struct PendingPso {
        std::atomic<bool> done{false};
        void* pso = nullptr; // +1 retained; valid once done
    };
    std::unordered_map<u64, std::shared_ptr<PendingPso>> pending_psos;
    std::unordered_map<u64, std::unique_ptr<ComputePipeline>> compute;
    std::array<Shader::RuntimeInfo, MaxShaderStages> runtime_infos{};
    std::array<const Shader::Info*, MaxShaderStages> infos{};
    std::array<const Module*, MaxShaderStages> modules{};
    std::optional<Shader::Gcn::FetchShaderData> fetch_shader;
    GraphicsPipelineKey key{};
    PipelineCache::IndirectParams indirect{};

    Impl(const Instance& instance_, AmdGpu::Liverpool* liverpool_)
        : instance{instance_}, liverpool{liverpool_} {}

    const Shader::RuntimeInfo& BuildRuntimeInfo(const AmdGpu::Regs& regs, HwStage stage,
                                                SwStage l_stage);
    const Module* GetProgram(const Shader::Profile& profile, const AmdGpu::Regs& regs,
                             HwStage hw_stage, SwStage sw_stage,
                             const Shader::ShaderParams& params,
                             Shader::Backend::Bindings& binding, const Shader::Info** out_info,
                             bool last_vertex_stage);
    bool RefreshGraphicsKey(const Shader::Profile& profile, const AmdGpu::Regs& regs);
    bool RefreshGraphicsStages(const Shader::Profile& profile, const AmdGpu::Regs& regs);
    GraphicsPipeline* CreateGraphics();
};

const Shader::RuntimeInfo& PipelineCache::Impl::BuildRuntimeInfo(const AmdGpu::Regs& regs,
                                                                 HwStage stage, SwStage l_stage) {
    auto& info = runtime_infos[u32(l_stage)];
    const auto BuildCommon = [&](const auto& program) {
        info.props.num_user_data = program.settings.num_user_regs;
        info.props.num_input_vgprs = program.settings.vgpr_comp_cnt;
        info.props.num_allocated_vgprs = program.NumVgprs();
        info.props.fp_denorm_mode32 = program.settings.fp_denorm_mode32;
        info.props.fp_denorm_mode16_64 = program.settings.fp_denorm_mode64;
        info.props.fp_round_mode32 = program.settings.fp_round_mode32;
        info.props.fp_round_mode16_64 = program.settings.fp_round_mode64;
    };
    info.Initialize(stage, l_stage);
    switch (stage) {
    case HwStage::Vertex:
        BuildCommon(regs.vs_program);
        info.hw.vs.user_clip_plane_mask = regs.clipper_control.user_clip_plane_enable;
        info.hw.vs.num_outputs = MapOutputs(info.hw.vs.outputs, regs.vs_output_control);
        // Metal has no clip control: [-w, w] depth is converted in the shader.
        info.hw.vs.emulate_depth_negative_one_to_one =
            regs.clipper_control.clip_space == AmdGpu::ClipSpace::MinusWToW;
        info.hw.vs.clip_disable = regs.IsClipDisabled();
        info.hw.vs.motion_vectors = false;
        break;
    case HwStage::Fragment: {
        BuildCommon(regs.ps_program);
        info.hw.fs.en_flags = regs.ps_input_ena;
        info.hw.fs.addr_flags = regs.ps_input_addr;
        info.hw.fs.num_inputs = regs.num_interp;
        info.hw.fs.front_face_all_bits = regs.barycentric_control.front_face_all_bits;
        info.hw.fs.depth_before_shader = false;
        info.hw.fs.num_samples =
            regs.ps_input_addr.sample_coverage_ena && regs.ps_input_ena.sample_coverage_ena
                ? regs.aa_config.NumSamples()
                : 1;
        info.hw.fs.z_export_format = regs.z_export_format;
        info.hw.fs.motion_vectors = false;
        const u8 stencil_ref_export_enable =
            regs.depth_shader_control.stencil_op_val_export_enable |
            regs.depth_shader_control.stencil_test_val_export_enable;
        info.hw.fs.mrtz_mask = regs.depth_shader_control.z_export_enable |
                               (stencil_ref_export_enable << 1) |
                               (regs.depth_shader_control.mask_export_enable << 2) |
                               (regs.depth_shader_control.coverage_to_mask_enable << 3);
        const auto& cb0_blend = regs.blend_control[0];
        info.hw.fs.dual_source_blending = false;
        if (cb0_blend.enable) {
            info.hw.fs.dual_source_blending =
                LiverpoolToVK::IsDualSourceBlendFactor(cb0_blend.color_dst_factor) ||
                LiverpoolToVK::IsDualSourceBlendFactor(cb0_blend.color_src_factor);
            if (cb0_blend.separate_alpha_blend) {
                info.hw.fs.dual_source_blending |=
                    LiverpoolToVK::IsDualSourceBlendFactor(cb0_blend.alpha_dst_factor) ||
                    LiverpoolToVK::IsDualSourceBlendFactor(cb0_blend.alpha_src_factor);
            }
        }
        const auto& ps_inputs = regs.ps_inputs;
        for (u32 i = 0; i < regs.num_interp; i++) {
            info.hw.fs.inputs[i] = {
                .param_index = u8(ps_inputs[i].input_offset),
                .is_default = bool(ps_inputs[i].use_default),
                .is_flat = bool(ps_inputs[i].flat_shade),
                .default_value = u8(ps_inputs[i].default_value),
            };
        }
        for (u32 i = 0; i < Shader::MaxColorBuffers; i++) {
            info.hw.fs.color_buffers[i] = key.color_buffers[i];
        }
        info.hw.fs.clip_distance_emulation = false;
        break;
    }
    case HwStage::Compute: {
        const auto& cs_pgm = liverpool->GetCsRegs();
        info.props.num_user_data = cs_pgm.settings.num_user_regs;
        info.props.num_allocated_vgprs = cs_pgm.settings.num_vgprs * 4;
        info.props.fp_denorm_mode32 = cs_pgm.settings.fp_denorm_mode32;
        info.props.fp_denorm_mode16_64 = cs_pgm.settings.fp_denorm_mode64;
        info.props.fp_round_mode32 = cs_pgm.settings.fp_round_mode32;
        info.props.fp_round_mode16_64 = cs_pgm.settings.fp_round_mode64;
        info.hw.cs.workgroup_size = {cs_pgm.num_thread_x.full, cs_pgm.num_thread_y.full,
                                     cs_pgm.num_thread_z.full};
        info.hw.cs.tgid_enable = {cs_pgm.IsTgidEnabled(0), cs_pgm.IsTgidEnabled(1),
                                  cs_pgm.IsTgidEnabled(2)};
        info.hw.cs.shared_memory_size = cs_pgm.SharedMemSize();
        break;
    }
    default:
        break;
    }
    if (l_stage == SwStage::Vertex) {
        info.sw.vs.step_rate_0 = regs.vgt_instance_step_rate_0;
        info.sw.vs.step_rate_1 = regs.vgt_instance_step_rate_1;
        info.sw.vs.vertex_sgpr_offset = indirect.vertex_sgpr_offset;
        info.sw.vs.instance_sgpr_offset = indirect.instance_sgpr_offset;
        info.sw.vs.is_indirect = indirect.is_indirect;
        info.sw.vs.tess_emulated_primitive = false;
    }
    return info;
}

const Module* PipelineCache::Impl::GetProgram(const Shader::Profile& profile,
                                              const AmdGpu::Regs& regs, HwStage hw_stage,
                                              SwStage sw_stage, const Shader::ShaderParams& params,
                                              Shader::Backend::Bindings& binding,
                                              const Shader::Info** out_info,
                                              bool last_vertex_stage) {
    const auto& runtime_info = BuildRuntimeInfo(regs, hw_stage, sw_stage);
    auto [it, inserted] = programs.try_emplace(params.hash);
    if (inserted) {
        it->second = std::make_unique<Program>(hw_stage, sw_stage, params);
    }
    Program& program = *it->second;
    if (program.failed) {
        return nullptr;
    }
    auto& info = program.info;
    info.pgm_base = params.Base();
    info.user_data = params.user_data;
    info.RefreshFlatBuf();

    const auto start = binding;
    static const bool no_fast = std::getenv("TLG_METAL_NO_FAST_PROGRAM") != nullptr;
    const auto remember = [&](size_t index) {
        auto& last = program.last;
        const Module& module = program.modules[index];
        last.valid = true;
        last.user_data.assign(info.user_data.begin(), info.user_data.end());
        const auto flat = info.FlatUserData();
        last.flat.assign(flat.begin(), flat.end());
        last.runtime_info = runtime_info;
        last.start = start;
        last.attribs.clear();
        if (module.spec.fetch_shader_data) {
            for (const auto& attrib : module.spec.fetch_shader_data->attributes) {
                last.attribs.push_back(attrib.GetSharp(info));
            }
        }
        last.module = index;
    };
    if (auto& last = program.last; !no_fast && last.valid && last.module < program.modules.size() &&
                                   last.start == start && SameSpan(last.user_data, info.user_data) &&
                                   SameSpan(last.flat, info.FlatUserData()) &&
                                   last.runtime_info == runtime_info) {
        const Module& module = program.modules[last.module];
        bool same = true;
        if (module.spec.fetch_shader_data) {
            const auto& attributes = module.spec.fetch_shader_data->attributes;
            same = attributes.size() == last.attribs.size();
            for (size_t a = 0; same && a < attributes.size(); ++a) {
                const auto sharp = attributes[a].GetSharp(info);
                same = std::memcmp(&sharp, &last.attribs[a], sizeof(sharp)) == 0;
            }
        }
        if (same) {
            program.last_used = last.module;
            info.AddBindings(binding);
            *out_info = &info;
            return &module;
        }
    }
    if (!program.modules.empty()) {
        auto spec = Shader::StageSpecialization(info, runtime_info, profile, binding);
        auto found = program.last_used < program.modules.size() &&
                             program.modules[program.last_used].spec == spec
                         ? program.modules.begin() + program.last_used
                         : std::ranges::find(program.modules, spec, &Module::spec);
        if (found != program.modules.end()) {
            program.last_used = std::distance(program.modules.begin(), found);
            remember(program.last_used);
            info.AddBindings(binding);
            *out_info = &info;
            return &*found;
        }
    }

    // tlg: async shaders (the in-game setting, as on Vulkan): a new graphics permutation's MSL
    // compiles on the prewarm workers and its draws are skipped until it is ready; compute
    // stays synchronous (game logic). A pending permutation costs one lookup per draw.
    const bool async = sw_stage != SwStage::Compute &&
                       TlgSettings::Get().async_shaders.load(std::memory_order_relaxed) &&
                       MslPrewarm::Get().Running();
    std::optional<Shader::StageSpecialization> pending_key;
    if (async) {
        pending_key.emplace(info, runtime_info, profile, start);
        for (auto it = program.pending.begin(); it != program.pending.end(); ++it) {
            if (it->first == *pending_key) {
                bool still = false;
                MslPrewarm::Get().Poll(it->second, still);
                if (still) {
                    g_async_skips.fetch_add(1, std::memory_order_relaxed);
                    return nullptr;
                }
                program.pending.erase(it); // ready: the compile below takes the library
                break;
            }
        }
    }

    // Compile a new permutation.
    const auto t0 = std::chrono::steady_clock::now();
    auto new_info = Shader::Info(hw_stage, sw_stage, params);
    auto compile_runtime = runtime_info;
    std::vector<u32> spirv;
    try {
        const auto ir = Shader::TranslateProgram(params.code, pools, new_info, compile_runtime,
                                                 profile);
        spirv = Shader::Backend::SPIRV::EmitSPIRV(profile, compile_runtime, ir, binding);
    } catch (const std::exception& e) {
        if (g_failed.fetch_add(1) < 32) {
            std::printf("GPU (Metal): shader %016llx refused: %s\n",
                        (unsigned long long)params.hash, e.what());
        }
        if (program.modules.empty()) {
            program.failed = true;
        }
        return nullptr;
    }
    const bool is_vertex_like = sw_stage == SwStage::Vertex || sw_stage == SwStage::TessellationEval ||
                                sw_stage == SwStage::Geometry;
    // No Y flip in the shader: the viewport maps Vulkan's clip space (see mtl_draw.mm).
    (void)is_vertex_like;
    g_stage_ns[0].fetch_add(NsSince(t0), std::memory_order_relaxed);
    const auto t1 = std::chrono::steady_clock::now();
    MslResult msl = MslDiskCache::Get().Translate(spirv, false);
    g_stage_ns[1].fetch_add(NsSince(t1), std::memory_order_relaxed);
    if (!msl.error.empty()) {
        if (g_failed.fetch_add(1) < 32) {
            std::printf("GPU (Metal): shader %016llx: SPIR-V -> MSL failed: %s\n",
                        (unsigned long long)params.hash, msl.error.c_str());
        }
        if (program.modules.empty()) {
            program.failed = true;
        }
        return nullptr;
    }
    static const char* dump = std::getenv("TLG_METAL_DUMP");
    if (dump) {
        char path[512];
        std::snprintf(path, sizeof(path), "%s/%016llx_%u_%zu.metal", dump,
                      (unsigned long long)params.hash, u32(sw_stage), program.modules.size());
        if (FILE* f = std::fopen(path, "w")) {
            std::fwrite(msl.msl.data(), 1, msl.msl.size(), f);
            std::fclose(f);
        }
    }
    // Debugging: hand-edited MSL for a shader (TLG_METAL_MSL_OVERRIDE=<dir>, files named as the
    // TLG_METAL_DUMP ones).
    if (static const char* override_dir = std::getenv("TLG_METAL_MSL_OVERRIDE"); override_dir) {
        char path[512];
        std::snprintf(path, sizeof(path), "%s/%016llx_%u_%zu.metal", override_dir,
                      (unsigned long long)params.hash, u32(sw_stage), program.modules.size());
        if (FILE* f = std::fopen(path, "rb")) {
            std::string text;
            char buf[4096];
            size_t n;
            while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
                text.append(buf, n);
            }
            std::fclose(f);
            msl.msl = std::move(text);
            std::printf("GPU (Metal): shader %016llx: MSL from %s\n", (unsigned long long)params.hash, path);
        }
    }
    const auto t2 = std::chrono::steady_clock::now();
    // Diagnosis: TLG_METAL_SKIP_SHADERS=<hex>[,<hex>...] refuses those shaders (their draws and
    // dispatches are skipped); with TLG_METAL_DUMP their MSL is still written first.
    if (static const char* skip = std::getenv("TLG_METAL_SKIP_SHADERS"); skip) {
        char want[24];
        std::snprintf(want, sizeof(want), "%llx", (unsigned long long)params.hash);
        for (const char* p = skip; *p;) {
            const char* end = std::strchr(p, ',');
            const size_t n = end ? size_t(end - p) : std::strlen(p);
            const char* q = p;
            if (n > 2 && q[0] == '0' && (q[1] == 'x' || q[1] == 'X')) {
                q += 2;
            }
            if (size_t(p + n - q) == std::strlen(want) && std::strncmp(q, want, p + n - q) == 0) {
                std::printf("GPU (Metal): shader %016llx skipped (TLG_METAL_SKIP_SHADERS)\n",
                            (unsigned long long)params.hash);
                if (program.modules.empty()) {
                    program.failed = true;
                }
                return nullptr;
            }
            p = end ? end + 1 : p + n;
        }
    }
    // tlg: shaders of earlier runs (MSL cache hit) compile here at once: Metal's own cache has
    // them (~1 ms). Going async for them too skipped their draws for a frame or more whenever a
    // new permutation showed up (flames that started, stopped and started again).
    if (async && !msl.cache_hit) {
        std::string source = MslSource(msl.msl);
        bool still = false;
        MslPrewarm::Get().Poll(source, still);
        if (still) {
            program.pending.emplace_back(*pending_key, std::move(source));
            g_async_skips.fetch_add(1, std::memory_order_relaxed);
            g_async_queued.fetch_add(1, std::memory_order_relaxed);
            return nullptr;
        }
    }
    id<MTLFunction> fn = CompileMsl(msl, params.hash, sw_stage == SwStage::Compute ? "compute" : "graphics");
    g_stage_ns[2].fetch_add(NsSince(t2), std::memory_order_relaxed);
    if (!fn) {
        if (program.modules.empty()) {
            program.failed = true;
        }
        return nullptr;
    }
    if (program.modules.empty()) {
        program.info = new_info;
        program.info.pgm_base = params.Base();
        program.info.user_data = params.user_data;
        program.info.RefreshFlatBuf();
    }
    auto spec = Shader::StageSpecialization(program.info, runtime_info, profile, start);
    Module module{std::move(spec), fn, {}};
    module.meta.function = (__bridge void*)fn;
    module.meta.num_buffers = msl.num_buffers;
    module.meta.num_textures = msl.num_textures;
    module.meta.num_samplers = msl.num_samplers;
    module.meta.uses_buffer_sizes = msl.uses_buffer_sizes;
    module.cold = !msl.cache_hit;
    program.modules.push_back(std::move(module));
    program.last_used = program.modules.size() - 1;
    remember(program.last_used);
    g_compiles.fetch_add(1, std::memory_order_relaxed);
    g_compile_ns.fetch_add(std::chrono::duration_cast<std::chrono::nanoseconds>(
                               std::chrono::steady_clock::now() - t0)
                               .count(),
                           std::memory_order_relaxed);
    *out_info = &program.info;
    return &program.modules.back();
}

bool PipelineCache::Impl::RefreshGraphicsKey(const Shader::Profile& profile,
                                             const AmdGpu::Regs& regs) {
    std::memset(&key, 0, sizeof(key));
    const bool db_enabled = GetEffectiveDepthStencilState(regs).needs_attachment;
    key.z_format = db_enabled && regs.depth_buffer.DepthValid() ? regs.depth_buffer.z_info.format
                                                                : AmdGpu::DepthBuffer::ZFormat::Invalid;
    key.stencil_format = db_enabled && regs.depth_buffer.StencilValid()
                             ? regs.depth_buffer.stencil_info.format
                             : AmdGpu::DepthBuffer::StencilFormat::Invalid;
    key.prim_type = regs.primitive_type;
    key.depth_samples = db_enabled ? regs.depth_buffer.NumSamples() : 1;
    key.num_samples = key.depth_samples;
    key.cb_shader_mask = regs.color_shader_mask.raw;
    key.alpha_to_coverage = false;

    const bool skip_cb = regs.color_control.mode == AmdGpu::ColorControl::OperationMode::Disable;
    for (s32 cb = 0; cb < AmdGpu::NUM_COLOR_BUFFERS && !skip_cb; ++cb) {
        const auto& col_buf = regs.color_buffers[cb];
        if (!col_buf || !regs.color_target_mask.GetMask(cb)) {
            continue;
        }
        auto& color_buffer = key.color_buffers[cb];
        color_buffer.data_format = col_buf.GetDataFmt();
        color_buffer.num_format = col_buf.GetNumberFmt();
        color_buffer.num_conversion = col_buf.GetNumberConversion();
        color_buffer.export_format = regs.color_export_format.GetFormat(cb);
        color_buffer.swizzle = col_buf.Swizzle();
    }
    if (!RefreshGraphicsStages(profile, regs)) {
        return false;
    }
    for (s32 cb = 0; cb < s32(key.num_color_attachments) && !skip_cb; ++cb) {
        const auto& col_buf = regs.color_buffers[cb];
        const u32 target_mask = regs.color_target_mask.GetMask(cb);
        if (!col_buf || !target_mask) {
            continue;
        }
        if ((key.mrt_mask & (1u << cb)) == 0) {
            std::memset(&key.color_buffers[cb], 0, sizeof(Shader::PsColorBuffer));
            continue;
        }
        if (regs.blend_control[cb].enable && !col_buf.info.blend_bypass) {
            key.blend_controls[cb] = regs.blend_control[cb];
        }
        key.write_masks[cb] = u8(key.color_buffers[cb].swizzle.ApplyMask(target_mask));
        key.color_samples[cb] = u8(col_buf.NumSamples());
        key.num_samples = std::max<u32>(key.num_samples, col_buf.NumSamples());
    }
    // Metal needs equal sample counts across attachments.
    for (u32 cb = 0; cb < key.num_color_attachments; ++cb) {
        if (key.color_samples[cb]) {
            key.color_samples[cb] = u8(key.num_samples);
        }
    }
    if (db_enabled) {
        key.depth_samples = key.num_samples;
    }
    return true;
}

bool PipelineCache::Impl::RefreshGraphicsStages(const Shader::Profile& profile,
                                                const AmdGpu::Regs& regs) {
    fetch_shader = std::nullopt;
    infos.fill(nullptr);
    modules.fill(nullptr);
    Shader::Backend::Bindings binding{};
    const auto bind_stage = [&](HwStage stage_in, SwStage stage_out, bool last_vertex) -> bool {
        const auto in_idx = static_cast<u32>(stage_in);
        const auto out_idx = static_cast<u32>(stage_out);
        if (!regs.stage_enable.IsStageEnabled(in_idx)) {
            return false;
        }
        const auto* pgm = regs.ProgramForStage(in_idx);
        if (!pgm || !pgm->Address<u32*>()) {
            return false;
        }
        const auto found = AmdGpu::TryGetParams(*pgm);
        if (!found) {
            return false;
        }
        const Shader::Info* info = nullptr;
        const Module* module = GetProgram(profile, regs, stage_in, stage_out, *found, binding,
                                          &info, last_vertex);
        if (!module) {
            return false;
        }
        infos[out_idx] = info;
        modules[out_idx] = module;
        key.stage_hashes[out_idx] = reinterpret_cast<u64>(module);
        if (module->spec.fetch_shader_data) {
            fetch_shader = module->spec.fetch_shader_data;
        }
        return true;
    };

    bind_stage(HwStage::Fragment, SwStage::Fragment, false);
    const auto* fs_info = infos[static_cast<u32>(SwStage::Fragment)];
    key.mrt_mask = fs_info ? fs_info->mrt_mask : 0u;
    key.num_color_attachments = std::bit_width(key.mrt_mask);

    switch (regs.stage_enable.raw) {
    case AmdGpu::ShaderStageEnable::VgtStages::Vs:
        if (!bind_stage(HwStage::Vertex, SwStage::Vertex, true)) {
            return false;
        }
        break;
    default:
        // Tessellation and geometry shaders: not yet (counted by stage set, ReportCompilerStats).
        {
            const u32 raw = u32(regs.stage_enable.raw);
            g_stage_skips[raw == 0xB0u ? 1 : raw == 0x45u ? 2 : raw == 0xADu ? 3 : 4].fetch_add(1, std::memory_order_relaxed);
        }
        return false;
    }

    const auto* vs_info = infos[static_cast<u32>(SwStage::Vertex)];
    if (vs_info && fetch_shader) {
        u32 i = 0;
        for (const auto& attrib : fetch_shader->attributes) {
            if (i >= key.vertex_formats.size()) {
                break;
            }
            const auto& buffer = attrib.GetSharp(*vs_info);
            key.vertex_formats[i] =
                LiverpoolToVK::SurfaceFormat(buffer.GetDataFmt(), buffer.GetNumberFmt());
            key.vertex_strides[i] = buffer.GetStride();
            using InstanceIdType = Shader::Gcn::VertexAttribute::InstanceIdType;
            if (attrib.GetStepRate() == InstanceIdType::OverStepRate0) {
                key.step_rate_0 = regs.vgt_instance_step_rate_0;
            } else if (attrib.GetStepRate() == InstanceIdType::OverStepRate1) {
                key.step_rate_1 = regs.vgt_instance_step_rate_1;
            }
            ++i;
        }
    }
    return true;
}

GraphicsPipeline* PipelineCache::Impl::CreateGraphics() {
    auto pipeline = std::make_unique<GraphicsPipeline>();
    pipeline->key = key;
    pipeline->fetch_shader = fetch_shader;
    for (u32 i = 0; i < MaxShaderStages; ++i) {
        if (modules[i]) {
            pipeline->stages[i] = modules[i]->meta;
            pipeline->stages[i].info = infos[i];
        }
    }
    const auto& vs = pipeline->stages[u32(SwStage::Vertex)];
    const auto& fs = pipeline->stages[u32(SwStage::Fragment)];
    // Diagnosis: TLG_METAL_LOG_PIPELINES=1 names each new pipeline with its time (s since the
    // first one), so the effects that first appear at a given moment can be found.
    if (static const bool log_pl = std::getenv("TLG_METAL_LOG_PIPELINES") != nullptr; log_pl) {
        static const auto t0 = std::chrono::steady_clock::now();
        const double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        std::printf("GPU (Metal): pipeline t=%.2f vs %016llx ps %016llx prim %u rt %u fmt0 %u blend0 %u\n", t,
                    (unsigned long long)(vs.info ? vs.info->pgm_hash : 0),
                    (unsigned long long)(fs.info ? fs.info->pgm_hash : 0), u32(key.prim_type),
                    u32(key.num_color_attachments), u32(key.color_buffers[0].data_format),
                    u32(key.blend_controls[0].enable));
    }

    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = (__bridge id<MTLFunction>)vs.function;
    desc.fragmentFunction = (__bridge id<MTLFunction>)fs.function;
    desc.rasterSampleCount = std::max<u32>(key.num_samples, 1);
    desc.alphaToCoverageEnabled = key.alpha_to_coverage;
    for (u32 cb = 0; cb < key.num_color_attachments; ++cb) {
        const auto& cbuf = key.color_buffers[cb];
        if (cbuf.data_format == AmdGpu::DataFormat::FormatInvalid ||
            (key.mrt_mask & (1u << cb)) == 0) {
            continue;
        }
        const auto vk_format = LiverpoolToVK::SurfaceFormat(cbuf.data_format, cbuf.num_format);
        const auto& f = Metal::GetFormat(vk_format);
        if (!f.metal) {
            continue;
        }
        auto* att = desc.colorAttachments[cb];
        att.pixelFormat = static_cast<MTLPixelFormat>(f.metal);
        const u8 mask = key.write_masks[cb];
        att.writeMask = (mask & 1 ? MTLColorWriteMaskRed : 0) | (mask & 2 ? MTLColorWriteMaskGreen : 0) |
                        (mask & 4 ? MTLColorWriteMaskBlue : 0) | (mask & 8 ? MTLColorWriteMaskAlpha : 0);
        const auto& blend = key.blend_controls[cb];
        if (blend.enable) {
            att.blendingEnabled = YES;
            att.sourceRGBBlendFactor = BlendFactor(blend.color_src_factor);
            att.destinationRGBBlendFactor = BlendFactor(blend.color_dst_factor);
            att.rgbBlendOperation = BlendOp(blend.color_func);
            if (blend.separate_alpha_blend) {
                att.sourceAlphaBlendFactor = BlendFactor(blend.alpha_src_factor);
                att.destinationAlphaBlendFactor = BlendFactor(blend.alpha_dst_factor);
                att.alphaBlendOperation = BlendOp(blend.alpha_func);
            } else {
                att.sourceAlphaBlendFactor = att.sourceRGBBlendFactor;
                att.destinationAlphaBlendFactor = att.destinationRGBBlendFactor;
                att.alphaBlendOperation = att.rgbBlendOperation;
            }
            // Min/max ignore the factors (Vulkan); Metal requires One.
            if (att.rgbBlendOperation == MTLBlendOperationMin || att.rgbBlendOperation == MTLBlendOperationMax) {
                att.sourceRGBBlendFactor = MTLBlendFactorOne;
                att.destinationRGBBlendFactor = MTLBlendFactorOne;
            }
            if (att.alphaBlendOperation == MTLBlendOperationMin || att.alphaBlendOperation == MTLBlendOperationMax) {
                att.sourceAlphaBlendFactor = MTLBlendFactorOne;
                att.destinationAlphaBlendFactor = MTLBlendFactorOne;
            }
        }
    }
    if (key.z_format != AmdGpu::DepthBuffer::ZFormat::Invalid ||
        key.stencil_format != AmdGpu::DepthBuffer::StencilFormat::Invalid) {
        const auto vk_depth = LiverpoolToVK::DepthFormat(key.z_format, key.stencil_format);
        const auto& f = Metal::GetFormat(vk_depth);
        const MTLPixelFormat pf = static_cast<MTLPixelFormat>(f.metal);
        if (f.depth) {
            desc.depthAttachmentPixelFormat = pf;
        }
        if (f.stencil) {
            desc.stencilAttachmentPixelFormat = pf;
        }
    }
    // Vertex input: attribute i (location = GCN semantic) reads buffer vertex_buffer_base + i.
    if (fetch_shader && vs.info) {
        pipeline->vertex_buffer_base = vs.num_buffers;
        MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
        u32 i = 0;
        using InstanceIdType = Shader::Gcn::VertexAttribute::InstanceIdType;
        for (const auto& attrib : fetch_shader->attributes) {
            if (i >= key.vertex_formats.size()) {
                break;
            }
            const u32 buffer_index = pipeline->vertex_buffer_base + i;
            if (buffer_index >= BufferSizesBufferIndex) {
                std::printf("GPU (Metal): too many vertex buffers (%u)\n", buffer_index);
                return nullptr;
            }
            const MTLVertexFormat format = VertexFormat(key.vertex_formats[i]);
            if (format == MTLVertexFormatInvalid) {
                std::printf("GPU (Metal): vertex format %s not supported\n",
                            vk::to_string(key.vertex_formats[i]).c_str());
                return nullptr;
            }
            vd.attributes[attrib.semantic].format = format;
            vd.attributes[attrib.semantic].offset = 0;
            vd.attributes[attrib.semantic].bufferIndex = buffer_index;
            auto* layout = vd.layouts[buffer_index];
            const u32 stride = key.vertex_strides[i];
            const auto step = attrib.GetStepRate();
            if (stride == 0) {
                layout.stepFunction = MTLVertexStepFunctionConstant;
                layout.stepRate = 0;
                layout.stride = 4;
            } else if (step == InstanceIdType::None) {
                layout.stepFunction = MTLVertexStepFunctionPerVertex;
                layout.stride = stride;
            } else {
                layout.stepFunction = MTLVertexStepFunctionPerInstance;
                layout.stepRate = step == InstanceIdType::OverStepRate0
                                      ? std::max<u32>(key.step_rate_0, 1)
                                      : step == InstanceIdType::OverStepRate1
                                            ? std::max<u32>(key.step_rate_1, 1)
                                            : 1;
                layout.stride = stride;
            }
            ++i;
        }
        desc.vertexDescriptor = vd;
    }
    const u64 hash = XXH3_64bits(&key, sizeof(key));
    // tlg: with async shaders the pipeline (Metal's backend compile, up to ~0.7 s for a burst of
    // new shaders) builds on Metal's compiler threads; its draws are skipped until it is ready.
    // Only pipelines with a shader new to this run (not in the MSL cache): Metal's pipeline
    // cache has the others, created at once (skipping their draws made flames blink).
    const bool cold_stage = std::ranges::any_of(modules, [](const Module* m) { return m && m->cold; });
    if (cold_stage && TlgSettings::Get().async_shaders.load(std::memory_order_relaxed)) {
        auto pending = std::make_shared<PendingPso>();
        const u64 vs_hash = vs.info ? vs.info->pgm_hash : 0, fs_hash = fs.info ? fs.info->pgm_hash : 0;
        // A blocking create on GCD's concurrent queue: Metal's completionHandler variant was
        // seen building one pipeline at a time (a single busy MTLCompilerService).
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError* err = nil;
            id<MTLRenderPipelineState> state =
                [Metal::Device() newRenderPipelineStateWithDescriptor:desc error:&err];
            if (!state && g_failed.fetch_add(1) < 32) {
                std::printf("GPU (Metal): render pipeline (vs %016llx ps %016llx) failed: %s\n",
                            (unsigned long long)vs_hash, (unsigned long long)fs_hash,
                            err.localizedDescription.UTF8String);
            }
            pending->pso = state ? (__bridge_retained void*)state : nullptr;
            pending->done.store(true, std::memory_order_release);
        });
        pending_psos[hash] = std::move(pending);
        g_async_queued.fetch_add(1, std::memory_order_relaxed);
        g_async_skips.fetch_add(1, std::memory_order_relaxed);
        graphics[hash] = std::move(pipeline);
        return nullptr;
    }
    NSError* error = nil;
    const auto tp = std::chrono::steady_clock::now();
    id<MTLRenderPipelineState> pso = [Metal::Device() newRenderPipelineStateWithDescriptor:desc
                                                                                     error:&error];
    g_stage_ns[3].fetch_add(NsSince(tp), std::memory_order_relaxed);
    if (!pso) {
        if (g_failed.fetch_add(1) < 32) {
            std::printf("GPU (Metal): render pipeline (vs %016llx ps %016llx) failed: %s\n",
                        (unsigned long long)(vs.info ? vs.info->pgm_hash : 0),
                        (unsigned long long)(fs.info ? fs.info->pgm_hash : 0),
                        error.localizedDescription.UTF8String);
        }
        return nullptr;
    }
    pipeline->pso = (__bridge_retained void*)pso;
    g_pipelines.fetch_add(1, std::memory_order_relaxed);
    auto* raw = pipeline.get();
    graphics[hash] = std::move(pipeline);
    return raw;
}

PipelineCache::PipelineCache(const Instance& instance, Scheduler&, AmdGpu::Liverpool* liverpool)
    : impl{std::make_unique<Impl>(instance, liverpool)} {
    profile = Shader::Profile{
        .max_viewport_width = 16384,
        .max_viewport_height = 16384,
        .max_shared_memory_size = 32768,
        .supported_spirv = 0x00010300,
        .subgroup_size = 32,
        .support_int8 = true,
        .support_int16 = true,
        .support_int64 = true,
        .support_float16 = true,
        .support_float64 = false,
        .support_fp32_denorm_flush = true,
        // Inf/NaN kept (Metal's relaxed math mode honors them): the recompiler emits GCN's
        // inf/nan rules only then; without it Delsin's vest renders wrong.
        .support_fp16_signed_zero_inf_nan_preserve = true,
        .support_fp32_signed_zero_inf_nan_preserve = true,
        .supports_image_load_store_lod = true,
        .supports_native_cube_calc = false,
        .supports_trinary_minmax = false,
        .supports_buffer_fp32_atomic_min_max = false,
        .supports_image_fp32_atomic_min_max = false,
        .supports_buffer_int64_atomics = false,
        .supports_shared_int64_atomics = false,
        .supports_workgroup_explicit_memory_layout = false,
        .supports_amd_shader_explicit_vertex_parameter = false,
        .supports_fragment_shader_barycentric = false,
        .needs_manual_interpolation = false,
        .needs_lds_barriers = true,
        .needs_buffer_offsets = true,
        .needs_unorm_fixup = false,
        .needs_clip_distance_emulation = false,
        .supports_shader_stencil_export = true,
        .block1d_as_2d = true,
        // No per-operation NoContraction: CompileMsl turns contraction off for whole shaders
        // (fused multiply-adds turn Delsin's vest into white/black blotches).
        .fast_fp = true,
        .vertex_scaled_as_int = true,
        // GCN min/max semantics with NaN (black squares on faces with fast::min/max).
        .nan_min_max = true,
        .pkrtz_saturate = true,
        .buffer_bounds_check = true,
        // Bounded loops: a stuck shader loop otherwise keeps the GPU busy after exit.
        .loop_guard = 1u << 20,
        .integer_moves = true,
    };
    if (const char* env = std::getenv("TLG_METAL_LOOP_GUARD"); env) {
        profile.loop_guard = u32(std::strtoul(env, nullptr, 0)); // 0 = off
    }
    if (const char* env = std::getenv("TLG_METAL_BOUNDS"); env && env[0] == '0') {
        profile.buffer_bounds_check = false;
    }
    if (const char* env = std::getenv("TLG_METAL_PKRTZ"); env && env[0] == '0') {
        profile.pkrtz_saturate = false;
    }
    if (const char* env = std::getenv("TLG_METAL_NAN_MINMAX"); env && env[0] == '0') {
        profile.nan_min_max = false;
    }
    if (const char* env = std::getenv("TLG_METAL_FP"); env && env[0] == 'd') {
        profile.fast_fp = false;
        std::printf("GPU (Metal): NoContraction on every float op (TLG_METAL_FP=decorated, slow)\n");
    }
    AmdGpu::all_1d_as_2d.store(true, std::memory_order_relaxed);
    // TLG_METAL_CLAMP_LAYERS=0: array sample layers as the shader computes them (unclamped).
    if (const char* env = std::getenv("TLG_METAL_CLAMP_LAYERS"); !(env && env[0] == '0')) {
        Shader::clamp_array_layers.store(true, std::memory_order_relaxed);
    }
}

PipelineCache::~PipelineCache() = default;

const GraphicsPipeline* PipelineCache::GetGraphicsPipeline(IndirectParams params) {
    const auto& regs = impl->liverpool->regs;
    impl->indirect = params;
    if (!impl->RefreshGraphicsKey(profile, regs)) {
        return nullptr;
    }
    const u64 hash = XXH3_64bits(&impl->key, sizeof(impl->key));
    if (const auto it = impl->graphics.find(hash); it != impl->graphics.end()) {
        // The program infos of this draw (sharps, user data) were refreshed by the key refresh.
        auto* pipeline = it->second.get();
        for (u32 i = 0; i < MaxShaderStages; ++i) {
            pipeline->stages[i].info = impl->infos[i];
        }
        if (!pipeline->pso && !impl->pending_psos.empty()) {
            if (const auto p = impl->pending_psos.find(hash); p != impl->pending_psos.end()) {
                if (!p->second->done.load(std::memory_order_acquire)) {
                    g_async_skips.fetch_add(1, std::memory_order_relaxed);
                    return nullptr;
                }
                pipeline->pso = p->second->pso; // null: failed, stays skipped
                if (pipeline->pso) {
                    g_pipelines.fetch_add(1, std::memory_order_relaxed);
                }
                impl->pending_psos.erase(p);
            }
        }
        return pipeline->pso ? pipeline : nullptr;
    }
    auto* created = impl->CreateGraphics();
    if (!created && !impl->pending_psos.contains(hash)) {
        // Remember the failure.
        auto failed = std::make_unique<GraphicsPipeline>();
        failed->key = impl->key;
        impl->graphics[hash] = std::move(failed);
    }
    return created;
}

const ComputePipeline* PipelineCache::GetComputePipeline() {
    const auto& cs_pgm = impl->liverpool->GetCsRegs();
    const auto found = AmdGpu::TryGetParams(cs_pgm);
    if (!found) {
        return nullptr;
    }
    Shader::Backend::Bindings binding{};
    const Shader::Info* info = nullptr;
    const Module* module = impl->GetProgram(profile, impl->liverpool->regs, HwStage::Compute,
                                            SwStage::Compute, *found, binding, &info, false);
    if (!module) {
        return nullptr;
    }
    const u64 hash = reinterpret_cast<u64>(module);
    auto& slot = impl->compute[hash];
    if (!slot) {
        slot = std::make_unique<ComputePipeline>();
        slot->hash = found->hash;
        slot->stage = module->meta;
        NSError* error = nil;
        id<MTLComputePipelineState> pso =
            [Metal::Device() newComputePipelineStateWithFunction:module->function error:&error];
        if (!pso) {
            if (g_failed.fetch_add(1) < 32) {
                std::printf("GPU (Metal): compute pipeline %016llx failed: %s\n",
                            (unsigned long long)found->hash, error.localizedDescription.UTF8String);
            }
        } else {
            slot->pso = (__bridge_retained void*)pso;
        }
        slot->workgroup_size = {cs_pgm.num_thread_x.full, cs_pgm.num_thread_y.full,
                                cs_pgm.num_thread_z.full};
    }
    slot->stage.info = info;
    return slot->pso ? slot.get() : nullptr;
}

void PipelineCache::ReportCompilerStats() {
    {
        std::string skipped;
        for (u32 i = 0; i < 16; ++i) {
            if (const u64 n = g_stage_skips[i].exchange(0)) {
                static const char* names[] = {"vs", "es+gs", "ls+hs (tess)", "ls+hs+es+gs", "other"};
                skipped += std::string(" ") + names[i < 5 ? i : 4] + ":" + std::to_string(n);
            }
        }
        if (!skipped.empty()) {
            std::printf("GPU (Metal): draws dropped for unsupported shader stages (5 s):%s\n", skipped.c_str());
        }
    }
    if (const u32 queued = g_async_queued.exchange(0), skips = g_async_skips.exchange(0);
        queued || skips) {
        std::printf("GPU (Metal): async shaders: %u queued, %u stage lookups skipped while "
                    "compiling\n",
                    queued, skips);
    }
    const u32 compiles = g_compiles.exchange(0);
    if (compiles) {
        std::printf("GPU (Metal): %u shaders compiled (%.0f ms: recompile %.0f, spirv-cross %.0f, "
                    "msl %.0f; %u MSL cache hits), %u pipelines (%.0f ms), %u failures\n",
                    compiles, g_compile_ns.exchange(0) / 1e6, g_stage_ns[0].exchange(0) / 1e6,
                    g_stage_ns[1].exchange(0) / 1e6, g_stage_ns[2].exchange(0) / 1e6,
                    MslDiskCache::Get().TakeHits(), g_pipelines.exchange(0), g_stage_ns[3].exchange(0) / 1e6, g_failed.load());
    }
}

} // namespace Vulkan
