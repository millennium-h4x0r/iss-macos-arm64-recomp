// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: GCN stencil faces (separate test and op values) as one reference per face.
// Copied from the Vulkan renderer (vk_rasterizer.cpp, from shadPS4-Infamous-FixBuild 03db8f14).
#pragma once
#include <array>
#include <optional>
#include "video_core/amdgpu/regs.h"
#include "video_core/renderer_vulkan/liverpool_to_vk.h"
namespace Vulkan {
struct StencilFaceState {
    vk::StencilOp fail_op;
    vk::StencilOp pass_op;
    vk::StencilOp depth_fail_op;
    u32 reference;
};

// tlg: from shadPS4-Infamous-FixBuild 03db8f14 (GPL-2.0-or-later). GCN has separate stencil test
// (STENCILTESTVAL) and replace (STENCILOPVAL) values, while a Vulkan face has a single reference
// for both. Finds a reference that keeps the test exact and still writes what every replacing op
// should, turning such ops into equivalent ones (zero, keep, invert, increment, decrement) where
// the stencil value is known. Returns nullopt if it can't. inFAMOUS hits the conflict ~9500 times
// a session (effects masked by the character silhouette). Checked by the fork against a model of
// the GCN stencil unit (400k random face configurations).
inline std::optional<StencilFaceState> ResolveStencilFace(AmdGpu::CompareFunc func,
                                                          const AmdGpu::StencilRefMask& ref,
                                                          u32 write_mask, AmdGpu::StencilFunc fail,
                                                          AmdGpu::StencilFunc zpass,
                                                          AmdGpu::StencilFunc zfail) {
    using AmdGpu::CompareFunc;
    using AmdGpu::StencilFunc;
    const u32 test_val = ref.stencil_test_val;
    const u32 compare_mask = ref.stencil_mask;
    write_mask &= 0xFF;
    const bool test_uses_reference = func != CompareFunc::Always && func != CompareFunc::Never;

    const auto written_value = [&](StencilFunc op) -> std::optional<u32> {
        switch (op) {
        case StencilFunc::ReplaceTest:
            return test_val;
        case StencilFunc::ReplaceOp:
            return ref.stencil_op_val;
        case StencilFunc::Ones:
            return 0xFFU;
        default:
            return std::nullopt;
        }
    };

    // An EQUAL test that passed, or a NOTEQUAL test that failed, means the stencil value matches
    // test_val in the compared bits, which is enough to know what a write will change.
    const bool written_bits_compared = (write_mask & ~compare_mask) == 0;
    const bool whole_value_known = compare_mask == 0xFF && write_mask == 0xFF;
    const bool known_on_pass = func == CompareFunc::Equal && written_bits_compared;
    const bool known_on_fail = func == CompareFunc::NotEqual && written_bits_compared;

    const auto resolve = [&](StencilFunc op, u32 reference,
                             bool value_known) -> std::optional<vk::StencilOp> {
        const auto value = written_value(op);
        if (!value) {
            return LiverpoolToVK::StencilOp(op);
        }
        const u32 target = *value & write_mask;
        if (target == (reference & write_mask)) {
            return vk::StencilOp::eReplace;
        }
        if (target == 0) {
            return vk::StencilOp::eZero;
        }
        if (value_known) {
            if (target == (test_val & write_mask)) {
                return vk::StencilOp::eKeep;
            }
            if (target == (~test_val & write_mask)) {
                return vk::StencilOp::eInvert;
            }
            if (whole_value_known && *value == ((test_val + 1) & 0xFF)) {
                return vk::StencilOp::eIncrementAndWrap;
            }
            if (whole_value_known && *value == ((test_val - 1) & 0xFF)) {
                return vk::StencilOp::eDecrementAndWrap;
            }
        }
        return std::nullopt;
    };

    // Try each written value as the reference. When the test reads the reference, its compared
    // bits must stay those of test_val, and only the rest can carry the written value.
    const std::array<std::optional<u32>, 4> candidates = {
        written_value(zpass), written_value(zfail), written_value(fail), test_val};
    for (const auto& candidate : candidates) {
        if (!candidate) {
            continue;
        }
        const u32 reference = test_uses_reference
                                  ? (test_val & compare_mask) | (*candidate & ~compare_mask & 0xFF)
                                  : *candidate;
        const auto fail_op = resolve(fail, reference, known_on_fail);
        const auto pass_op = resolve(zpass, reference, known_on_pass);
        const auto depth_fail_op = resolve(zfail, reference, known_on_pass);
        if (fail_op && pass_op && depth_fail_op) {
            return StencilFaceState{*fail_op, *pass_op, *depth_fail_op, reference};
        }
    }
    return std::nullopt;
}
} // namespace Vulkan
