// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: SPIR-V -> MSL (SPIRV-Cross) -> Metal libraries.

#pragma once

#include <span>
#include <string>
#include <vector>

#include "common/types.h"

namespace Metal {

enum class ResourceKind : u8 { Buffer, Texture, Sampler };

/// Where a Vulkan descriptor (set, binding) lands in Metal's argument tables.
struct ResourceSlot {
    u32 set = 0;
    u32 binding = 0;
    ResourceKind kind = ResourceKind::Buffer;
    u32 index = 0; ///< [[buffer(n)]], [[texture(n)]] or [[sampler(n)]]
};

struct TranslateOptions {
    std::vector<ResourceSlot> slots;
    /// Push constants land in [[buffer(push_constant_buffer)]].
    u32 push_constant_buffer = 30;
    /// Vertex inputs come from [[buffer(vertex_buffer_base + binding)]] (stage_in).
    u32 vertex_buffer_base = 16;
    bool invariant_position = false;
};

struct TranslatedShader {
    std::string msl;
    std::string entry;
    std::string error; ///< non-empty when translation failed
};

TranslatedShader TranslateToMsl(std::span<const u32> spirv, const TranslateOptions& options);

/// A compute pipeline (id<MTLComputePipelineState>, +1 reference) from SPIR-V with spec
/// constants 0..N-1 set to `spec` (32-bit unsigned), or null on failure (logged).
void* NewComputePipeline(std::span<const u32> spirv, std::span<const u32> spec,
                         const TranslateOptions& options, const char* label);

} // namespace Metal
