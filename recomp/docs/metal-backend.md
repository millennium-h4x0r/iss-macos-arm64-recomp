# Native Metal backend: feasibility and plan (2026-11-02)

## Why

The game runs at ~24-25 FPS in the cannery through shadPS4's Vulkan renderer on KosmicKrisp
(Vulkan -> Metal 4). Per frame (~40 ms): ~28 ms of GPU encoder time in ~180 render passes and
~320 barriers, ~8 ms of bubbles between encoders, and 60 Hz vblank rounding. KosmicKrisp ends
every encoder with a full GPU barrier, records Vulkan commands and re-encodes them at submit, and
compiles shaders SPIR-V -> NIR -> MSL.

A native backend could:
- order work with Metal's own dependency tracking (or per-resource fences) instead of a full
  barrier after every pass: the ~8 ms of bubbles, and overlap of independent passes;
- treat guest memory as one `MTLBuffer` (`newBufferWithBytesNoCopy`, `gpuAddress`): no sparse
  arenas, residency churn or readbacks;
- choose load/store actions and memoryless targets with frame-level knowledge;
- use hardware tessellation instead of compute emulation, and framebuffer fetch for the
  attachment feedback loops that now end passes.

Expected gain: removing the bubbles and some pass overhead is ~1.3-1.5x on GPU time, which
would hold 30 FPS at the 60 Hz vblank (more with a frame rate patch and 120 Hz vblank). A 2-3x
gain would also need the shaders themselves to run faster, which is not yet known.

## Stage 1: shader translation (done)

The port's SPIR-V shaders from the pipeline cache (`work/user/cache/CUSA00004-*/*.spv`, 1182
shaders) translated with SPIRV-Cross 1.4.363 (`--msl --msl-version 30100 --msl-argument-buffers`)
and compiled with the runtime Metal compiler (`MTLDevice newLibraryWithSource`, Metal 3.1):
**1181/1182 compile**, ~46 ms each. The failure aliases 64-bit and 32-bit workgroup memory
(`SPV_KHR_workgroup_memory_explicit_layout`); the recompiler's profile can turn that off.

## Size

No renderer interface exists: `Vulkan::Rasterizer`/`Presenter` are used directly by Liverpool,
the page manager, the video out driver and the shim; the texture and buffer caches hold Vulkan
objects (`vk::Format` is part of `ImageInfo`). The plan is a `renderer_metal/` with the same
class names, chosen by CMake, with the PC-port extras (upscalers, DLSS/FSR, scene resolution,
motion vectors, frame record, profiler, pipeline serialization) stubbed.
Estimate: 13-17k new lines (rasterizer 3.5-4.5k, pipelines 2-2.5k, scheduler/runtime 2-2.5k,
device/presenter 1.5k, formats 1.2k, cache backends 2-2.5k, SPIRV-Cross glue 1k, host shaders
0.8k), plus 1-2k lines of stubs and type edits.

## Milestones

1. Build switch (`TLG_METAL=1`), stubs, Metal device, presenter clears the window, overlay.
2. Formats, images/views/samplers, buffers over guest memory, copies (Runtime), detiling.
3. Pipelines: SPIRV-Cross at pipeline creation (argument buffers for set 0, push constants via
   `setBytes`, vertex descriptors), pipeline cache.
4. Rasterizer: render passes, dynamic state, draws, dispatches: first game frames (intro).
5. Gameplay correctness against the Vulkan path (frame dumps), then performance work.

## Stage 2: shader code experiment (2026-11-02)

KosmicKrisp's MSL for the game's shaders (`KK_MSL_DUMP`) has every float add/mul in
`#pragma METAL fp math_mode(safe)`, an opaque `!&buf0.contents[0] ? 1 :` guard on every multiply
(NaN preservation) and `coherent` on every buffer access. The first two come from the port's
SPIR-V (every float op `NoContraction`, `SignedZeroInfNanPreserve`); SPIRV-Cross would emit a
`[[clang::optnone]]` fma helper call per such op instead, which is no better. Cannery, explore
route, FPS after 45 s:

| Config | FPS |
|---|---|
| baseline | 23.6, 25.1 |
| KK workarounds 6,14,17 off | 30.0, 28.3 |
| + `TLG_FAST_FP=1` (no NoContraction / inf-nan preserve) | 31.6 (p90 33.3 ms) |

So shader code is a large lever, and it is available in the Vulkan path (now the default in
`run.sh`). The game has no frame cap: it calls `sceVideoOutSetFlipRate(0)` (every vblank;
`TLG_FLIP_RATE` overrides and logs it), and frame intervals at a 120 Hz vblank were 25 ms
(24%), 33 ms (59%) and 42 ms (12%); at 60 Hz, 24% of frames took 16.7 ms. It runs as fast as
CPU and GPU allow, so a faster renderer does raise the frame rate.

## Shader float math (2026-11-02)

Delsin's vest and coat need unfused float math: with fused multiply-adds they render as
white/black blotches. The recompiler can mark every float op NoContraction, but SPIRV-Cross
turns each such op into a call to an `[[clang::optnone]]` helper (`spvFMul`, `spvFAdd`), which
made gameplay about 5x more GPU-expensive (~4.5 FPS). The Metal renderer instead emits no
per-op decorations (`profile.fast_fp = true`) and compiles every shader as MSL 3.2 with
`#pragma METAL fp contract(off)` in Metal's safe math mode: correct vest, ~20 FPS in the
cannery (Vulkan build: ~25).

Switches: `TLG_METAL_FP=decorated` (old per-op path), `TLG_METAL_MATH=relaxed|fast`,
`TLG_METAL_CONTRACT=1` (allow fusion), `TLG_METAL_UNALIGNED_VB=0` (copy 2-byte aligned vertex
buffers instead of binding them directly), `TLG_METAL_LABEL=1` (one labeled encoder per compute
job and per-pass draw/vertex counts, for Metal System Trace), `TLG_DRAW_STATS=1` (direct draws
and vertices per 5 s, both renderers).

## Black squares on faces (2026-11-03, fixed)

The squares were NaN spread by the post-processing blurs. The skin vertex shader (`3f30e238`)
read past the end of guest buffers: GCN returns 0 for loads past a buffer's `num_records` (and
Vulkan gets the same from robust buffer access), Metal reads whatever guest memory follows.
Huge interpolants made the G-buffer pixel shader (`62354dfb`) write Inf to render target 4,
the tiled lighting (`ce1675e0`) turned it into NaN, and the bloom/DOF chain grew it into
30-40 px squares. Fix: `Profile::buffer_bounds_check` (Metal): guest buffer loads past the
bound range return 0 and stores are dropped (`OpArrayLength` against SPIRV-Cross's buffer size
table; `OpArrayLength` was added to sirit). Also on the Metal profile, for GCN semantics:
`nan_min_max` (NMin/NMax/NClamp; SPIRV-Cross's `fast::min/max` may return the NaN) and
`pkrtz_saturate` (`v_cvt_pkrtz_f16_f32` saturates finite overflow to +-65504).
Switches: `TLG_METAL_BOUNDS=0`, `TLG_METAL_NAN_MINMAX=0`, `TLG_METAL_PKRTZ=0`.

Debug tools: `TLG_METAL_NAN_SCAN=1` counts NaN/Inf texels in every pass's float targets and
every dispatch's textures on the frames after a frame dump (`=2`: one pass per draw, names the
draw); `TLG_METAL_MSL_OVERRIDE=<dir>` loads hand-edited MSL named like the `TLG_METAL_DUMP`
files; `TLG_METAL_LOG_PS=<hash>` logs the images a shader binds; `TLG_METAL_DUMP_ALL_TEX=1`
adds every fragment texture to `TLG_METAL_DUMP_TARGETS` dumps; `TLG_LOG_IMAGE_ADDR=<hex>` logs
an image's uploads (texture_cache.cpp). `tests/play.sh`: `DUMP_EVERY=<s>`, `FULL_FRAMES=1`.

## Loading screen emblem (2026-11-03, fixed)

The crows emblem rendered as vertical bars: the shader permutation key did not include the
BC-1D-as-2D promotion (which samples the middle row), so a 2D texture reused a permutation
compiled for a promoted 1D one. `ImageSpecialization::is_block1d` fixes it in both renderers
(Vulkan `ShaderMetaVersion` 10).

## Frame rate (2026-11-03)

Cannery route (`tests/play.sh explore`, 150 s, mean FPS 40-130 s): Metal 25.4 -> 30.0 (locked,
p95 33.3 ms), Vulkan 28.2. The game paces itself: its main thread spins (guest 0x1f2700) until
the previous frame's end-of-pipe label is written, so frame time is the latency through the
command processor thread and the GPU. Found with `xctrace` Time Profiler (CPU) and Metal System
Trace (GPU busy only ~24%):

- `StageBindings` held 1056 strong ObjC references per draw (6 stages x buffers, textures,
  samplers): ARC set/release was ~30% of the command processor thread. Now `__unsafe_unretained`
  (the caches own the objects; encoders retain what they bind) and not zeroed: 25.4 -> 28.3.
- `PipelineCache::GetProgram` rebuilt the `StageSpecialization` of every stage of every draw;
  it now reuses the last permutation when the user data, flattened user data, runtime info,
  binding start and vertex attribute sharps repeat (`TLG_METAL_NO_FAST_PROGRAM=1` turns it off).
- GCN's shader barrier (EVENT_WRITE_EOS + WAIT_REG_MEM on its label, ~10 per frame) drained the
  whole GPU each time (`Scheduler::Finish`, ~40% of the command processor thread blocked).
  `RunInOrder` now reports the label writes it defers to command buffer completion, so they are
  pending fences (`DrawPipeHead/Reached` = command buffer ticks) and the wait passes: the Metal
  queue runs the later work in order anyway. EOS no longer waits for earlier deferred labels
  (completion handlers run in order). 28.5 -> 30.0 locked. `TLG_METAL_SYNC_STATS=1` counts the
  remaining GPU waits; `TLG_LOG_WAITS=<n>` logs them and the EOS/EOP label writes.

The 30 FPS ceiling is the 60 Hz vblank (`TLG_VBLANK_HZ=60`; the engine steps time per vblank).

Caution: one run with `vsync=0` and `TLG_VBLANK_HZ=120` exited after ~10 s and left an
unattributed ("n/a") compute job holding the GPU at 100% after the process was gone (as on
2026-11-02). Do not repeat that configuration unguarded.

## Shader compile time (2026-11-03)

About 650 shaders compile while the cannery loads (the 10-20 s FPS bucket fell to ~22). The
"shaders compiled" line (every 5 s) splits the time: recompile + SPIR-V ~0.7 ms, SPIRV-Cross
~2.4 ms, Metal's MSL compile ~0.05 ms (the system's shader cache is warm after the first run),
render pipelines ~0.1 ms. SPIRV-Cross output now goes to `work/user/metal-msl-cache.bin`
(append-only, keyed by a hash of the SPIR-V, so recompiler changes miss automatically; bump
`kMslCacheVersion` when `TranslateStage`'s options or SPIRV-Cross change;
`TLG_METAL_NO_MSL_CACHE=1` turns it off). Second run: load-time compile 2094 -> 485 ms, 10-20 s
bucket 22.9 -> 27.8 FPS; ~16 MB for the cannery.

## GPU hang in the opening (2026-11-03, fixed)

Compute shader 0xfcda0194 (runs when the opening starts a new save, ~143 s into
`tests/play.sh opening`) does a binary search whose indices the recompiler moved through
float-typed selects (V_CNDMASK_B32 / V_MOV_B32 read their operands as F32). Small integers as
floats are denormals; Metal flushed them in the select, `lo` stayed 0 and the loop never ended.
A stuck shader on Metal keeps the GPU at 100% after the process is gone (only a reboot clears
it; this was also the "n/a" GPU job of 2026-11-02/03). Fixes (Metal profile only):
- `Profile::integer_moves`: V_MOV_B32 / V_CNDMASK_B32 without input or output modifiers move
  U32 (GCN moves bits).
- `Profile::loop_guard` (1<<20, `TLG_METAL_LOOP_GUARD=<n>`, 0 = off): every loop back-edge
  counts into a Private counter and the loop exits past the cap, so a future loop bug cannot
  hang the GPU.
- Diagnosis without running a suspect: `TLG_METAL_SKIP_SHADERS=<hex>[,...]` refuses those
  shaders (their draws and dispatches are skipped); with `TLG_METAL_DUMP=<dir>` the MSL is still
  written first.

## macOS 27 address space (2026-11-03)

From macOS 27, libmalloc reserves a randomized ~12 GiB block inside the PS4 user range
[0x7000000000, 0xe000000000) during libSystem initialization, before any constructor runs
("cannot reserve PS4 user range"). `rt/guest_reserve.S` links a zero-fill placeholder segment
`__TLGUSER` at 0x7000000000 (build.sh `-segaddr`), which the kernel maps with the executable;
`reserve_guest_ranges()` unmaps it first and reserves as before. The executable slides with
ASLR (tens of MiB), so the segment can start a little above USER_MIN (that gap is reserved
normally) and end a little into the guest image; a second tiny segment `__TLGEND` at
0xfe00000000 keeps `__LINKEDIT` (always after the highest segment) off the guest image. Both
builds.

## Shader prewarm (2026-11-03)

Metal compiles MSL on the command processor thread, one shader at a time. With a cold system
cache (after a macOS update; always for the unbundled `ISS_RAW_BINARY=1` binary on macOS 27,
whose cache does not persist) that is ~60 ms per shader, 33 s while the cannery loads. At
startup, worker threads (performance cores - 2; `TLG_METAL_PREWARM=<n>`, 0 = off) compile every
MSL source of `metal-msl-cache.bin`, newest first; `CompileMsl` takes the finished library or
waits for one in progress. Cold cache: 1852 shaders in 14.9 s before the level loads,
load-time compile 33 s -> 0.01 s, 10-20 s bucket 6-13 -> 28.6 FPS. Opening route with the
fixed shader: 30 FPS for 260 s, GPU idle afterwards.

## Known issues

- Intro video, Metal build (2026-11-03, reported by the player: stutters, frames out of
  order). Investigated, see "Intro video pacing" below; no out-of-order frame reproduced.

## Intro video pacing (2026-11-03)

Tools: `tests/play.sh intro` (Continue at the title, then no input), `DUMP_COUNT=<n>` bursts of
consecutive frames, `TLG_METAL_CONTENT_STATS=1` (8 rows of each flipped frame read back and
hashed: new pictures and runs of repeats every 5 s, no disk writes), `TLG_METAL_PRESENT_STATS=1`
(GPU-ready and drawable waits), `TLG_LOG_UPLOAD_RACE=1` (CPU-written images changed between
recording their upload and the GPU copying them).
- Windowed and covered by other windows, macOS composites the layer at 30 Hz: `nextDrawable`
  waited ~33 ms and everything ran at exactly 30 FPS. Fullscreen: 60 FPS. Benchmark Metal in
  fullscreen (`work/tlg-metal-fs.ini`).
- Fullscreen: the text crawl shows 60 new pictures per second, perfectly even; the cinematic
  (~100-140 s) 30 per second with 0-8 per 5 s held 3 flips (the next 1). No repeated, skipped
  or out-of-order picture in 400 burst frames; upload races 1 in 1780 (not the video).
- The emulated vblank was a free-running 60 Hz timer drifting against the display. It now
  ticks `TLG_VSYNC_LEAD_US` (6000) before a real refresh (CVDisplayLink on the main display,
  `port/gpu/shim/tlg_vsync.h`, Metal only; `TLG_VSYNC_LOCK=0` = timer). The remaining 3/1
  holds did not change measurably (game-side sampling of a 30 Hz animation at 60 Hz flips).
- Likely what the player saw: the first runs after the macOS 27 update compiled every shader
  cold on the command processor thread (33 s of stalls; fixed by the shader prewarm).

## CPU writes vs queued GPU work (2026-11-03)

Metal reads guest memory when the GPU runs, and the command processor thread runs ahead of the
GPU, so its own writes (gfx/compute WRITE_DATA and DUMP_CONST_RAM are memcpys at record time)
could reach memory that queued work has yet to read. `TLG_LOG_WRITE_RACE=1` tracks the guest
pages each binding reads per command buffer (bindings over 4 MiB as ranges) and checks every
such write: cannery gameplay, 30-45 writes/s, none to memory queued work reads. Images:
`TLG_LOG_UPLOAD_RACE=1`, 1 of ~1780 uploads (an odd 182 MB "256x256" image), not visible.
Nothing to fix so far; rerun both checks in new areas.

## Async shaders (2026-11-03)

The in-game `async_shaders` setting (off by default, as on Vulkan; `TLG_ASYNC_SHADERS=1`)
now works on Metal: a new graphics permutation's MSL goes to the prewarm workers (they stay
after startup) and its draws are skipped until the library is ready; the program remembers the
pending permutation by its lookup specialization, so a skipped draw costs one lookup. Compute
stays synchronous. With no MSL cache and a cold system cache (first visit): no compile stall
(10-20 s bucket 26.9 FPS instead of a 33 s freeze), frames correct after the shaders land.

## Fullscreen frame rate (2026-11-03)

The "30 FPS locked" numbers above were windowed: a covered window is composited at 30 Hz.
Fullscreen (`work/tlg-metal-fs.ini`), cannery route 40-130 s: Metal 49.7 FPS (median 16.7 ms,
p95 33.3 ms), Vulkan (bundled app, player's fullscreen tlg.ini) 27.5 FPS (median 33.3 ms).

## Mid-frame commits (2026-11-03)

Fullscreen, nothing is saturated (Time Profiler, 20 s of gameplay: game main thread ~25% busy,
of it ~15% spinning on the previous frame's end-of-pipe label; command processor thread ~21%;
GPU ~30% above this machine's idle load): the frame time is the chain game -> recording ->
GPU, and a frame that misses a vblank shows for two. Command buffers were committed only at
labels; now also at a render pass boundary once 400 draws were recorded
(`TLG_METAL_COMMIT_DRAWS`, 0 = off), so the GPU starts while the rest of the frame is
recorded. Cannery route, fullscreen, two rounds each (background GPU load varied between
rounds): off 51.7 / 45.6 FPS, 400 draws 57.8 / 51.7 (p95 33.3 -> 16.7 ms in the first round,
frames over 17 ms 16% -> 4%), 1000 draws 39.7 / 48.3, 150 draws 57.2, 250 draws 55.6.
A small per-program cache of recent lookups did not help (the user data changes on almost
every draw, so the specialization is rebuilt: ~6% of the command processor thread).

## Recording cost (2026-11-03)

Heavy cannery stretches: the command processor thread was ~76% busy (~13.6 ms of recording a
frame) and the GPU ~65% (`TLG_METAL_PASS_STATS=1` prints the union of the command buffers' GPU
time, ~12 ms a frame), so recording sets the pace. Recording cost per frame (Time Profiler at
70-85 s, busy time / FPS): 13.6 -> 10.4 ms.
- Thread-locals: `Info::UserData()`/`FlatUserData()` and the fetch shader's attribute sharps
  checked thread-local snapshots (Vulkan's draw pipe, compiler workers) on every sharp read;
  each thread-local access is a `_tlv_get_addr` call on macOS (12.9% of the thread). A global
  flag set by the first thread that installs one now skips them (4.5% left, mostly the guest
  memory region cache in runtime_memory.c, per thread by design).
- ARC: per-draw Metal objects (render targets, vertex/index/argument buffers, bound textures
  and samplers) are unretained, taken with `Metal::Raw` (retain/release 6% -> 0.7%).
- Draws with no attachments that write no memory (~9 a frame) are not recorded
  (`TLG_METAL_KEEP_NOOP_DRAWS=1` keeps them): each was a render pass and ended the one around it.
- Tried, no gain: a signature of the specialization's inputs instead of building it (the cost
  is reading the sharps from guest memory, the same either way); keeping a pass open for a
  draw that binds fewer of its attachments with a pipeline variant (after the no-op draws are
  gone, ~6 a frame); committing every 150 draws instead of 400.

Why passes end (`TLG_METAL_PASS_STATS=1`, per 5 s, ~130 passes a frame): other colour targets
~16.5k, colour and depth ~5k, a superset of the open pass's attachments ~3k, clears ~3k, the
400-draw commits ~2.3k, a subset ~2k, compute jobs and copies ~2.5k.

## Depth of field blocks in the cutscene after the mural (2026-11-03, fixed)

Player report: black flicker in the video after the spray mural. Rectangular blocks of the
cutscene's depth of field (dark, blurred, over faces) for single frames, 13 of 224 frames in
dense bursts. Cause: the scheduler stopped waiting on its guest-memory fence at every command
buffer boundary ("the queue orders command buffers"); command buffers of one queue start in
order but overlap on the GPU, and guest memory is untracked, so with the mid-frame commits a
pass read tile data a compute job in the previous command buffer was still writing. The fence
wait now carries over (0 of 224; cannery 56.8-58.4 FPS, no cost). With TLG_METAL_COMMIT_DRAWS=0
it had been 0 too; the no-op draw skip was not the cause.

Tests: `tests/play.sh mural` replays the player's recording of the mural
(work/routes/spray-mural.txt, from F9 in the installed app: pad, motion and touches) from the
"hold the controller sideways" prompt (MURAL_AT, 156 s), then the cutscene plays and the
cannery starts (~320 s). DUMP_FROM=<s> limits dumps to the part of interest; scratchpad
holes.py finds frames with black patches their burst neighbours do not have.

## MSL cache size (2026-11-03)

`metal-msl-cache.bin` is append-only; past 4096 records it is rewritten with the newest 3072 at
startup (a dropped shader still in use is translated once more and appended again).

## Coverage (2026-11-03)

Cannery, intro, opening up to the mural (7 minutes): no skipped draws or dispatches, no
tessellation, geometry shader, rect list or MSAA copy. The mural needs its stencil filled:
the pad file now takes `aim=<yaw>,<pitch>` (degrees) and `tests/play.sh opening` sweeps a grid
while spraying; it covers most of the stencil but the scene does not advance (gaps remain and
a second, offset pass paints nothing new), so later areas are not reached by the tests yet.
