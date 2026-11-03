// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: SPIR-V -> MSL with SPIRV-Cross.

#include <cstdio>

#include <spirv_cross/spirv_msl.hpp>

#include "mtl_objc.h"
#include "mtl_shader.h"

namespace Metal {

TranslatedShader TranslateToMsl(std::span<const u32> spirv, const TranslateOptions& options) {
    TranslatedShader out;
    try {
        spirv_cross::CompilerMSL compiler(spirv.data(), spirv.size());
        spirv_cross::CompilerMSL::Options msl;
        msl.platform = spirv_cross::CompilerMSL::Options::macOS;
        msl.set_msl_version(3, 1);
        msl.enable_decoration_binding = false;
        msl.pad_fragment_output_components = true;
        msl.invariant_float_math = options.invariant_position;
        msl.force_native_arrays = false;
        msl.argument_buffers = false;
        msl.use_framebuffer_fetch_subpasses = true;
        msl.texture_buffer_native = true;
        compiler.set_msl_options(msl);

        auto common = compiler.get_common_options();
        common.vertex.flip_vert_y = false;
        common.vertex.fixup_clipspace = false;
        compiler.set_common_options(common);

        const auto model = compiler.get_execution_model();
        for (const auto& slot : options.slots) {
            spirv_cross::MSLResourceBinding b{};
            b.stage = model;
            b.desc_set = slot.set;
            b.binding = slot.binding;
            b.count = 1;
            switch (slot.kind) {
            case ResourceKind::Buffer:
                b.basetype = spirv_cross::SPIRType::Struct;
                b.msl_buffer = slot.index;
                break;
            case ResourceKind::Texture:
                b.basetype = spirv_cross::SPIRType::Image;
                b.msl_texture = slot.index;
                break;
            case ResourceKind::Sampler:
                b.basetype = spirv_cross::SPIRType::Sampler;
                b.msl_sampler = slot.index;
                break;
            }
            compiler.add_msl_resource_binding(b);
        }
        spirv_cross::MSLResourceBinding push{};
        push.stage = model;
        push.desc_set = spirv_cross::kPushConstDescSet;
        push.binding = spirv_cross::kPushConstBinding;
        push.msl_buffer = options.push_constant_buffer;
        compiler.add_msl_resource_binding(push);

        out.msl = compiler.compile();
        const auto entries = compiler.get_entry_points_and_stages();
        out.entry = entries.empty() ? "main0"
                                    : compiler.get_cleansed_entry_point_name(entries[0].name,
                                                                             entries[0].execution_model);
    } catch (const std::exception& e) {
        out.error = e.what();
    }
    return out;
}

void* NewComputePipeline(std::span<const u32> spirv, std::span<const u32> spec,
                         const TranslateOptions& options, const char* label) {
    const TranslatedShader shader = TranslateToMsl(spirv, options);
    if (!shader.error.empty()) {
        std::printf("GPU (Metal): %s: SPIR-V translation failed: %s\n", label, shader.error.c_str());
        return nullptr;
    }
    NSError* error = nil;
    MTLCompileOptions* compile = [MTLCompileOptions new];
    compile.languageVersion = MTLLanguageVersion3_1;
    compile.mathMode = MTLMathModeFast;
    id<MTLLibrary> library = [Device() newLibraryWithSource:[NSString stringWithUTF8String:shader.msl.c_str()]
                                                    options:compile
                                                      error:&error];
    if (!library) {
        std::printf("GPU (Metal): %s: MSL compile failed: %s\n", label,
                    error.localizedDescription.UTF8String);
        return nullptr;
    }
    MTLFunctionConstantValues* constants = [MTLFunctionConstantValues new];
    for (u32 i = 0; i < spec.size(); ++i) {
        const u32 value = spec[i];
        [constants setConstantValue:&value type:MTLDataTypeUInt atIndex:i];
    }
    id<MTLFunction> fn = [library newFunctionWithName:[NSString stringWithUTF8String:shader.entry.c_str()]
                                       constantValues:constants
                                                error:&error];
    if (!fn) {
        std::printf("GPU (Metal): %s: function: %s\n", label, error.localizedDescription.UTF8String);
        return nullptr;
    }
    id<MTLComputePipelineState> pso = [Device() newComputePipelineStateWithFunction:fn error:&error];
    if (!pso) {
        std::printf("GPU (Metal): %s: pipeline: %s\n", label, error.localizedDescription.UTF8String);
        return nullptr;
    }
    return (__bridge_retained void*)pso;
}

} // namespace Metal
