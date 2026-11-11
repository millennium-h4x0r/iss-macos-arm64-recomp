# inFAMOUS Second Son on Apple Silicon

A native Apple Silicon build of the [iss_pc](https://github.com/HayatoG/iss_pc) port. The game's
x86-64 PS4 code is **statically recompiled** to ARM64 ahead of time (no Rosetta, no CPU
emulator); the PS4 system runtime is the port's (`port/src`); graphics go through a **native
Metal renderer** built on shadPS4's video core (`port/gpu/metal`).

> **No game code or assets are in this repository.** The recompiler runs on your machine,
> against your own dump, and writes the generated sources to `recomp/work/` (git-ignored).

## Status

- **Playable from start to the Seattle open world** on an M1 Max (64 GB, macOS 27): the opening,
  the cannery, the fire road, the walk to Seattle and free roam in Seattle, with lighting, fire,
  smoke and particle effects rendering.
- **About 30 FPS in most scenes at 1080p**, more in lighter ones. Heavy scenes are GPU-bound.
- Recompiles the whole linked image: ~46,000 functions, ~2.5 M instructions, ~910 switch tables.
- Only tested on one machine. Other Apple Silicon Macs should work but have not been tried.

Known issues:

- **Shader pop-in after an update.** The first launch of a new build compiles shaders: for a few
  minutes, effects can appear a moment late (Metal's shader cache is per binary).
- **A rare gray frame.** On the walk to Seattle, about one frame in several hundred can come out
  gray. See [How the renderer works](#how-the-renderer-works) for the cause.
- **Speed depends on what else uses the GPU.** Several high-resolution or scaled external displays
  keep WindowServer busy and cost frames; fullscreen helps.

## Requirements

- An Apple Silicon Mac. macOS 14 is the minimum the app declares; tested on macOS 27.
- Xcode Command Line Tools (`clang`, `swiftc`): `xcode-select --install`.
- [Homebrew](https://brew.sh) packages:
  ```
  brew install cmake ninja pkgconf sdl3 ffmpeg freetype fmt boost robin-map xxhash zydis \
               vulkan-headers vulkan-loader spirv-cross glslang python@3.13
  ```
- Python 3 with [Capstone](https://www.capstone-engine.org) for the recompiler (a venv below).
- **Your own copy of the game**, dumped from your own PS4: inFAMOUS Second Son with the 1.07
  update merged into one folder (the one with `eboot.bin`). Tested with CUSA00004 1.07; the
  upstream port targets CUSA00223 (US) 1.07. See the main [README](../README.md#required-game-files).
- About 1 GB of disk for the generated sources and the build, plus shader caches over time.

## Build

```sh
git clone --recursive <this repository> iss_pc && cd iss_pc/recomp
GAME="/path/to/your/dump"        # the folder with eboot.bin

# Third-party headers the build expects (not committed)
git clone --depth 1 https://github.com/simd-everywhere/simde third_party/simde
mkdir -p third_party/vma/include
curl -L -o third_party/vma/include/vk_mem_alloc.h \
  https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/master/include/vk_mem_alloc.h

# 1. Prepare the guest image from your dump (the port's scripts)
mkdir -p work/out
python3 ../port/scripts/prepare.py      "$GAME" --out work/out
python3 ../port/scripts/link_libc.py    "$GAME" --out work/out
python3 ../port/scripts/link_modules.py "$GAME" --out work/out
python3 ../port/scripts/content_profile.py "$GAME" --out work/out --sku full

# 2. Recompile the game's code to C (once; again after changing the lifter)
python3 -m venv work/venv && work/venv/bin/pip install capstone
work/venv/bin/python -I lifter/lift.py work/out/boot-linked.bin "$GAME" work/gen

# 3. Build with the Metal renderer
TLG_METAL=1 ./build.sh

# 4. Install as an app ("/Applications/inFAMOUS Second Son.app")
ISS_GAME_DIR="$GAME" ./install-app.sh
```

Then start **inFAMOUS Second Son** from Finder, Launchpad or Spotlight. After a rebuild, run
`./install-app.sh` again (the app keeps its own copy of the binary; it refuses while the game is
running).

To run from a terminal instead: `ISS_METAL=1 ISS_GAME_DIR="$GAME" ./run.sh`. If the dump lives
next to the repository as `CUSA00004[Infamous Second Son]/extracted/uroot`, `ISS_GAME_DIR` is not
needed.

`./build.sh runtime` relinks without recompiling the generated code. `./build.sh` without
`TLG_METAL=1` builds the older Vulkan renderer (see [Vulkan renderer](#vulkan-renderer-older)).

## Playing

- **Port menu:** F12, the key left of 1 (Macs have no Insert key), or R3+L2 on a controller.
  Settings are saved to `work/tlg.ini`.
- **Saves** are in `work/user/savedata/`, the log in `work/game.log`.
- **Native render resolution:** `iss_native_output=1` and `iss_native_percent=<25..100>` in
  `work/tlg.ini` (or the menu's Native rendering tab) render the 3D scene below 1920x1080 with the
  HUD at full size.
- The game runs as an app bundle on purpose: macOS treats an unbundled binary as a background
  process, evicts its GPU memory and pages it back in under the kernel GPU lock (a desktop-wide
  freeze), and gives it no Game Mode.
- A small guard (`tests/wsguard.swift`, started by `run.sh`) pauses the game while WindowServer
  stops answering, so a long GPU stall can never reach WindowServer's watchdog, which would restart
  the desktop. `ISS_WSGUARD=0` turns it off.

Switches for terminal runs (`./run.sh`):

| Variable | Effect |
|---|---|
| `ISS_GAME_DIR=<dir>` | the game folder (with `eboot.bin`) |
| `ISS_METAL=1` | use the Metal build (`work/iss-recomp-metal`); the app always does |
| `ISS_DIRECT=1` | run the binary directly (debuggers, `sample`) |
| `TLG_METAL_CF_GDS_FLAG_DEFER=0` | faster in heavy scenes, but fires and the smoke form can drop out |
| `TLG_METAL_SHADER_WAIT_MS=<ms>` | how long a frame may wait for new shaders per second (default 100) |
| `TLG_METAL_HITCH_MS=<ms>` | log frames slower than that, with what they waited for |

## How it works

### Static recompilation

- Every guest function becomes `void F_<offset>(Ctx *c)` in `work/gen/`. Guest registers are C
  locals (spilled to `Ctx` around calls); flags are locals the C compiler removes when unused.
  The guest stack is real memory: calls push return addresses exactly as on x86, so stack
  arguments, varargs and the guest's own unwinding keep working.
- Indirect calls and jumps go through `recomp_lookup` (a hash of the guest offset); switch tables
  become C `switch`es on the computed target; register and vtable tail calls use `musttail`.
- Imports are fake guest addresses whose thunks call the port's runtime through `rt/hostcall.S`
  (System V to AAPCS64).
- Guest loads and stores (other than stack-relative ones) are acquire/release (`LDAPR`/`STLR`),
  which gives x86's TSO ordering between threads.
- Guest memory layout below the 1 TiB that the guest's 40-bit pointers allow: PS4 user range
  `0x7000000000-0xe000000000`, image at `0xe000000000`, guest stacks and TLS from
  `0xe100000000`.

### How the renderer works

`port/gpu/metal` replaces shadPS4's Vulkan backend: its command processor and shader recompiler
(GCN to SPIR-V) feed Metal, with SPIRV-Cross translating SPIR-V to MSL.

- **Unified memory:** guest memory is one `MTLBuffer` over the game's own pages, so the GPU writes
  results in place and CPU reads of GPU data need no download.
- **Shaders:** translations and compiled MSL are cached on disk (`work/user/metal-*-cache.bin`).
  New shaders compile in parallel off the command processor, and a frame waits for them within a
  budget instead of skipping draws, so effects do not blink.
- **Encoding:** a separate encoder thread turns the recorded work into Metal command buffers.
  Writes to guest memory are ordered with fences, since Metal does not track that buffer.
- **Labels and timing:** the GPU runs about a frame behind the game, while the game waits on GPU
  labels in memory and recycles a job's memory soon after it sees the job's completion flag.
  Job flags are written when the work is recorded (a job seen late is dropped, which gave gray
  frames); timeline counters, and flags after a GPU particle-count copy, are written when the GPU
  has finished (an early count made fires and the smoke form vanish). Small job inputs are copied
  when recorded, and graphics shaders get a short loop guard, so memory the game has already
  reused cannot hang the GPU. The rare gray frame is what is left of this.

The development log, with measurements and the reasoning behind each choice, is in
[`docs/metal-backend.md`](docs/metal-backend.md).

## Repository layout

| Path | What |
|---|---|
| `lifter/` | the recompiler: image reader, function discovery, switch tables, x86-64 / SSE / AVX / x87 semantics, C emission |
| `rt/` | the runtime the generated code runs on: CPU state, dispatch, host calls, loader (`main.c`), macOS stand-ins for Linux/x86 APIs |
| `../port/gpu/metal/` | the Metal renderer |
| `build.sh`, `run.sh`, `install-app.sh` | build, run, install as an app |
| `tests/play.sh` | plays a route with scripted controller input and reports frame times, frame dumps and logs |
| `tests/semtest/` | lifted instruction semantics checked against real x86 (Rosetta as the oracle) on random states |
| `tests/wsguard.swift` | the WindowServer guard |
| `tools/native_sites.c` | finds the native-resolution patch sites |
| `patches/kosmickrisp.patch` | for the older Vulkan renderer's driver |

`tests/play.sh <route> [seconds] [save]` routes include `opening`, `explore`, `dash` and `roam`. A
save fixture is a copy of a `work/user/savedata` folder kept as `work/saves/<name>`. The script
backs up your own saves to `work/saves/auto-backup-*` before swapping them in, and only one run
can be active at a time.

## Vulkan renderer (older)

`./build.sh` without `TLG_METAL=1` builds shadPS4's Vulkan renderer, which runs on Vulkan-on-Metal
(Mesa KosmicKrisp). It needs a KosmicKrisp build with sparse buffers, such as
[shadexternals/mesa-kosmickrisp](https://github.com/shadexternals/mesa-kosmickrisp) cloned next to
this repository, with `patches/kosmickrisp.patch` applied (residency, buffer recycling and a GPU
watchdog for macOS). It is slower than the Metal renderer and kept for comparison;
`./install-app.sh --vulkan` installs it as a separate app.

## Credits and legal

- [HayatoG/iss_pc](https://github.com/HayatoG/iss_pc): the PC port this builds on (PS4 runtime,
  scripts, game fixes).
- [shadPS4](https://github.com/shadps4-emu/shadPS4): the video core and shader recompiler
  (GPL-2.0-or-later); the Metal renderer extends them under the same license.
- [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross), [SIMDe](https://github.com/simd-everywhere/simde),
  [Vulkan Memory Allocator](https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator),
  [Capstone](https://www.capstone-engine.org), [SDL](https://libsdl.org), [FFmpeg](https://ffmpeg.org),
  [LibAtrac9](https://github.com/Thealexbarney/LibAtrac9), and Mesa KosmicKrisp for the Vulkan
  renderer.

No game code, assets or keys are included; play only with a copy you own, dumped from your own
console. inFAMOUS Second Son is a trademark of Sony Interactive Entertainment. This project is not
affiliated with Sony Interactive Entertainment or Sucker Punch Productions.
