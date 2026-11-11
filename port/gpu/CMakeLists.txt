# tlg GPU library: shadPS4 video core + shader recompiler + Gnm/VideoOut
# drivers, adapted to the native_probe runtime through shims in shim/.
cmake_minimum_required(VERSION 3.24)
project(tlggpu LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()
# Frame pointers keep the loader's thread dumps (watchdog, SIGUSR2 sampling) walkable.
add_compile_options(-fno-omit-frame-pointer)

# tlg: link-time optimization (TLG_LTO, default on) and profile-guided optimization
# (TLG_PGO: off, generate = instrumented build writing into TLG_PGO_DIR, use = build with that
# profile). Covers tlggpu and the static libraries linked into it. No -march: the same build
# runs on the Steam Deck.
option(TLG_LTO "Link-time optimization of tlggpu" ON)
set(TLG_PGO "off" CACHE STRING "Profile-guided optimization: off, generate, use")
set(TLG_PGO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../pgo" CACHE PATH "Profile directory")
if (TLG_LTO)
    include(CheckIPOSupported)
    check_ipo_supported(RESULT tlg_ipo_ok OUTPUT tlg_ipo_error)
    if (tlg_ipo_ok)
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
    else()
        message(WARNING "LTO unavailable: ${tlg_ipo_error}")
    endif()
endif()
if (TLG_PGO STREQUAL "generate")
    # Atomic counters: the GPU, recording, preparation and copy threads run the same code.
    add_compile_options(-fprofile-generate=${TLG_PGO_DIR} -fprofile-update=atomic)
    add_link_options(-fprofile-generate=${TLG_PGO_DIR})
    add_compile_definitions(TLG_PGO_GENERATE)
elseif (TLG_PGO STREQUAL "use")
    # Partial training keeps unprofiled code optimized normally; counters from concurrent
    # threads can be slightly inconsistent (correction). Functions changed since the profile
    # (or built differently for it, tlggpu_init) are compiled without it.
    add_compile_options(-fprofile-use=${TLG_PGO_DIR} -fprofile-partial-training
                        -fprofile-correction -Wno-missing-profile -Wno-coverage-mismatch)
endif()

find_package(Vulkan REQUIRED)
# Pinned Vulkan-Headers (submodule) ahead of the system ones: distro headers can lag behind the
# extensions the shadPS4 video core uses (e.g. Fedora 44 ships 1.4.341, VALVE mixed float dot is newer).
if (EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/vulkan-headers/include/vulkan/vulkan.hpp)
    include_directories(BEFORE SYSTEM ${CMAKE_CURRENT_SOURCE_DIR}/third_party/vulkan-headers/include)
endif()
find_package(fmt REQUIRED)
find_package(Boost REQUIRED)
# tlg (Windows): MSYS2 has no magic_enum/miniz packages; the submodules are used instead.
# The pinned submodule is preferred: Fedora's magic_enum installs flat headers (no magic_enum/ dir).
if (NOT EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/magic_enum/include/magic_enum/magic_enum.hpp)
    find_package(magic_enum QUIET)
endif()
if (NOT magic_enum_FOUND)
    add_library(magic_enum INTERFACE)
    add_library(magic_enum::magic_enum ALIAS magic_enum)
    target_include_directories(magic_enum INTERFACE third_party/magic_enum/include
                                                    third_party/magic_enum/include/magic_enum)
endif()
find_package(tsl-robin-map REQUIRED)
find_package(VulkanMemoryAllocator CONFIG QUIET)
if (NOT VulkanMemoryAllocator_FOUND)
    # MSYS2 ships the header (include/vma/vk_mem_alloc.h) without a CMake package.
    find_path(VMA_INCLUDE_DIR vk_mem_alloc.h PATH_SUFFIXES vma REQUIRED)
    add_library(VulkanMemoryAllocator INTERFACE)
    add_library(GPUOpen::VulkanMemoryAllocator ALIAS VulkanMemoryAllocator)
    target_include_directories(VulkanMemoryAllocator INTERFACE ${VMA_INCLUDE_DIR})
endif()
find_package(PkgConfig REQUIRED)
pkg_check_modules(XXHASH REQUIRED IMPORTED_TARGET libxxhash)
pkg_check_modules(SDL3 REQUIRED IMPORTED_TARGET sdl3)
if (NOT WIN32 AND NOT APPLE)
    pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)
endif()
find_package(miniz QUIET)
if (NOT miniz_FOUND)
    set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(BUILD_FUZZERS OFF CACHE BOOL "" FORCE)
    set(BUILD_SHARED_LIBS OFF)
    set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
    add_subdirectory(third_party/miniz EXCLUDE_FROM_ALL)
    unset(CMAKE_POLICY_VERSION_MINIMUM)
    add_library(miniz::miniz ALIAS miniz)
endif()
find_package(Zydis QUIET)
if (NOT Zydis_FOUND)
    # Fedora/Nobara ship zydis-devel with a pkg-config file only.
    pkg_check_modules(ZYDIS REQUIRED IMPORTED_TARGET zydis)
    add_library(Zydis::Zydis ALIAS PkgConfig::ZYDIS)
endif()
find_program(GLSLANG_COMPILER NAMES glslang glslangValidator REQUIRED)

set(SIRIT_USE_SYSTEM_SPIRV_HEADERS OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/sirit EXCLUDE_FROM_ALL)

# tlg: FSR 3.1 temporal upscaling / frame generation, native Vulkan (MIT, FireBurn/FSR-Vulkan).
set(FFX_VK_PORTABLE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(FFX_VK_PORTABLE_BUILD_PROBE OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/fsr-vulkan EXCLUDE_FROM_ALL)

# Host shaders -> headers (same scheme as shadPS4's host_shaders/CMakeLists.txt).
set(SHADER_SRC ${CMAKE_CURRENT_SOURCE_DIR}/shadps4/video_core/host_shaders)
set(SHADER_INCLUDE ${CMAKE_CURRENT_BINARY_DIR}/include)
set(SHADER_DIR ${SHADER_INCLUDE}/video_core/host_shaders)
set(SHADER_HEADERS "")
function(add_host_shader FILENAME SHADER_NAME)
    set(OUT ${SHADER_DIR}/${SHADER_NAME}.h)
    string(TOUPPER ${SHADER_NAME} SYMBOL)
    set(DEFINES ${ARGN})
    list(TRANSFORM DEFINES PREPEND "-D")
    add_custom_command(OUTPUT ${OUT}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${SHADER_DIR}
        COMMAND ${GLSLANG_COMPILER} --target-env vulkan1.3 -o ${OUT} --vn ${SYMBOL} ${DEFINES} ${SHADER_SRC}/${FILENAME}
        COMMAND ${CMAKE_COMMAND} "-DHEADER_FILE=${OUT}" -P ${SHADER_SRC}/AddShaderHeaderInclude.cmake
        DEPENDS ${SHADER_SRC}/${FILENAME} VERBATIM)
    set(SHADER_HEADERS ${SHADER_HEADERS} ${OUT} PARENT_SCOPE)
endfunction()
add_host_shader(color_to_ms_depth.frag color_to_ms_depth_frag)
add_host_shader(color_to_ms_depth.frag color_to_ms_depth_fallback_frag SAMPLE_FALLBACK=1)
add_host_shader(ms_image_blit.frag ms_image_blit_frag)
add_host_shader(ms_image_blit.frag ms_image_blit_msaa_frag SRC_MSAA=1)
add_host_shader(fault_buffer_process.comp fault_buffer_process_comp)
add_host_shader(fs_tri.vert fs_tri_vert)
add_host_shader(fsr.comp fsr_easu_comp SAMPLE_EASU=1)
add_host_shader(fsr.comp fsr_rcas_comp SAMPLE_RCAS=1)
add_host_shader(post_process.frag post_process_frag)
add_host_shader(camera_motion.comp camera_motion_comp)
add_host_shader(upscale_merge.comp upscale_merge_comp)
add_host_shader(upscale_reactive.comp upscale_reactive_comp)
add_host_shader(taa.comp taa_comp)
add_host_shader(taa_sharpen.comp taa_sharpen_comp)
add_host_shader(taa_sharpen.comp taa_sharpen_ldr_comp LDR_OUTPUT=1)
add_host_shader(buffer_multi_copy.comp buffer_multi_copy_comp)
add_host_shader(depth_resample.frag depth_resample_frag)
add_host_shader(depth_resample.frag depth_stencil_resample_frag HAS_STENCIL=1)
add_host_shader(depth_resample.frag depth_stencil_bits_frag STENCIL_BITS=1)
add_host_shader(camera_motion.comp camera_motion_debug_comp DEBUG_OVERLAY=1)
foreach(BPP IN ITEMS 8 16 32 64 96 128)
    add_host_shader(tiling.comp tiling_micro_${BPP}_comp BITS_PER_PIXEL=${BPP} IS_MACRO_TILED=0)
    add_host_shader(tiling.comp tiling_macro_${BPP}_comp BITS_PER_PIXEL=${BPP} IS_MACRO_TILED=1)
endforeach()
add_custom_target(host_shaders DEPENDS ${SHADER_HEADERS})

file(GLOB_RECURSE VIDEO_CORE CONFIGURE_DEPENDS shadps4/video_core/*.cpp)
file(GLOB_RECURSE RECOMPILER CONFIGURE_DEPENDS shadps4/shader_recompiler/*.cpp)
# tlg: the shader cache key: a hash of every source that shapes the generated SPIR-V. The
# shader cache directory carries it, so a changed recompiler starts a fresh cache instead of
# reusing shaders translated by the old code (build.sh configures on every build).
file(GLOB_RECURSE TLG_SHADER_KEY_SOURCES shadps4/shader_recompiler/*.cpp shadps4/shader_recompiler/*.h)
list(APPEND TLG_SHADER_KEY_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/shadps4/video_core/amdgpu/resource.h
    # tlg: the 1D/BC promotion predicates that resource.h and the SPIR-V image emitter read
    # (IsBlock1D): their code changes which texels a shader samples, without changing the profile
    # the cache compares.
    ${CMAKE_CURRENT_SOURCE_DIR}/shadps4/video_core/amdgpu/tlg_block1d.h
    ${CMAKE_CURRENT_SOURCE_DIR}/shadps4/video_core/amdgpu/tlg_bc_tiny.h
    # tlg: the graphics pipeline writes the host tessellation/discard SPIR-V into its serialized
    # pipeline entry and decides when to emit it.
    ${CMAKE_CURRENT_SOURCE_DIR}/shadps4/video_core/renderer_vulkan/vk_graphics_pipeline.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/shadps4/video_core/renderer_vulkan/vk_pipeline_cache.cpp)
list(SORT TLG_SHADER_KEY_SOURCES)
set(TLG_SHADER_KEY_DATA "")
foreach(source ${TLG_SHADER_KEY_SOURCES})
    file(SHA1 ${source} source_hash)
    string(APPEND TLG_SHADER_KEY_DATA ${source_hash})
endforeach()
string(SHA1 TLG_SHADER_KEY "${TLG_SHADER_KEY_DATA}")
string(SUBSTRING ${TLG_SHADER_KEY} 0 12 TLG_SHADER_KEY)
add_compile_definitions(TLG_SHADER_CACHE_KEY="${TLG_SHADER_KEY}")
message(STATUS "Shader cache key: ${TLG_SHADER_KEY}")

list(FILTER VIDEO_CORE EXCLUDE REGEX "renderdoc\\.cpp$")
set(COMMON
    shadps4/common/decoder.cpp shadps4/common/error.cpp
    shadps4/common/io_file.cpp shadps4/common/native_clock.cpp shadps4/common/number_utils.cpp
    shadps4/common/path_util.cpp shadps4/common/rdtsc.cpp shadps4/common/spin_lock.cpp shadps4/common/recursive_lock.cpp
    shadps4/common/string_util.cpp shadps4/common/thread.cpp shadps4/common/signal_context.cpp
    shim/common/logging/log.cpp)
file(GLOB AVPLAYER CONFIGURE_DEPENDS shadps4/core/libraries/avplayer/*.cpp)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET libavformat libavcodec libavutil libswscale libswresample)
file(GLOB SHIM_SOURCES CONFIGURE_DEPENDS shim/*.cpp shim/*/*.cpp)
# tlg: TLG_METAL=ON (macOS): native Metal renderer (metal/) instead of the Vulkan one. The
# renderer classes keep their names (Vulkan::Rasterizer, Presenter, Scheduler, Runtime, ...):
# metal/shadow holds the headers that replace renderer_vulkan's, ahead on the include path, so
# Liverpool, VideoOut, the caches and the shim build unchanged. The texture/buffer caches keep
# their headers; Metal objects travel in their vk:: handle fields (metal/src/mtl_objc.h).
option(TLG_METAL "Native Metal renderer instead of Vulkan (macOS)" OFF)
if (TLG_METAL)
    enable_language(OBJCXX)
    list(FILTER VIDEO_CORE EXCLUDE REGEX "renderer_vulkan/")
    list(FILTER VIDEO_CORE EXCLUDE REGEX "texture_cache/(image|image_view|sampler|tile_manager|blit_helper)\\.cpp$")
    list(FILTER VIDEO_CORE EXCLUDE REGEX "buffer_cache/(buffer|fault_manager|buffer_cache)\\.cpp$")
    list(APPEND VIDEO_CORE shadps4/video_core/renderer_vulkan/liverpool_to_vk.cpp
        shadps4/video_core/renderer_vulkan/vk_staging_buffer_pool.cpp)
    file(GLOB METAL_SOURCES CONFIGURE_DEPENDS metal/src/*.cpp metal/src/*.mm)
    list(APPEND SHIM_SOURCES ${METAL_SOURCES})
endif()
# Windows: a DLL cannot leave the runtime_* symbols for tlg-probe.exe to resolve, so the
# library is static there and linked into the executable.
if (WIN32 OR APPLE)
    set(TLGGPU_KIND STATIC)
else()
    set(TLGGPU_KIND SHARED)
endif()
add_library(tlggpu ${TLGGPU_KIND} ${VIDEO_CORE} ${RECOMPILER} ${COMMON} ${SHIM_SOURCES}
    ../src/trophy_store.cpp
    shadps4/core/libraries/gnmdriver/gnmdriver.cpp
    shadps4/core/libraries/videoout/driver.cpp shadps4/core/libraries/videoout/video_out.cpp
    shadps4/core/libraries/kernel/equeue.cpp ${AVPLAYER}
    shadps4/core/libraries/videodec/video_utils.cpp)
# Identify diagnostic captures without exposing a build directory.
include(cmake/PerfBuildRevision.cmake)
tlg_perf_build_revision("${CMAKE_CURRENT_SOURCE_DIR}" TLG_TRACE_REV)
target_compile_definitions(tlggpu PRIVATE TLG_PERF_BUILD_ID="${TLG_TRACE_REV}")
add_dependencies(tlggpu host_shaders)
# In-game settings menu: Dear ImGui (third_party/imgui, MIT) with its Vulkan backend, and an
# embedded Cyrillic font (third_party/fonts).
target_sources(tlggpu PRIVATE third_party/imgui/imgui.cpp third_party/imgui/imgui_draw.cpp
    third_party/imgui/imgui_tables.cpp third_party/imgui/imgui_widgets.cpp
    $<IF:$<BOOL:${TLG_METAL}>,third_party/imgui/backends/imgui_impl_metal.mm,third_party/imgui/backends/imgui_impl_vulkan.cpp>)
target_include_directories(tlggpu PRIVATE third_party/imgui third_party/imgui/backends)
if (TLG_METAL)
    target_include_directories(tlggpu BEFORE PRIVATE metal/shadow metal/src)
    target_compile_definitions(tlggpu PUBLIC TLG_METAL=1)
    set_source_files_properties(${METAL_SOURCES} third_party/imgui/backends/imgui_impl_metal.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc;-UVK_USE_PLATFORM_METAL_EXT;-fexceptions")
    find_path(SPIRV_CROSS_INCLUDE spirv_cross/spirv_msl.hpp REQUIRED)
    target_include_directories(tlggpu PRIVATE ${SPIRV_CROSS_INCLUDE})
    foreach(lib spirv-cross-msl spirv-cross-glsl spirv-cross-core)
        find_library(TLG_${lib} NAMES ${lib} REQUIRED)
        target_link_libraries(tlggpu PUBLIC ${TLG_${lib}})
    endforeach()
endif()
target_include_directories(tlggpu PRIVATE compat)
set_property(SOURCE shim/tlg_power_art.cpp APPEND PROPERTY
    COMPILE_DEFINITIONS "TLG_POWER_WHEEL_PATH=\"${CMAKE_CURRENT_SOURCE_DIR}/shim/assets/power-wheel.png\"")
target_compile_definitions(tlggpu PRIVATE IMGUI_IMPL_VULKAN_NO_PROTOTYPES
    TLG_FONT_PATH="${CMAKE_CURRENT_SOURCE_DIR}/third_party/fonts/DejaVuSans.ttf")
set_source_files_properties(shim/tlg_overlay.cpp PROPERTIES
    OBJECT_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/fonts/DejaVuSans.ttf)
target_include_directories(tlggpu PRIVATE shim shadps4 ${SHADER_INCLUDE} third_party/gcn/include third_party/half/include)
target_compile_definitions(tlggpu PRIVATE BOOST_ASIO_STANDALONE NDEBUG)
target_compile_options(tlggpu PRIVATE -Wno-deprecated-declarations -Wno-missing-field-initializers)
# Runtime symbols (runtime_memory_*, runtime_process_*) resolve against tlg-probe.
if (NOT WIN32 AND NOT APPLE)
    target_link_options(tlggpu PRIVATE -Wl,--allow-shlib-undefined)
endif()
if (NOT TLG_METAL)
    target_link_libraries(tlggpu PRIVATE ffx-vulkan::portable ffx-vulkan::fsr4-v07-vulkan)
endif()
target_link_libraries(tlggpu PUBLIC Vulkan::Headers fmt::fmt Boost::headers magic_enum::magic_enum
    tsl::robin_map GPUOpen::VulkanMemoryAllocator PkgConfig::XXHASH PkgConfig::SDL3 PkgConfig::FFMPEG miniz::miniz Zydis::Zydis sirit)
# xbyak is header-only: the distribution's copy when there is one (Fedora xbyak-devel), else the
# submodule (MSYS2 and Ubuntu do not package it).
find_path(XBYAK_SYSTEM_INCLUDE xbyak/xbyak.h)
if (NOT XBYAK_SYSTEM_INCLUDE)
    target_include_directories(tlggpu PRIVATE third_party/xbyak)
endif()
if (WIN32)
    # Guest code is entered with the System V ABI; NOMINMAX/WIN32_LEAN_AND_MEAN keep
    # <windows.h> out of the way of std::min/max and the Vulkan/SDL headers.
    target_compile_definitions(tlggpu PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN)
    target_compile_options(tlggpu PRIVATE -include ${CMAKE_CURRENT_SOURCE_DIR}/shim/tlg_win_compat.h)
    target_link_libraries(tlggpu PUBLIC Vulkan::Vulkan ws2_32 bcrypt ntdll synchronization winmm pdh)
elseif (APPLE)
    # macOS (Apple Silicon, recompiled guest code): Vulkan through the loader + MoltenVK/KosmicKrisp.
    target_compile_definitions(tlggpu PUBLIC TLG_RECOMP=1 VK_USE_PLATFORM_METAL_EXT _XOPEN_SOURCE=700 _DARWIN_C_SOURCE)
    target_compile_options(tlggpu PRIVATE -include ${CMAKE_CURRENT_SOURCE_DIR}/../../recomp/rt/compat_include/darwin_linux_compat.h)
    target_include_directories(tlggpu BEFORE PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../recomp/rt/compat_include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../recomp/third_party/simde ${CMAKE_CURRENT_SOURCE_DIR}/../../recomp/rt)
    target_link_libraries(tlggpu PUBLIC Vulkan::Vulkan "-framework Metal" "-framework QuartzCore" "-framework Foundation")
else()
    target_link_libraries(tlggpu PUBLIC PkgConfig::X11)
endif()

# tlg (Windows): tlggpu is a static library there, so the loader and the HLE runtime are
# linked here, where CMake knows its dependencies (build.sh builds them with ninja).
if (WIN32)
    enable_language(RC)
    file(GLOB TLG_RUNTIME CONFIGURE_DEPENDS ../src/runtime*.c)
    file(GLOB TLG_ATRAC9 CONFIGURE_DEPENDS ../third_party/LibAtrac9/C/src/*.c)
    add_library(atrac9 STATIC ${TLG_ATRAC9})
    target_compile_options(atrac9 PRIVATE -w)
    set_target_properties(atrac9 PROPERTIES C_STANDARD 99 INTERPROCEDURAL_OPTIMIZATION OFF)
    add_executable(tlg-probe ../src/probe.c ${TLG_RUNTIME} ../src/compat_win.c ../src/cpu_check.c ../src/vulkan_smoke.c
        ../src/isa_rewrite.c ../src/isa_emulate.c
        ../packaging/windows/tlg-probe.rc)
    set_target_properties(tlg-probe PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    if (DEFINED ENV{TLG_BUILD_COMMIT})
        target_compile_definitions(tlg-probe PRIVATE TLG_BUILD_COMMIT="$ENV{TLG_BUILD_COMMIT}")
    endif()
    target_compile_options(tlg-probe PRIVATE $<$<COMPILE_LANGUAGE:C>:-Wall -Wextra -Werror>)
    target_include_directories(tlg-probe PRIVATE .. ../src)
    # tlg: libSceFont (runtime_gr2_font.c) renders glyphs with FreeType.
    pkg_check_modules(FREETYPE REQUIRED IMPORTED_TARGET freetype2)
    target_link_libraries(tlg-probe PRIVATE tlggpu atrac9 PkgConfig::FREETYPE onecore bcrypt ws2_32 -pthread)
    # The PS4 range (64 GiB - 1 TiB) must stay free: no high-entropy ASLR for heaps and stacks.
    # The guest main thread runs on the process stack: 16 MiB, committed (no stack probes).
    target_link_options(tlg-probe PRIVATE -Wl,--disable-high-entropy-va "SHELL:-Xlinker --stack -Xlinker 16777216,16777216")
    # tlg: runtime unit tests (ninja -C out/gpu mp3-test videodec-test services-test).
    add_executable(mp3-test EXCLUDE_FROM_ALL ../tests/test_mp3.c ../src/runtime_mp3.c ../src/compat_win.c)
    add_executable(videodec-test EXCLUDE_FROM_ALL ../tests/test_videodec.c ../src/compat_win.c)
    add_executable(services-test EXCLUDE_FROM_ALL ../tests/test_services.c ../src/compat_win.c)
    foreach(test mp3-test videodec-test services-test)
        set_target_properties(${test} PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
        target_compile_options(${test} PRIVATE -Wall -Wextra -Werror)
        target_include_directories(${test} PRIVATE .. ../src)
        target_link_libraries(${test} PRIVATE atrac9 PkgConfig::FFMPEG bcrypt -pthread)
    endforeach()
    add_executable(pad-map-test EXCLUDE_FROM_ALL ../tests/test_pad_map.c ../src/compat_win.c)
    set_target_properties(pad-map-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(pad-map-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(pad-map-test PRIVATE .. ../src)
    target_link_libraries(pad-map-test PRIVATE PkgConfig::SDL3 bcrypt -pthread)
    add_executable(mouse-shake-test EXCLUDE_FROM_ALL ../tests/test_mouse_shake.c)
    set_target_properties(mouse-shake-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(mouse-shake-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(mouse-shake-test PRIVATE .. ../src)
    add_executable(audio-downmix-test EXCLUDE_FROM_ALL ../tests/test_audio_downmix.c ../src/compat_win.c)
    set_target_properties(audio-downmix-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(audio-downmix-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(audio-downmix-test PRIVATE .. ../src)
    target_link_libraries(audio-downmix-test PRIVATE PkgConfig::SDL3 bcrypt -pthread)
    add_executable(cpu-check-test EXCLUDE_FROM_ALL ../tests/test_cpu_check.c)
    set_target_properties(cpu-check-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(cpu-check-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(cpu-check-test PRIVATE .. ../src)
    # isa_emulate runs inside guest code: no XMM/YMM. The test runs the real instructions as its oracle.
    add_executable(isa-emulate-test EXCLUDE_FROM_ALL ../tests/test_isa_emulate.c ../src/isa_emulate.c)
    set_source_files_properties(../src/isa_emulate.c PROPERTIES COMPILE_OPTIONS "-mgeneral-regs-only")
    set_source_files_properties(../tests/test_isa_emulate.c PROPERTIES COMPILE_OPTIONS "-mbmi;-mlzcnt;-mmovbe")
    set_target_properties(isa-emulate-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(isa-emulate-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(isa-emulate-test PRIVATE .. ../src)
    # Stubs and patched sites run for real in an RWX region; the fixture path is the first argument.
    add_executable(isa-stub-test EXCLUDE_FROM_ALL ../tests/test_isa_stub.c ../src/isa_rewrite.c ../src/isa_emulate.c)
    set_source_files_properties(../tests/test_isa_stub.c PROPERTIES COMPILE_OPTIONS "-mbmi;-mlzcnt")
    set_target_properties(isa-stub-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(isa-stub-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(isa-stub-test PRIVATE .. ../src)
    target_link_libraries(isa-stub-test PRIVATE bcrypt -pthread)
    # SSE4A sites against the real EXTRQ/INSERTQ (AMD hosts) or recorded AMD results.
    add_executable(isa-sse4a-test EXCLUDE_FROM_ALL ../tests/test_isa_sse4a.c ../src/isa_rewrite.c ../src/isa_emulate.c)
    set_source_files_properties(../tests/test_isa_sse4a.c PROPERTIES COMPILE_OPTIONS "-msse4a")
    set_target_properties(isa-sse4a-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(isa-sse4a-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(isa-sse4a-test PRIVATE .. ../src)
    # F16C sites against the real VCVTPH2PS/VCVTPS2PH (hosts with F16C) or recorded results.
    add_executable(isa-f16c-test EXCLUDE_FROM_ALL ../tests/test_isa_f16c.c ../src/isa_rewrite.c ../src/isa_emulate.c)
    set_source_files_properties(../tests/test_isa_f16c.c PROPERTIES COMPILE_OPTIONS "-mavx;-mf16c")
    set_target_properties(isa-f16c-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(isa-f16c-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(isa-f16c-test PRIVATE .. ../src)
    # tlg: the runtime memory table's reader-preferring lock (winpthreads' rwlock deadlocks nested readers).
    add_executable(rwlock-rp-test EXCLUDE_FROM_ALL ../tests/test_rwlock_rp.c)
    set_target_properties(rwlock-rp-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(rwlock-rp-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(rwlock-rp-test PRIVATE ../src)
    target_link_libraries(rwlock-rp-test PRIVATE -pthread)
    add_executable(tsc-clock-test EXCLUDE_FROM_ALL ../tests/test_tsc_clock.c ../src/compat_win.c)
    set_target_properties(tsc-clock-test PROPERTIES C_STANDARD 11 C_EXTENSIONS OFF)
    target_compile_options(tsc-clock-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
    target_include_directories(tsc-clock-test PRIVATE .. ../src)
    target_link_libraries(tsc-clock-test PRIVATE bcrypt -pthread)
    add_executable(tlg-gpu-capabilities ../tools/gpu_capabilities.c ../packaging/windows/tlg-gpu-capabilities.rc)
    target_include_directories(tlg-gpu-capabilities PRIVATE shadps4)
    target_link_libraries(tlg-gpu-capabilities PRIVATE Vulkan::Vulkan)
    # "Play The Last Guardian.exe": the game with the launcher's saved settings, no launcher window.
    add_executable(tlg-play WIN32 ../packaging/windows/play.c ../packaging/windows/play.rc)
    target_compile_options(tlg-play PRIVATE -municode)
    target_link_options(tlg-play PRIVATE -municode)
endif()
