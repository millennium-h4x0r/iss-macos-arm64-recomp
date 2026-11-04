// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <atomic>
#include "common/types.h"

namespace Shader {

struct Profile {
    u32 max_viewport_width{};
    u32 max_viewport_height{};
    u32 max_shared_memory_size{};
    u32 supported_spirv{0x00010000};
    u32 subgroup_size{};
    u32 sparse_page_shift{};
    bool support_int8{};
    bool support_int16{};
    bool support_int64{};
    bool support_float16{};
    bool support_float64{};
    bool supports_denorm_behavior_independence{};
    bool supports_rounding_mode_independence{};
    bool support_fp16_denorm_preserve{};
    bool support_fp16_denorm_flush{};
    bool support_fp16_round_to_zero{};
    bool support_fp32_denorm_preserve{};
    bool support_fp32_denorm_flush{};
    bool support_fp32_round_to_zero{};
    bool support_fp64_denorm_preserve{};
    bool support_fp64_denorm_flush{};
    bool support_fp64_round_to_zero{};
    bool support_fp16_signed_zero_inf_nan_preserve{};
    bool support_fp32_signed_zero_inf_nan_preserve{};
    bool support_fp64_signed_zero_inf_nan_preserve{};
    bool supports_image_load_store_lod{};
    bool supports_maximal_reconvergence{}; // tlg: BP06
    bool supports_native_cube_calc{};
    bool supports_trinary_minmax{};
    bool supports_buffer_fp32_atomic_min_max{};
    bool supports_image_fp32_atomic_min_max{};
    bool supports_buffer_int64_atomics{};
    bool supports_shared_int64_atomics{};
    bool supports_workgroup_explicit_memory_layout{};
    bool supports_amd_shader_explicit_vertex_parameter{};
    bool supports_fragment_shader_barycentric{};
    bool supports_shader_subgroup_clock{};
    bool has_broken_spirv_clamp{};
    bool lower_left_origin_mode{};
    bool needs_manual_interpolation{};
    /// tlg: NVIDIA without fragment shader barycentrics (Pascal and older).
    bool needs_integer_interpolation_fix{};
    bool needs_lds_barriers{};
    bool needs_buffer_offsets{};
    bool needs_unorm_fixup{};
    bool needs_clip_distance_emulation{};
    bool supports_shader_stencil_export{};
    /// tlg: TLG_LIGHTING_TEST=dref (vk_lighting_test.h): depth comparisons return the result
    /// in all four channels instead of (v, 0, 0, 0).
    bool dref_broadcast{};
    /// tlg: block-compressed 1D textures are 2D images (video_core/amdgpu/tlg_block1d.h).
    bool block1d_as_2d{};
    /// tlg: tiny BC textures decoded to plain images (video_core/amdgpu/tlg_bc_tiny.h).
    bool bc_tiny_decode{};
    /// tlg: TLG_FAST_FP=1, no NoContraction decorations and no signed zero/inf/nan preserve mode:
    /// the driver may fuse and reorder float math (GCN's exact rounding is not kept).
    bool fast_fp{};
    /// tlg (Metal): USCALED/SSCALED vertex attributes are read as integers and converted to
    /// float in the shader (Metal has no scaled vertex formats).
    bool vertex_scaled_as_int{};
    /// tlg (Metal): min/max/clamp are NMin/NMax/NClamp (a NaN operand gives the other one, as on
    /// GCN). SPIRV-Cross turns FMin/FMax/FClamp into fast::min/max/clamp, which may return the
    /// NaN on Apple GPUs: max(x, 0) then no longer removes it and blurs spread it into squares.
    bool nan_min_max{};
    /// tlg (Metal): v_cvt_pkrtz_f16_f32 saturates finite overflow to +-65504 like GCN's round
    /// toward zero (Inf in the G-buffer turns into NaN squares on faces after the lighting).
    bool pkrtz_saturate{};
    /// tlg (Metal): guest buffer loads past the bound range return 0 and such stores are dropped,
    /// as GCN does with num_records (Vulkan gets this from robust buffer access; Metal reads the
    /// neighbouring guest memory: huge values in face shading, black squares after the blurs).
    bool buffer_bounds_check{};
    /// tlg (Metal): caps the loop back-edges one invocation takes (0 = no cap). A shader stuck in
    /// a loop on Metal leaves an unkillable GPU job running after the process is gone (only a
    /// reboot clears it); Vulkan drivers time out and reset.
    u32 loop_guard{};
    /// tlg (Metal): V_MOV_B32 / V_CNDMASK_B32 without input modifiers move integers, not floats
    /// (GCN moves bits). As floats, small integers are denormals and Metal flushes them in a
    /// float select: a binary search's index stuck at 0 and the loop never ended (GPU hang).
    bool integer_moves{};

    bool operator==(const Profile&) const = default;
};

/// tlg (Metal): samples of array images clamp the layer to the image's layers, as Vulkan's
/// sampler does (Metal reads nothing for a layer past the end: flipbook fire sprites blinked).
inline std::atomic<bool> clamp_array_layers{false};

} // namespace Shader
