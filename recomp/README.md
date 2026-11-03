# iss_pc on Apple Silicon: static recompilation

inFAMOUS Second Son running natively on Apple Silicon Macs (no Rosetta): the game's x86-64 code
(eboot 1.07 + its `libc.prx` and `libSceFios2.prx`) is translated **once** into C and compiled
for ARM64; the PS4 runtime (`port/src`) and the GPU library (`port/gpu`, shadPS4's video core)
are compiled natively; graphics go through Vulkan on Metal (Mesa KosmicKrisp).

No game code is in this repository: the recompiler runs on your machine against your own dump
and writes the generated sources to `recomp/work/` (git-ignored).

## Layout

| Path | What |
|---|---|
| `lifter/image.py` | reads the linked guest image (`port/scripts/link_modules.py` output) and the modules' unwind tables |
| `lifter/lift.py` | function discovery (unwind tables, calls, relocations, address-taken code), switch tables, C emission |
| `lifter/x86emit.py`, `simd.py`, `x87emit.py` | x86-64 / SSE / AVX / F16C / SSE4a / x87 instruction semantics |
| `lifter/audit_tables.py` | lists indirect jumps that look like switch tables but did not resolve |
| `rt/x86.h`, `x87.h`, `pcmpstr.h` | guest CPU state (`Ctx`) and the helpers the generated code calls |
| `rt/dispatch.c` | guest address -> function table, import thunks, guest calls from host code, threads, cpuid/rdtsc/MXCSR |
| `rt/hostcall.S` | System V argument registers -> AAPCS64 call into the PS4 runtime |
| `rt/main.c` | loader: address-space reservation, relocation, imports, GPU start, module init, entry |
| `rt/compat_include/` | Linux/x86 API stand-ins for macOS (timed locks, x86 intrinsics via SIMDe, ...) |
| `third_party/simde`, `third_party/vma` | SIMDe (x86 SIMD on NEON), Vulkan Memory Allocator header |
| `build.sh`, `run.sh` | build everything into `work/iss-recomp`; prepare the image and run |

## How it works

- Every guest function becomes `void F_<offset>(Ctx *c)`. Guest registers are C locals (spilled
  to `Ctx` around calls); flags are locals the C compiler removes when unused. The guest stack is
  real memory: calls push return addresses exactly as on x86, so stack arguments, varargs and the
  guest's own `longjmp`-free unwinding keep working.
- Indirect calls/jumps go through `recomp_lookup` (hash of guest offset -> function). Switch
  tables become C `switch`es on the computed target; register/vtable tail calls use `musttail`.
- Imports are fake guest addresses; their thunks call the port's runtime through `hostcall.S`.
  Host function pointers handed to the guest (exit handler, dlsym) get a slot on first use.
- Guest memory layout on Apple Silicon (below the 1 TiB the guest's 40-bit pointers allow, above
  the commpage/GPU carveout at `[0xfc0000000, 0x7000000000)`): PS4 user range
  `0x7000000000-0xe000000000`, image at `0xe000000000`, guest stacks/TLS from `0xe100000000`.
- GPU page tracking uses 16 KiB pages (the host page size); the shader recompiler's SRT walker is
  a bytecode interpreter instead of x86 JIT code.

## Build and run

```
brew install cmake ninja pkg-config sdl3 ffmpeg freetype fmt boost robin-map xxhash zydis vulkan-loader vulkan-headers llvm meson
python3 -m venv /tmp/venv && /tmp/venv/bin/pip install capstone      # the lifter's disassembler
# KosmicKrisp with sparse buffers (shadPS4's build): see "Vulkan driver" below
/tmp/venv/bin/python -I lifter/lift.py work/out/boot-linked.bin <game dir> work/gen   # once per lifter change
./build.sh
./run.sh            # ISS_GAME_DIR=<dump> to choose the game folder
```

`run.sh` prepares `work/out/boot-linked.bin` with the port's scripts on first use. It runs the
game as an app bundle (`work/inFAMOUS.app`, launched through LaunchServices with `open`): an
unbundled binary is a background process to macOS (RunningBoard `anon<...> running-NotVisible`),
whose GPU memory the system evicted mid-game (17 GB down to 7 GB) and paged back in under the
kernel GPU lock, freezing the whole desktop; the bundle also carries the games category for Game
Mode. Output goes to `work/game.log` and is echoed. `ISS_DIRECT=1` runs the binary directly
(debuggers, `sample`).

`run.sh` also starts `work/wsguard` (`tests/wsguard.swift`), which pings WindowServer every
0.5 s and pauses the game (SIGSTOP) while WindowServer does not answer for 1.5 s, resuming it
afterwards: a stall then cannot reach WindowServer's 40 s watchdog, which restarts the desktop.
It never kills the game: tearing down its GPU memory needs the same kernel lock. `ISS_WSGUARD=0`
turns it off.

Native render resolution: `iss_native_output=1` and `iss_native_percent=<25..100>` in
`work/tlg.ini` (or the port menu's Native rendering tab) render the 3D scene below 1920x1080
with the HUD at full size. The port's patch is for the US 01.07 executable; the EU 01.07 one
matches it byte for byte at every site. The lifter patches the resolution-independent sites
(`lifter/iss_native_sites.json`, written by `tools/native_sites.c`) and reads the six size
immediates from guest memory, where `rt/main.c` writes the chosen values after checking every
site. Scenes above 1080p need the exposure patches and are refused.

### Vulkan driver

The GPU library needs sparse buffers. Homebrew's Mesa KosmicKrisp lacks them; shadPS4's build
(`github.com/shadexternals/mesa-kosmickrisp`, a Mesa fork with sparse buffers and geometry
shaders) has them. Build it next to this repository; `run.sh` prefers it.

Apply `patches/kosmickrisp.patch` to its `externals/mesa` first. After changing it, rebuild
with `ninja` in `build/externals/mesa/build-target` and copy the dylib to `build/outputs/` (the
top-level CMake build does not notice source edits; never copy it over a running game). It:

- commits the device residency set only when allocations changed (upstream committed and
  re-requested residency of all ~14 GB on every `vkQueueSubmit`, holding the kernel GPU lock long
  enough for WindowServer's watchdog to restart the desktop);
- recycles command-buffer upload BOs (pool cap 32 -> 1024) and large scratch BOs (a 1 GB device
  cache) instead of creating and destroying ~500 MTLHeaps a second, each a residency commit;
- adds a GPU watchdog: when a residency commit or queue submit holds the GPU for over 100 ms,
  submissions are spaced 20 ms apart for a while so WindowServer gets the lock
  (`KK_GPU_WATCHDOG=0` disables);
- `KK_RESIDENCY_STATS=1`: every 2 s, residency commits, BO churn, GPU busy time, encoders,
  render passes and their split reasons, barrier stage masks and estimated attachment traffic;
- `KK_LIGHT_BARRIERS=1` (opt-in): replaces the full barrier after every encoder with queue
  barriers where needed. No gain measured: the port records a barrier between nearly every
  pair of passes.
- keys the pipeline cache on `MESA_KK_DISABLE_WORKAROUNDS` (the workarounds change the MSL);
- `KK_MSL_DUMP=<dir>`: writes each generated MSL shader as `<SPIR-V blake3>_<stage>_<n>.metal`
  (Mesa's `MESA_SPIRV_DUMP_PATH` names the SPIR-V the same way);
- `KK_PRIVATE_MEMORY=1` (opt-in): a second, device-local-only memory type backed by private
  Metal heaps; optimal-tiling images go there (lossless compression possible, ~6 GB less
  "in use" GPU memory). No frame time gain measured.

## Performance notes (2026-11-02)

Cannery gameplay (`tests/play.sh explore`, fullscreen): ~24-25 FPS, median frame 33 ms (was
~21-23 FPS, median 50 ms). Opening (spray scene): ~31 FPS. Measured with the Metal System
Trace (`xcrun xctrace`), `/usr/bin/sample` and the counters below.

- **Readbacks (fixed).** The game reads GPU-written memory ~80 times a second. Each read made
  the draw recording thread download it with `Scheduler::Finish`: the whole GPU drained, about
  half of that thread's time, an idle GPU gap every frame (`TLG_READBACK_STATS=1` shows them,
  with the guest regions). `run.sh` now turns on unified memory (`TLG_UNIFIED_MEMORY=1`,
  `TLG_UNIFIED_RANGE=0x7048000000:0xc0000000`): the game's direct memory heaps are imported as
  one Vulkan buffer, the GPU writes the guest's bytes in place and reads need no download.
  The default range in `unified_memory.h` is the PS4 address; the recompiled image maps guest
  memory 0x6000000000 higher. Readbacks: 0 per second.
- **Frame pacing.** The game waits for the previous frame's GPU completion label (spin loop at
  guest 0x1f2700), so the CPU never runs more than a frame ahead; `frames_queued` 0/1/2 makes
  no difference. Frames land on 60 Hz vblanks (33/50 ms) because `TLG_VBLANK_HZ=60`: without
  the frame rate patch (not available locally) the engine steps time per vblank.
- **WindowServer** uses ~20% of the GPU with no game running (6K XDR plus two displays);
  windowed play added ~7%. `display_mode=fullscreen` in `tlg.ini` removes that share.
- **GPU work** is ~28 ms per frame in ~180 render passes, ~320 barriers and one ~4 ms compute
  encoder; ~8 ms more is bubbles between encoders. Most pass ends are real data dependencies
  (a render target sampled by the next draw). `TLG_HOIST_BARRIERS=1` (opt-in) records the
  barriers that order nothing inside the open pass ahead of it and keeps the pass open; only
  ~4% qualify, no frame time change. Private image memory (above) did not change it either.
  `TLG_PASS_STATS=1` prints pass reopen statistics, the callers that end passes, and the
  hoisting refusal reasons.
- **Shader math (fixed).** The recompiler decorates every float add/mul `NoContraction` and
  requests signed zero/inf/nan preservation; KosmicKrisp turns that into Metal's `safe` math
  mode, an opaque guard on every multiply, and `coherent` on every buffer access (workarounds
  6, 14, 17 for macOS 26 compiler bugs that only CTS edge cases hit). `run.sh` now sets
  `TLG_FAST_FP=1` and `MESA_KK_DISABLE_WORKAROUNDS=6,14,17`: cannery ~24 -> ~30 FPS (p90
  33 ms), no visible difference. The game has no frame cap (it sets flip rate 0; at 60 Hz a
  quarter of frames take 16.7 ms): it runs as fast as CPU and GPU allow. `ISS_STRICT_SHADERS=1` restores them.
  SPIRV-Cross would carry the same cost (`[[clang::optnone]]` fma helpers per `NoContraction`
  op), so this is a property of the shaders, not of the Vulkan layer.
- Lowering the scene resolution (native resolution above, 75%) gained ~2%: not pixel bound.
- iTerm2's Metal renderer can take a large share of the GPU while its window is visible.

## Status (2026-11-01)

- **Playable on an M1 Max**: boots to the title screen, plays the intro text and the opening
  (Delsin at the billboard, first graffiti prompt). ~23 FPS there, limited by the GPU library's
  command thread, not by the recompiled game code.
- Recompiles the whole linked image: ~46,000 functions, ~2.5 M instructions, ~910 switch tables.
- `tests/semtest`: 1,019 instruction forms the game uses, run on real x86 (Rosetta, as a test
  oracle only) and as lifted ARM64 C on random states. Remaining differences are undefined
  flags (imul SF/ZF/PF, multi-bit shift OF), the sign of the default NaN, rcp/rsqrt
  approximations, and two Rosetta quirks (cmpxchg flags, 32-bit movsxd).
- `tests/autoplay.sh`: unattended run that taps a button and dumps frames to `work/auto/`.
- `tests/play.sh <opening|explore> [seconds] [save]`: plays with simulated controller input
  (`TLG_PAD_FILE`) under the guards and reports FPS, GPU utilization and memory every 10 s, plus
  frame dumps, in `work/play/<route>/`. `opening` starts without a save (cutscenes, tilt and
  shake the can, spray); `explore` loads `work/saves/cannery-escape` and runs, turns, jumps,
  climbs, fights and interacts. The player's own save is moved aside and put back.
- `tests/spray.sh`: the older opening route with a WindowServer ping log.
- `tests/flicker.sh`: dumps runs of consecutive frames and reports frame-to-frame differences.
- Memory ordering: guest loads/stores other than rsp-relative ones are acquire/release
  (`LDAPR`/`STLR`, x86.h), which gives x86's TSO ordering between threads; accesses straddling a
  16-byte block take a plain access plus barrier. `-DRECOMP_WEAK_MEMORY` restores plain accesses.
- The port's menu opens with F12 or the key left of 1 (Macs have no Insert key), or R3+L2.

Known limits: SSE/x87 memory accesses are plain (ordered only through the GPR accesses around
them); NaNs created by x86 operations have a positive sign; the dependence on
shadPS4's KosmicKrisp build.
