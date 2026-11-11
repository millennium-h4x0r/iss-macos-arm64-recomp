<p align="center"><img src="port/packaging/icon/infamous-icon-1024.png" width="160" alt=""></p>

<h1 align="center">inFAMOUS Second Son — native PC port</h1>

<p align="center"><a href="https://buymeacoffee.com/hayatog"><img src="https://img.shields.io/badge/Buy_me_a_coffee-Support_the_project-FFDD00?logo=buymeacoffee&amp;logoColor=000000" alt="Buy me a coffee"></a></p>

<p align="center">
  <a href="https://github.com/HayatoG/iss_pc/releases/latest">Download</a> ·
  <a href="https://www.youtube.com/@hayatog-dev">YouTube</a> ·
  <a href="https://discord.gg/UMkdMYZh9g">Discord</a>
</p>

<p align="center"><a href="https://github.com/sponsors/HayatoG"><img src="https://img.shields.io/badge/Sponsor-HayatoG-ea4aaa?logo=githubsponsors&logoColor=white" alt="Sponsor HayatoG on GitHub"></a></p>

<p align="center"><a href="https://github.com/HayatoG/iss_pc/actions/workflows/build.yml"><img src="https://github.com/HayatoG/iss_pc/actions/workflows/build.yml/badge.svg" alt="Build"></a></p>

<p align="center">
  <a href="https://trendshift.io/repositories/307125?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-307125" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/307125/daily?language=C%2B%2B" alt="HayatoG/iss_pc | Trendshift (daily)" width="250" height="55"></a>
  <a href="https://trendshift.io/repositories/307125?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-307125" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/307125/weekly?language=C%2B%2B" alt="HayatoG/iss_pc | Trendshift (weekly)" width="250" height="55"></a>
</p>

<p align="center"><a href="https://youtu.be/F5sD_HCGCWo"><img src="docs/screenshots/video-tutorial.jpg" width="640" alt="How to port PS4 games: video on YouTube"></a></p>

<p align="center">▶️ <a href="https://youtu.be/F5sD_HCGCWo"><b>Tutorial video:</b> how to port PS4 games to PC (in Portuguese)</a></p>

> **Playable, in development.** The game boots, reaches gameplay and gets through the first chapters, but performance is still unstable (20–30 FPS typical on an RTX 2060) and there are known graphics glitches. See the [Status](#status).

**inFAMOUS Second Son** (PS4, CUSA00223, base game 1.00 + update 1.07) running on PC without a CPU emulator: the game's original code runs natively on the processor, the PS4 system is reimplemented, and the GPU is translated to Vulkan. It uses the same core as the [The Last Guardian](https://github.com/HayatoG/tlg_pc) and [Gravity Rush 2](https://github.com/HayatoG/gr2_pc) ports.

> **No game files come with this project.** To play, you need your own copy, dumped from your own PS4.

> **macOS (Apple Silicon):** a native build for Apple Silicon Macs (static recompilation to ARM64 and a Metal renderer) is in [`recomp/`](recomp/README.md).

By **HayatoG** · YouTube [@hayatog-dev](https://www.youtube.com/@hayatog-dev) · Discord [discord.gg/UMkdMYZh9g](https://discord.gg/UMkdMYZh9g)

| | |
|---|---|
| ![Delsin in front of the billboard, with the prompt to turn the controller sideways](docs/screenshots/01-grafite-sensor.jpg) | ![Delsin in the dock warehouse](docs/screenshots/02-galpao.jpg) |
| ![On the dock fence](docs/screenshots/03-cerca.jpg) | ![Running along the beach at sunset](docs/screenshots/04-praia.jpg) |

![Climbing the rocks above the village](docs/screenshots/05-escalada.jpg)

<sub>Captured at native resolution (1920×1080, scaled down to 1280), straight from the GPU, on Linux with an RTX 2060.</sub>

## Contributors

<p align="center">
  <a href="https://github.com/HayatoG"><img src="https://avatars.githubusercontent.com/u/22659047?v=4" width="72" alt="Contributor profile picture"></a>&nbsp;&nbsp;
  <a href="https://github.com/intemerated"><img src="https://avatars.githubusercontent.com/u/343755099?v=4" width="72" alt="Contributor profile picture"></a>&nbsp;&nbsp;
  <a href="https://github.com/Andretuta"><img src="https://avatars.githubusercontent.com/u/219594641?v=4" width="72" alt="Contributor profile picture"></a>&nbsp;&nbsp;
  <a href="https://github.com/Playdbunny"><img src="https://avatars.githubusercontent.com/u/70190491?v=4" width="72" alt="Contributor profile picture"></a>&nbsp;&nbsp;
  <a href="https://github.com/EdouardSence"><img src="https://avatars.githubusercontent.com/u/103503538?v=4" width="72" alt="Contributor profile picture"></a>&nbsp;&nbsp;
  <a href="https://github.com/HayatoG/iss_pc/graphs/contributors"><img src="https://github.com/identicons/guilherme-oliveira.png" width="72" alt="Contributor avatar"></a>&nbsp;&nbsp;
  <a href="https://github.com/batuhankiskac"><img src="https://github.com/batuhankiskac.png" width="72" alt="Contributor profile picture"></a>&nbsp;&nbsp;
  <a href="https://github.com/sapoguruoficial-cmd"><img src="https://github.com/sapoguruoficial-cmd.png" width="72" alt="Contributor profile picture"></a>
</p>

## What's new

- **New launcher (Qt Quick), now the default:** 10 screens, including **Mods / Cheats** and **Advanced**, the interface in Portuguese and English, and the game language following the system's by default. The old launcher (Tk) stays in the package as **inFAMOUS Second Son (classic)**, as a fallback. See [The launcher](#the-launcher).
- **Saves and data:** a configurable data folder, a backup before every play session, `.zip` export/import, duplicate and delete saves, and a search for saves from other installs. It fixes the "I lost my save after updating" problem. See [Saves and data](#saves-and-data).
- **Flickering headlights and glare that showed through characters: fixed.** The occlusion counter the game reads to know how much of a light is visible was a fake; the new mode 3 (the default) answers with zero counts, and that fixed the problem, **confirmed on Windows and on Linux**. See [Lights and occlusion](#lights-and-occlusion).
- **Experimental fixes BP01–BP12:** twelve fixes brought from other PS4 ports and from shadPS4, each with its own switch, a Recommended profile and a "Like the previous release" button to compare. See [Experimental fixes](#experimental-fixes).
- **More useful logs:** every log starts with a `Config:` block (your options, no paths) and shows the `Backports:` lines; the **Support** screen builds the report without personal data. See [Logs and reports](#logs-and-reports).
- **Controller guides:** ready-made images (Xbox, Switch Pro and 8BitDo, in Portuguese and English) of sensor mode and the touchpad, in [Motion sensor and touchpad](#motion-sensor-and-touchpad) and in the launcher's **Controller guides** screen.
- **CPUs without F16C (Sandy Bridge, #51):** the game's 13 half-precision conversions (`VCVTPH2PS`/`VCVTPS2PH`) are now emulated at start, bit-exact with the CPU (rounding, denormals, Inf and NaN). The game used to stop with "13 sites use encodings the rewrite cannot emulate".
- **Mouse:** the mouse turns the camera (right stick) and also plays the **touchpad**. Left = R2, right = L2, middle = R3. **Hold Left Ctrl (or the X1 side button)** and the mouse becomes a finger on the touchpad: left touches/clicks (hold = absorb a power), dragging with the left slides (the "Open Door" swipe, the scanner), right = two fingers (lift the car off Reggie). The window captures the mouse; Esc releases it and a click captures it again. See [Mouse](#mouse).
- **Graffiti steps on screen:** the first time sensor mode turns on, a screen in the middle shows the steps (shake, spray, aim, leave) with your controller's buttons; "Got it" closes it. The Insert menu has a new **Controls** tab that shows it again and sets the **graffiti aiming speed** (25–200%, also `ISS_SENSOR_AIM`).
- **Easier graffiti (sensor mode):** sensor mode is now the graffiti's spray can: turning it on (L3+R3) holds the controller on its side, as the game asks ("Hold Wireless Controller Sideways"); **cross/A shakes**, **R2 sprays** and the **left stick aims** the cursor left/right and up/down (it used to move only up and down), slower with a small push, for tracing the stencil. On the keyboard, while T or G hold the controller sideways, the **arrow keys** aim.
- **Being tested: flickering GPU smoke and particles (#7, #50).** Shader recompiler fixes, partly from the native [Shadow of the Colossus](https://github.com/AjncSystem/ShadowOfTheColossus-PC) port:
  - shared memory (LDS) barriers in compute shaders of every workgroup size, including those that are not multiples of 64 (96, 192...): `ISS_LDS_SMALL` (under 64 threads), `ISS_LDS_MULTI` (over 64; on 32-lane GPUs the barrier covers the whole workgroup, because each 64-lane PS4 wave takes two subgroups), `ISS_LDS_READLANE`;
  - `ISS_LANE_DIVERGENCE`: branches that depend on `v_mbcnt`, the lane number or an atomic's returned value count as divergent, so no barrier lands inside a branch only one lane takes;
  - `S_WQM_B64`, which did nothing (`ISS_WQM`).
  - All on by default in inFAMOUS; `0` turns each one off, for comparisons. The log has one `shader switch` line per switch.
  - Experiment, off: `ISS_RFL_ALL=1` makes `ReadFirstLane` read the first lane of the whole 64-lane wave in every wide compute shader (not only those that use ballots).
  - The shader cache rebuilds itself for each combination.
- **Fixes from [shadPS4-Infamous-FixBuild](https://github.com/rayhlancaner-png/shadPS4-Infamous-FixBuild):**
  - **Delsin's glow while draining energy fixed:** stencil now honors both the test and the write values, which are separate on PS4.
  - **More FPS:** when the game reads GPU results, only the thread that asked waits, not the whole GPU (`ISS_DEFERRED_READBACK`, on by default), and work goes to the GPU in pieces (`ISS_SUBMIT_DRAWS`, default 1024).
  - **Fewer hitches when a new effect shows up:** compute shaders compile off the GPU thread (`ISS_COMPUTE_ASYNC_BUILD`), and pipeline creation is retried when the driver fails.
  - **VRAM:** when video memory runs short, the port frees old textures and tries again instead of closing. Huge uploads, such as loading a save, go in parts, and the driver may page memory out to RAM.
  - **Float atomics** fixed on GPUs without native support, such as NVIDIA.
- **Motion sensor:** the DualShock 4/DualSense gyro works as is. On controllers without one, a tap on L3+R3 (or Share on an Xbox Series) toggles "sensor mode", the graffiti's spray can: the controller is held on its side, cross/A shakes, R2 sprays and the left stick aims. On the keyboard, T/G turn it sideways (the arrow keys aim while they are held) and Y shakes. This is what gets you past the graffiti ("Hold Wireless Controller Sideways").
- **Sticks:** a 10% dead zone against drift (`ISS_STICK_DEADZONE`, also in the launcher), and the last controller used is the one that counts.
- **Touchpad without a touchpad:** hold View/Select (or Tab) and move the right stick (or the arrow keys) to swipe, as in "Open Door"; a quick tap still clicks.
- **Performance:** FPS no longer drops over time (it went from 60 to 6 in 2 minutes: shader variants were never reused), and repeated partial image transitions are skipped.
- **Precise GPU readbacks by default:** the energy-drain smoke, drones and other GPU-computed particles show up. The fast mode is still in the launcher ("GPU accuracy").
- **Automatic shader cache:** it lives in `user/cache/`, next to the saves (Linux and Windows; the old cache in `~/.local/share/shadPS4` or `user/user/` is moved over on the first start). The folder is keyed by the shader recompiler version, and the old cache is deleted on its own after an update. To rebuild everything, the launcher has a **Clear shader cache** button (or `./run_infamous.sh --clear-shader-cache`); it deletes only this game's compiled shaders, never saves or settings.

## Status

| Area | State |
|---|---|
| Boot, title, intro and gameplay | ✅ Works; tested up to "Go to Longhouse", with climbing, running, powers and cutscenes |
| Motion sensor (graffiti, motion prompts) | ✅ Real gyro, or simulated on any controller and the keyboard |
| Drain smoke, drones and GPU particles | ✅ With precise GPU readbacks (default) |
| HUD | ✅ Correct |
| Audio | ✅ Our own AudioOut + Ajm, no firmware file needed |
| Saves | ✅ The save is created and "Continue" works |
| Controller | ✅ DualSense, DualShock 4, Xbox and 8BitDo via SDL3 |
| Performance | 🔧 20–30 FPS typical on an RTX 2060, unstable; optimization ongoing |
| Stutter | 🔧 The first time each shader is compiled (cutscenes and new areas) |
| Lights (flickering headlights, glare showing through characters) | ✅ Fixed by occlusion mode 3 (default), confirmed on Windows and on Linux; if light glare looks weak, use mode 0 |
| Graphics | 🔧 Some fog, water and fire effects still flicker |
| Launcher | ✅ Qt Quick (default) with the Tk one as a fallback; Portuguese and English |
| Saves and data | ✅ Configurable folder, backup, export/import |
| Mouse (camera and touchpad) | 🧪 Implemented, not yet tested much in game |
| Experimental fixes (BP01–BP12) | 🧪 The ones on by default come in the Recommended profile; BP07 and BP09 (off) are experimental; BP06 and BP08 are on by default |
| Linux | ✅ Tested (Nobara/Fedora 44) |
| Windows | 🧪 Tested by players (the lights fix was confirmed); known crash on RX 580/Polaris, see [Known problems](#known-problems) |

![Performance over a 7-minute session walking through the city](docs/screenshots/desempenho.png)

<sub>FPS, worst frame and draws per frame every 5 s, from the port's log (`ISS_FRAME_STATS=1`), on an RTX 2060: median 27 FPS, above 30 FPS 44% of the time. The game has no frame cap. Made with `scripts/session_chart.py` (`0` = uncapped).</sub>

## Plans

| Plan | State |
|---|---|
| 720p | 📋 Planned |
| 2K | 📋 Planned |
| 4K | 📋 Planned |
| Ultrawide | 📋 Planned |
| 60 Hz | ✅ Partially done |
| 120 Hz | 📋 Planned |
| 240 Hz | 📋 Planned |
| Mods | 📋 Planned |
| Cheats | 📋 Planned |
| FSR | 📋 Planned |
| DLSS | 📋 Planned |

## Download

The [**latest release**](https://github.com/HayatoG/iss_pc/releases/latest) is published when the maintainer chooses to bundle the accumulated changes. PRs build and test; approvals and merges do not trigger builds. On `main`, Linux and Windows build only through an authorized manual release run. Older ones stay under [Releases](https://github.com/HayatoG/iss_pc/releases) as history. See [how to publish](docs/RELEASES.md):

- **Linux x86-64** (glibc 2.39+: Ubuntu 24.04, Fedora 40, SteamOS 3.6 or newer): `infamous-linux-x86_64.tar.gz`
- **Windows 10 (1903 or newer) / 11, 64-bit**: `infamous-windows-x86_64.zip`

The packages open the Qt launcher by default; it adds about 55 MB to the download (measured on Linux; an estimate on Windows). If the new launcher does not open on your machine, use **inFAMOUS Second Son (classic)**, in the same folder.

## Required game files

Everything comes from **your own** PS4 (GoldHEN + Itemzflow). None of it is in the download. Use **inFAMOUS Second Son CUSA00223 (US), base game 1.00 with update 1.07**, merged into one folder, with the base game and the update on top. About 33 GB.

| File | From | Purpose |
|---|---|---|
| `eboot.bin` | update 1.07 | the game code (must be the 1.07 one) |
| `sce_module/libc.prx`, `sce_module/libSceFios2.prx` | update 1.07 | the game's own libraries |
| `sce_sys/` (`param.sfo`, `playgo-chunk.dat`, `icon0.png`, `pic1.png`) | base game (+ the update's `param.sfo`) | metadata, install info and the launcher art |
| `art/` (`cache/`, `movies/`, `ui/`) | base + update | game content |
| `playgo.pgm`, `sce_discmap.plt`, `sce_discmap_patch.plt` | base + update | file map and install info |

**From the console firmware:** nothing. Audio uses our own AudioOut + Ajm; the game imports neither `libSceNgs2` nor any other PS4 system module.

The full list and the step-by-step guide, which also go in the notes of every Release, are in [`docs/ARQUIVOS_NECESSARIOS.md`](docs/ARQUIVOS_NECESSARIOS.md).

**PC:** 64-bit Windows 10 (1903+)/11 or x86-64 Linux (glibc 2.39+), a graphics card with Vulkan 1.3 (6 GB of VRAM recommended) and ~33 GB free.

## How to play

1. Extract the package.
2. Open **inFAMOUS Second Son** (on Windows, if "Windows protected your PC" appears, click *More info*, then *Run anyway*: the program is not digitally signed). Pick the game folder and click **Play**. The game language follows your system by default; you can change it on the same screen. If it stutters too much, the "GPU accuracy" option (**Graphics** screen) has a fast mode (without GPU particles).
3. In game, **F10** toggles the FPS counter, and **Insert** (or R3 + L2 on a controller) opens the port's menu.
4. When the game asks you to turn or shake the controller and yours has no sensor: tap L3+R3 (or Share on an Xbox Series). The controller is then on its side; cross/A shakes, R2 sprays and the left stick aims. Tap again to leave. On the keyboard: T/G (with the arrow keys to aim) and Y. See [Motion sensor and touchpad](#motion-sensor-and-touchpad).

The full guide is in [`README-player.md`](port/packaging/README-player.md), which also ships inside the package.

## The launcher

The launcher is the program that opens when you run **inFAMOUS Second Son**. The new one (Qt Quick) is the default; the old one (Tk) sits next to it as **inFAMOUS Second Son (classic)**, in case the new one does not open. Both use the same settings and the same saves, and accept `--play`, `--script` and `--clear-shader-cache`.

| Screen | What it is for |
|---|---|
| **Play** | game folder, game language, detected GPU and version, fixes profile, the occlusion (lights) selector, the Continue/Play button |
| **Graphics** | window mode, VSync, FPS limit, FSR 1 and sharpening, GPU accuracy, VRAM budget, shader cache, overlay and presets (Performance, Balanced, Quality, Faithful to PS4) |
| **Controls** | stick dead zone, graffiti aiming speed, mouse (camera and touchpad mode), keyboard map and remapping |
| **Fixes** | BP01–BP12, diagnostic (A/B) switches and Insert menu options; Recommended profile and "Like the previous release" |
| **Saves & data** | data folder, list of saves, backups, `.zip` export/import; see [Saves and data](#saves-and-data) |
| **Controller guides** | Xbox, Switch Pro and 8BitDo images (Portuguese and English): save, copy, open the folder |
| **Support** | known problems for your GPU, links and the problem report; see [Logs and reports](#logs-and-reports) |
| **Mods / Cheats** | enables cheat XML files and the optional boot logo movie skip (story cutscenes remain unchanged) |
| **Advanced** | additional launcher and port settings |
| **Updates** | shows the installed version and checks the latest release (see below) |

**Interface language:** Portuguese (Brazil) or English (US), which the launcher picks from the system language and you can change. When you pick one, the launcher passes it to the game (`ISS_UI_LANG`) for the overlay.

**Game language:** the first option is **Automatic (system language)**, the default, followed by the languages your dump's `sce_sys/playgo-chunk.dat` lists, out of the PS4's 30 (US and UK English, Brazilian and European Portuguese, Latin American and Spain Spanish, French and Canadian French, German, Italian, Dutch, Polish, Turkish, Russian, Japanese, Korean, Chinese and more); without that file (FTP dumps) the 6 of CUSA00223: English (1), Português (Brasil) (17), Español (Latinoamérica) (20), Français (Canada) (22), Türkçe (19) and Русский (8). Automatic follows the system's language and region (es_ES is Spain Spanish, es_MX Latin American, pt_PT European Portuguese) and, when the game lacks that language, the closest variant (Spain/Latin American Spanish, European/Brazilian Portuguese...), else English. The choice applies on the next start and becomes `ISS_LANGUAGE` (an `ISS_LANGUAGE` you set yourself wins). **It only works if your game files have that language:** Turkish and Russian, for example, only show up if your dump has them. It is separate from the interface language.

**Updates:** the **Updates** screen makes a single HTTPS query for the latest release on GitHub (nothing of yours is sent), shows the notes in the interface language, and the **Download** button only opens the release page. **It does not download or install anything: a real automatic updater does not exist yet.** "Check on open" is off by default.

**Running from source:** needs Python 3 with PySide6 (>= 6.7):

```bash
python3 -m venv .venv-qt
.venv-qt/bin/pip install -r port/launcher/qt/requirements.txt
./infamous_launcher_qt.sh      # the old launcher: ./infamous_launcher.sh
```

On Windows: `py -m venv .venv-qt`, `.venv-qt\Scripts\pip install -r port\launcher\qt\requirements.txt` and `.venv-qt\Scripts\python port\launcher\infamous_launcher_qt.py`. Without PySide6 the entry point says how to install it. The package already ships everything frozen, no Python needed.

**Self-test:** `"inFAMOUS Second Son" --selftest` opens the launcher off screen, checks QML, fonts, icon and translations, visits every screen and prints `selftest ok` (it does not read your settings or saves and does not start the game). The CI runs it on every package. Details: [`docs/LAUNCHER_QT.md`](docs/LAUNCHER_QT.md) and [`docs/QT_PACKAGING.md`](docs/QT_PACKAGING.md).

## Experimental fixes

The launcher's **Fixes** screen (and the **Experimental fixes…** button of the Tk launcher) turns the 12 fixes `BP01` to `BP12`, brought from other PS4 ports and from shadPS4, on and off one by one. Each has the `ISS_BPnn` (or `TLG_BPnn`) switch and a `bpnn` line in `tlg.ini`; if you touch nothing the defaults hold, and they make up the **Recommended** profile. "In game" means it can also be changed from the Insert menu, on the spot; "restarts" applies on the next start (the ones that change shaders recompile the shaders on the first game, and the image may flicker or look green for a while).

| Id | What it does | Source | Default | Applies |
|---|---|---|---|---|
| BP01 | frees the frame of nested command buffers | shadPS4 #5258 | on | in game |
| BP02 | faster texture lookup (first page only) | shadPS4 #5240 | on | in game |
| BP03 | keeps EXEC after an empty divergent branch | shadPS4 c34ca21f | on | restarts, recompiles shaders |
| BP04 | reciprocal/root/log without clamp, like the hardware | shadPS4 #5346 | on | restarts, recompiles shaders |
| BP05 | saturate treats NaN like the GPU (becomes 0) | shadPS4 #5257 | on | restarts, recompiles shaders |
| BP06 | maximal reconvergence in compute shaders | native Shadow of the Colossus port | **on** | restarts, recompiles shaders |
| BP07 | async compile never skips small or indirect draws | bbport (bloodborne_pc) | **off** (experimental) | in game |
| BP08 | keeps the driver pipeline cache between sessions | Mrsuss, 0xCydral (bloodborne_pc) | **on** (since 2026-10-16) | restarts |
| BP09 | every 1D image becomes 2D with height 1 | CTR | **off** (experimental) | restarts, recompiles shaders |
| BP10 | barriers for vertex, index and indirect buffers | shadPS4 #5262 | on | in game |
| BP11 | `firstInstance` counted once in indirect draws | shadPS4 #5348 | on | restarts, recompiles shaders |
| BP12 | `EarlyFragmentTests` when the game asks for depth before the shader | shadPS4 #5264 | on | restarts, recompiles shaders |

- **Like the previous release:** `TLG_BACKPORTS=0` (or the launcher button) turns off every BP that is on by default, to compare with the version without them; an individual `TLG_BPnn` still wins. On the first start after updating, a one-time message explains this. If a scene gets worse, test this way first, then turn them back on one by one.
- **Back to recommended** clears all your choices. Only what differs from the default is written.
- **Diagnostic (A/B) switches:** `ISS_WQM`, `ISS_LDS_SMALL`, `ISS_LDS_MULTI`, `ISS_LDS_READLANE`, `ISS_LANE_DIVERGENCE`, `ISS_RFL_ALL`, `ISS_BLOCK1D`, `ISS_BC_TINY`, `ISS_NO_MSAA`, `ISS_BACKGROUND_WARMUP`, `ISS_PIPELINE_BINARIES` (still crashes the game on the NVIDIA 595 driver) and the occlusion selector (`ISS_OCCLUSION_MODE`); `0` turns off, `1` turns on. They exist to find which change causes a problem.
- **GPU smoke no longer flickers (#7, #50):** `ISS_DYNAMIC_STRIDE` (on; `0` turns it off) makes compute shaders read each buffer's stride from the GPU descriptor instead of compiling it in, so one compiled shader serves every stride: the smoke stopped flickering and the first-run compile got 30% smaller (17,822 → 12,490 shaders).
- **Being tested:** `ISS_PRESENT_ACQUIRE_FENCE` (on; `0` turns it off) makes the present thread wait for the screen's image before submitting the frame, so it does not hold the GPU queue with VSync on. It comes from [Castlesea](https://github.com/Castlesea/infamous-second-son-pc-port)'s port.
- BP08 (the on-disk driver pipeline cache) is on since 2026-10-16: pipeline creation gets fast enough that no draw is skipped (the grey one-frame flashes). The file is saved only when there are new pipelines and never grows past 1 GB (`ISS_DRIVER_CACHE_MAX_MB`; deleting it starts over). The rest of the shader stutter is on the [roadmap](docs/ROADMAP.md).
- Full table, with the `tlg.ini` keys and the Insert menu options: [`docs/EXPERIMENTAL_FIXES.md`](docs/EXPERIMENTAL_FIXES.md).

## Lights and occlusion

Headlights flickered and the glare of lights showed up **through** characters. The cause: the occlusion counter (`ZPASS_DONE`) that the game reads to know how much of each light is visible was a fake number that only grew. Mode **3** (zero counts) fixed it, confirmed on Windows and on Linux, but treated every glare as hidden. Mode **4**, now the default, measures **real occlusion** on the GPU (Vulkan occlusion queries, from the weshayoub92 fork used by [Castlesea](https://github.com/Castlesea/infamous-second-son-pc-port)): the glare shows when the light is in view and disappears behind walls and characters.

| `ISS_OCCLUSION_MODE` | Effect |
|---|---|
| `0` | old behavior (fake counter; glare may show through) |
| `1` | test: lights count as hidden |
| `2` | test: lights count as fully visible |
| `3` | zero counts (previous default) |
| `4` | real occlusion, counted by the GPU: **default** |

The **Light glare (occlusion)** selector is on the launcher's **Play** screen (and among the diagnostic switches); the variable also takes the `TLG_` prefix. If a scene looks worse with mode 4, use mode 3 and send the log and a screenshot of each mode. `ISS_OCCLUSION_LOG=1` writes to the log how many queries were counted.

## Mouse

The mouse works with or without a controller (its buttons add to the controller's). The game window captures the mouse while it has focus and the Insert menu is closed; **Esc releases it** (the cursor comes back) and **a click in the window captures it again** (that click is not a game button).

**Camera and buttons:**

| Mouse | In the game |
|---|---|
| Move | turns the camera (right stick) |
| Left button | R2 (use the power / shoot) |
| Right button | L2 (aim) |
| Middle button | R3 |
| Side buttons X1 / X2 and the wheel | free (see `ISS_KEY_MAP`); X1 is also a touchpad-mode key |
| Sensor on (sensor mode, T or G) | the mouse points the graffiti spray can instead of turning the camera |

**Touchpad mode:** hold **Left Ctrl** or the mouse's **X1 side button**. While the mode is on the camera does not turn: mouse motion moves a virtual finger over the touchpad (a small pad in the bottom-left corner of the screen shows where it is) and the buttons become the finger:

| Gesture (mouse in touchpad mode) | What the game sees | Where to use it |
|---|---|---|
| Just move | hovering finger (no touch): places the finger | before a gesture |
| Left, quick tap | touch + touchpad click | "press the touchpad" interactions |
| Left, hold still | touch + click held | absorbing/draining powers (smoke, neon...) |
| Left, drag more than 80 units | the click is released and the finger slides | "Open Door", hand scanner |
| Middle button (hold and move) | finger with no click | sliding without a click, if a gesture dislikes the click |
| Right | two fingers on both ends with the touchpad pressed | lifting the car off Reggie |

The finger starts in the middle of the touchpad and stays where you leave it. The keyboard shortcuts (Tab/Backspace, Tab + arrow keys) work as before.

**Environment variables** (`ISS_` and `TLG_` work the same; the `mouse_*` ones can also go in `tlg.ini`):

| Variable | Default | What it does |
|---|---|---|
| `ISS_MOUSE` | `1` | `0` turns the mouse off (the window no longer captures it) |
| `ISS_MOUSE_SENS` | `1.0` | camera sensitivity (0.05-10) |
| `ISS_MOUSE_INVERT_Y` | `0` | `1` inverts the Y axis |
| `ISS_MOUSE_SMOOTHING` | `0.5` | smoothing (0-0.95) |
| `ISS_MOUSE_ACCEL` | `0` | acceleration (0-2) |
| `ISS_MOUSE_DEADZONE` | `0.1` | anti-dead zone: small movements skip the game's dead zone (0-0.5) |
| `ISS_MOUSE_PAD` | `1` | `0` turns the mouse touchpad mode off |
| `ISS_MOUSE_PAD_KEY` | `Left Ctrl\|Mouse X1` | touchpad-mode key(s); SDL key names or `Mouse Left/Middle/Right/X1/X2`, separated by `\|` |
| `ISS_MOUSE_PAD_MODE` | `hold` | `toggle`: one press turns it on, another turns it off |
| `ISS_MOUSE_PAD_SENS` | `1.0` | finger speed (0.1-10) |
| `ISS_MOUSE_PAD_DRAG` | `80` | units (the touchpad is 1920 wide) of drag before the click becomes a swipe; `0` = never |
| `ISS_KEY_MAP` | — | remaps keys and mouse: `"r2=Mouse Left\|F,l2=Mouse Right\|R,r1=Mouse X2,l1=Wheel Down"`; several per button with `\|`, `none` removes all |
| `ISS_MOUSE_LOG` | `0` | `1` logs what the game gets from the mouse |

The Insert menu's **Controls** tab has the mouse camera settings, and the launcher's **Controls** screen has the same ones, the touchpad mode and the keyboard map. **The mouse is new and has not been tested much in game by other players yet**: if something misbehaves, `ISS_MOUSE=0` turns it off and a report helps.

**Keyboard (default map):** works with or without a controller (the keys add to the controller's buttons).

| Key | PS4 button | Key | PS4 button |
|---|---|---|---|
| W / S (A / D) | left stick | arrow keys | right stick |
| Space | cross | Left Shift | circle |
| E | square | Q | triangle |
| 1 | L1 | 3 | R1 |
| R | L2 | F | R2 |
| Z | L3 | C | R3 |
| Enter | Options | Tab / Backspace | touchpad click (left / right) |
| I / K / J / L | d-pad (up / down / left / right) | T / G / Y | simulated sensor mode (see below) |

**Remapping:** `ISS_KEY_MAP` (or the advanced field of the launcher's **Controls** screen) changes keys and mouse buttons: `"cross=Q,r2=Mouse Left|F"`. The buttons are `cross`, `circle`, `square`, `triangle`, `l1`, `r1`, `l2`, `r2`, `l3`, `r3`, `options`, `up`, `down`, `left`, `right`, `touchpad_left`, `touchpad_right`.

## Saves and data

By default saves and settings live in `user/`, next to the game. **Updating deletes nothing** (the zip does not carry `user/`), but if you extract the new zip into **another folder**, or delete the old one, the game opens without saves: they are still in the old folder, under `user/savedata`. That is why it looks like "the update deleted my save".

**Recipe to update without losing saves:**
1. Open the launcher, go to **Saves & data** and click **Back up now** (and, if you like, **export all** to a `.zip`).
2. Pick a fixed data folder outside the game (suggestion: `Documents\inFAMOUS-PC` on Windows, `~/.local/share/infamous-pc` on Linux). The launcher asks whether to copy your saves and settings there (it copies, never moves).
3. Download and extract the new version anywhere: it finds the saves through that choice, which is kept in a per-user file and survives reinstalls.
4. If you already extracted the new version and the save is gone, the screen finds the other installs (Downloads, Desktop, Documents, neighbor folders...) and offers **Import**.

**Where the data folder is**, in this order: the `ISS_USER_DIR` variable; the per-user pointer file (`%APPDATA%\inFAMOUS-PC\launcher.json` on Windows, `~/.config/infamous-pc/launcher.json` on Linux); and, with neither, `user/` next to the game (portable mode). The same folder holds `tlg.ini`, saves, backups and the shader cache.

**DLC (costumes, Cole's Legacy):** the content is already in the base game; only the license is missing. Put your own DLC packages (`.pkg`) or the DLC folders of your dump (with `sce_sys/param.sfo`) in `dlc/`, inside the data folder. The launcher reads only each one's label, copies and changes nothing, and the game sees them as installed (`ISS_ADDCONT_LABELS=LABEL,LABEL` does the same by hand).

**On the Saves & data screen:** one card per slot (title, chapter, karma, date, size and the save's own thumbnail) with `.zip` export, duplicate and delete; `.zip` import; backups with **Restore**, keeping the last N (default 10) and an extra backup folder (another disk). **A backup is made before every play session** (skipped if nothing changed). Every operation that writes to a save needs the game closed and makes a safety backup first; an invalid or dangerous `.zip` (paths with `..`, absolute paths, links) is refused without writing anything.

## Motion sensor and touchpad

The game asks for the motion sensor and the touchpad in many scenes: graffiti, absorbing powers (smoke, neon...), opening doors and other interactions. On a **DualShock 4 or DualSense** the gyro and the touchpad work as is, with nothing to turn on. On other controllers and on the keyboard, the port simulates both.

**Controller guides** (the same images are on the launcher's **Controller guides** screen, with buttons to save and copy):

| Xbox / Xbox Series | Nintendo Switch Pro | 8BitDo |
|---|---|---|
| ![Guide for Xbox, in English](port/launcher/qt/assets/controller_guides/inFAMOUS-controle-xbox-en-US.png) | ![Guide for Switch Pro, in English](port/launcher/qt/assets/controller_guides/inFAMOUS-controle-switch-en-US.png) | ![Guide for 8BitDo, in English](port/launcher/qt/assets/controller_guides/inFAMOUS-controle-8bitdo-en-US.png) |

**Sensor mode (turning it on and off):**
- **One tap on L3+R3 together** turns sensor mode on; another tap turns it off. It works on any controller. The controller's extra button works too: **Share** on an Xbox Series, **Capture** on a Switch Pro and the **microphone** button on a DualSense. On a DualShock 4 or DualSense, Share/Create does **not** toggle sensor mode: it is the touchpad click.
- A notice on screen confirms it: "Sensor mode ON (spray can): cross shakes, R2 sprays, left stick aims" or "Sensor mode off".
- While it is on, the controller is **on its side**, like a spray can (what the graffiti asks for), **cross/A shakes** and the **left stick aims**, pointing the can left/right and up/down (this moves the graffiti cursor; it stays where you let go; a small push is slow, for tracing the stencil; the right stick works too). R2 still sprays. The sticks and cross/A are hidden from the game, so Delsin neither walks nor jumps and the camera does not turn: **turn the mode off after the scene**. L3+R3 together never reaches the game either.
- While it is on, the simulated tilt replaces the real gyro.
- **Keyboard** (no mode needed, any time): hold **T** or **G** to turn the controller sideways (one side or the other; the arrow keys or the mouse aim) and **Y** to shake it, or wiggle the mouse quickly side to side (or spin the wheel) while T or G is held.

**Touchpad on a controller without one:**
- **View/Select/Back** is the touchpad click (right side; with L1 held, the left side). Holding the button holds the touchpad.
- **Hold View/Select and move the right stick** to swipe a finger from the middle of the touchpad. A quick tap without moving still clicks.
- **Keyboard:** Tab (left side) and Backspace (right side) click; **hold Tab and use the arrow keys** to swipe.
- **Two fingers on both ends of the touchpad** (lifting the car off Reggie): **hold View/Select + R1**; on the keyboard, **hold Tab + Backspace**.

| In-game action | DualShock 4 / DualSense | Xbox / other controller | Keyboard |
|---|---|---|---|
| Absorb/drain a power (smoke, neon...) and "hold the touchpad" interactions | hold the touchpad | hold View/Select (leave the right stick alone, or it becomes a swipe) | hold Tab or Backspace (no arrow keys); mouse: Left Ctrl (or X1) + hold the left button still |
| "Press the touchpad" interactions | click the touchpad | tap View/Select | Tab or Backspace |
| Graffiti: turn the controller sideways | turn the controller | L3+R3 (sensor mode): it is on its side at once | hold T or G |
| Graffiti: shake the can | shake the controller | cross/A in sensor mode | Y |
| Graffiti: spray | R2, aiming with the controller | R2, aiming with the left stick in sensor mode | F (R2), aiming with the arrow keys while holding T or G |
| Press both ends of the touchpad (lifting the car off Reggie) | two fingers, one on each end | hold View/Select + R1 | hold Tab + Backspace; mouse: Left Ctrl (or X1) + right button |
| Touchpad swipe ("Open Door", hand scanner) | swipe a finger | hold View/Select + right stick in the asked direction | hold Tab + arrow keys; mouse: hold Left Ctrl (or X1), left button and drag |
| Back to normal after the graffiti | — | L3+R3 again ("Sensor mode off") | — |

**Launcher:** the **Controller** box has the **Stick dead zone** (0–40%, default 10%). Raise it if the character, the camera or the sensor-mode tilt moves on its own (stick drift).

**Environment variables:** `ISS_MOTION_BUTTON=<SDL button>` changes the sensor-mode button (default `misc1`; L3+R3 always works), and `ISS_MOTION=off` ignores the real gyro (the simulation still works).

**Intel CPUs:** the game's code uses SSE4A instructions (EXTRQ), which only AMD CPUs have. On Intel the port replaces them with an emulation at start (needs `iced-x86`, included in the packages). Older CPUs (Sandy and Ivy Bridge) also lack MOVBE, F16C, BMI1 or LZCNT, which are emulated the same way; AVX is still required. `ISS_ISA_REWRITE=sse4a` (or `f16c`, or a list such as `f16c,movbe`) forces the emulation on a CPU that has the instruction (testing), `ISS_ISA_REWRITE=1` forces every emulated set (MOVBE, BMI1, LZCNT, F16C, SSE4A) and `ISS_ISA_REWRITE=0` turns it off. Details: [port/docs/isa_rewrite.md](port/docs/isa_rewrite.md).

**Windows red-zone protection.** PS4 code keeps variables in the 128 bytes below `rsp` (the "red zone"), and Windows writes there on every exception (the port uses exceptions to track GPU memory). At start the port rewrites the memory instructions of the functions that use the red zone so they run with `rsp` 128 bytes lower (crash at `0x1cfaaf`, #29/#41). On by default on Windows; `ISS_RED_ZONE_REWRITE=0` turns it off and `ISS_RED_ZONE_REWRITE=1` turns it on on Linux (testing). Linux test: `TLG_CLOBBER_RED_ZONE=<bytes>` zeroes that many bytes below `rsp` on every exception, like Windows (`1` = 128). Details: [port/docs/red_zone.md](port/docs/red_zone.md).

**Frozen screen:** if the game shows no new frame for 10 s, the log (`out/last_run.log`) gets a `FREEZE: no frame for 10 s; threads:` block with every thread of the game, what it is waiting on (mutex, semaphore, event queue, file read, GPU...) and where it is in the code. The game keeps running, and the report only repeats after frames resume and stop again. Send that log with the report. `ISS_FREEZE_REPORT_SECONDS=<s>` changes the time (`0` turns it off).

**AMD cards on Windows (RX 580): experimental compatibility.** Players have reported crashes after the logos in `amdvlk64.dll+0xebbbb` (#31, #49). The [PR #232](https://github.com/HayatoG/iss_pc/pull/232) investigation found a batch of 9,217 barriers, including 9,216 for one image with 1,536 layers and 6 mips; the log does not prove that call caused the crash. Two players reported getting past that point with a test build. Enable **RX580 compatibility** in **Graphics → Image**, or choose **RX 580 compatibility (experimental)** to also apply the recommended AMD settings. This test defaults to off, requires a game restart and still needs validation in this version. The same switch appears in **Advanced → Image workarounds**. From a terminal: `ISS_BARRIER_MERGE=1` merges equivalent adjacent image barriers; `0` disables it. Values set outside the launcher take precedence. The earlier tiny-BC texture workaround remains available (`ISS_BC_TINY=0/1`), but is not a confirmed fix for this crash. For diagnostic comparisons, **Advanced** exposes `ISS_EXPLICIT_RANGE` (default `1`, explicit mip/layer counts) and `ISS_BARRIER_SPLIT` (default `0`; `1` splits per mip, `2` per mip and layer; requires explicit ranges). These experiments alone did not resolve the crash in the author's tests. Credit: @intemerated for merging and investigation; @Andretuta for the initial launcher integration.

## Logs and reports

Every game writes a log to `out/logs/run-YYYYMMDD-HHMMSS.log` (the most recent ones are kept; `out/last_run.log` points to the latest). The log starts with the `Build:` line and a **`Config:`** block with the keys of your `tlg.ini` and the `TLG_`/`ISS_` variables that are set (values that look like paths are left out), and has the `Backports:` lines (each BP with its on/off state, and the occlusion mode) and, with the frame statistics, `Backport hits (total): ...` (how many times each fix actually ran). With that, a report says which fixes were on.

**How to report a problem:** open the launcher's **Support** screen and use **Report a problem**: it collects GPU, driver, VRAM, system, CPU, port and game versions, lets you pick the log, **strips personal paths from the text** (user name and folder) and offers **Copy report**, **Save .zip** (report and log without paths) and **Open issue on GitHub**. Nothing is sent without your click. To report by hand, attach the log to an [issue](https://github.com/HayatoG/iss_pc/issues) or send it on [Discord](https://discord.gg/UMkdMYZh9g).

**Big log:** GitHub refuses big files. Compress the log into a `.zip` (the Support screen already does) before attaching it.

## Known problems

The launcher's **Support** screen shows the ones that match your GPU (a local table, no internet query). The ones known today:

| Situation | What happens | What to do |
|---|---|---|
| **AMD RX 580 / Polaris on Windows** (#31, #49, #59, #65, #67, #81) | crash right after the logos in `amdvlk64.dll+0xebbbb` | **experimental workaround available.** Try the **RX 580 compatibility (experimental)** launcher preset, restart the game and send the log; a fix is not guaranteed |
| **GPU with 4 GB of VRAM** (#72, #75) | texture memory runs out; very low FPS | lower the resolution (Graphics screen) and keep the VRAM budget below your card's memory. Note: **"GPU accuracy: Fast" darkens the image** |
| **NVIDIA Quadro / Maxwell** (#70) | may be below the port's minimum; black screen or the game does not open | tell us what you saw; no fix yet |
| **CPU without SSE4A or F16C** (Intel, Sandy Bridge...) | the port emulates those instructions at start | automatic; see [Intel CPUs](#motion-sensor-and-touchpad) |
| **Game version** | tested with **CUSA00223 1.00 + 1.07**; CUSA00004 also boots | use CUSA00223 with the 1.07 update |

NVIDIA RTX 30 cards on Windows have reported flickering lights and smoke; use the Recommended profile and play two sessions in a row (the first one recompiles the shaders). For the other open problems, see the [issues](https://github.com/HayatoG/iss_pc/issues).

## Building from source

```bash
git clone --recursive https://github.com/HayatoG/iss_pc.git && cd iss_pc
cd port && ISS_LTO=OFF bash build.sh   # Linux: SDL3, Vulkan, FFmpeg, FreeType, Boost, fmt, Zydis, glslang
cd .. && ./infamous_launcher_qt.sh     # Qt launcher (needs PySide6); ./infamous_launcher.sh is the Tk one; ./run_infamous.sh from a terminal
```

A clone builds without profile-guided optimization (PGO): the profile (`port/pgo/*.gcda`) is not in the tree, and the release packages are built without it as well, so a local build and a package should perform alike. `ISS_PGO=generate` builds an instrumented binary that writes the profile while you play, and the next build uses it.

On Windows, the build runs in MSYS2 CLANG64 ([`port/packaging/windows/README.md`](port/packaging/windows/README.md)). The workflow [`.github/workflows/build.yml`](.github/workflows/build.yml) shows the full process on both platforms.

## How it works

| Layer | What it does | Based on |
|---|---|---|
| Loader | Loads the 1.07 `eboot.bin` and links the game's own modules (`libc`, `Fios2`) | [tlg_pc](https://github.com/HayatoG/tlg_pc), [gr2_pc](https://github.com/HayatoG/gr2_pc), [gow3_pc](https://github.com/FelipePrado0/gow3_pc), [bloodborne_pc](https://github.com/deadinside28/bloodborne_pc) |
| Runtime | Reimplements the PS4 libraries (NpManager, Trophy, Http, PlayGo, SaveData, AppContent, AudioOut, Ajm...). inFAMOUS-specific: `port/src/runtime_infamous.c` | `port/src/` |
| Video | Translates Gnm commands and GCN shaders to Vulkan/SPIR-V | [shadPS4](https://github.com/shadps4-emu/shadPS4) video core |

## Next steps

What is left is in [`docs/ROADMAP.md`](docs/ROADMAP.md): performance (waits on GPU readbacks), an on-disk pipeline cache against the stutter (BP08 is only the first step), real occlusion through Vulkan, the fog, water and fire effects that still flicker, the drone-drain glow, the RX 580 crash on Windows, an automatic updater and validating the mouse.

## Credits and legal notice

Code base: [tlg_pc](https://github.com/HayatoG/tlg_pc), [gr2_pc](https://github.com/HayatoG/gr2_pc), [gow3_pc](https://github.com/FelipePrado0/gow3_pc) (FelipePrado0), [bloodborne_pc](https://github.com/deadinside28/bloodborne_pc) and [shadPS4](https://github.com/shadps4-emu/shadPS4) the [shadPS4-Infamous-FixBuild](https://github.com/rayhlancaner-png/shadPS4-Infamous-FixBuild) fork (Eye Of The Ruins/rayhlancaner-png, TOXIC-KID, 0xDeftones) and the native [ShadowOfTheColossus-PC](https://github.com/AjncSystem/ShadowOfTheColossus-PC) port (AjncSystem; with parts of Pink-shadPS4 by luizgustavs), all GPL-2.0, as is this project ([LICENSE](port/LICENSE)). ATRAC9 audio via [LibAtrac9](https://github.com/Thealexbarney/LibAtrac9); fonts via [FreeType](https://freetype.org).

**Origin of the experimental fixes (BP01–BP12):** the recompiler and video fixes come from [shadPS4](https://github.com/shadps4-emu/shadPS4) (BP01–BP05, BP10–BP12), the native [Shadow of the Colossus](https://github.com/AjncSystem/ShadowOfTheColossus-PC) port (BP06), bbport, i.e. [bloodborne_pc](https://github.com/deadinside28/bloodborne_pc) (BP07), Mrsuss's [bloodborne_pc_windows_port](https://github.com/Mrsuss60/bloodborne_pc_windows_port) and 0xCydral's [bloodborne_pc](https://github.com/0xCydral/bloodborne_pc) (BP08) and CTR ([T3CHNOLOG1C/CTR](https://github.com/T3CHNOLOG1C/CTR)) (BP09). The exact commits are in [`docs/EXPERIMENTAL_FIXES.md`](docs/EXPERIMENTAL_FIXES.md) and `port/gpu/VENDOR.txt`. Launcher fonts: Big Shoulders Stencil Display and Barlow (OFL license, in `port/launcher/qt/fonts/`).

### Acknowledgements

- **Kazu**, for the logs, screenshots and tests, on Windows and on Linux, that led to the fix for the flickering headlights and the glare showing through characters (occlusion mode 3).
- **[Castlesea](https://github.com/Castlesea/infamous-second-son-pc-port)**, author of another native inFAMOUS Second Son port (GPL-2.0), where the dynamic stride of compute shaders, the present's wait for the screen's image and DLC from the player's packages came from.
- The players who reported problems in the [issues](https://github.com/HayatoG/iss_pc/issues), with logs that changed the port's course: jacckkss (#50, flickering lights and smoke), heyzerr (#51, #65, #67, CPUs without F16C and the RX 580), Andrade2244 (#29), MrRobot11214 (#31), fghacksr (#49), AngelHomura (#59) and aledieb93-svg (#81) (crashes on the RX 580 and on Windows), ViniSnapeS (#72) and kudetgaming-art (#75) (video memory), summer882 (#71), manymanyyyd-afk (#63) and Kpopping (#73) (Turkish and Russian), mahmoudmahran2112-crypto (#70, Quadro/Maxwell), Milicksp (#16), gsev3333 (#41) and everyone else who opened an issue or tested a build.

This project is not affiliated with Sony Interactive Entertainment or Sucker Punch Productions. inFAMOUS is a trademark of Sony Interactive Entertainment. No game code, files or art are distributed here. The icon is original artwork made for this project.

## Support development

If you would like to support the ports, [buy me a coffee](https://buymeacoffee.com/hayatog). Support is optional; the ports remain free.
