#!/usr/bin/env bash
# Runs the recompiled game on Apple Silicon.
#   ISS_GAME_DIR=<dump>  (default: ../../CUSA00004[Infamous Second Son]/extracted/uroot)
#   ./run.sh [--cpu-only] [loader options]
set -euo pipefail
cd -- "$(dirname -- "$0")"
ROOT=$PWD
PORT=$ROOT/../port
WORK=$ROOT/work
OUT=$WORK/out
GAME=${ISS_GAME_DIR:-$ROOT/../../CUSA00004[Infamous Second Son]/extracted/uroot}
[[ -f $GAME/eboot.bin ]] || { echo "No eboot.bin in $GAME (set ISS_GAME_DIR)" >&2; exit 1; }
mkdir -p "$OUT" "$WORK/user"
if [[ ! -f $OUT/boot-linked.bin ]]; then
    python3 "$PORT/scripts/prepare.py" "$GAME" --out "$OUT"
    python3 "$PORT/scripts/link_libc.py" "$GAME" --out "$OUT"
    python3 "$PORT/scripts/link_modules.py" "$GAME" --out "$OUT"
fi
[[ -f $OUT/content.bin ]] || python3 "$PORT/scripts/content_profile.py" "$GAME" --out "$OUT" --sku full
# Vulkan driver: shadPS4's KosmicKrisp build (sparse buffers, geometry shaders; README), else
# Homebrew Mesa's KosmicKrisp, else MoltenVK.
if [[ -z ${VK_DRIVER_FILES:-} && -z ${VK_ICD_FILENAMES:-} ]]; then
    for icd in "$ROOT/../../mesa-kosmickrisp/build/outputs/kosmickrisp_mesa_icd.json" \
               /opt/homebrew/opt/mesa/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json \
               /opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json /opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json; do
        [[ -f $icd ]] && { export VK_DRIVER_FILES=$icd; break; }
    done
fi
export TLG_CONFIG=${TLG_CONFIG:-$WORK/tlg.ini}
export TLG_VBLANK_HZ=${TLG_VBLANK_HZ:-60}
# Unified memory: the GPU reads and writes the game's own memory (Apple Silicon is unified), so
# CPU reads of GPU results need no download. Without it, ~80 reads/s each drained the whole GPU
# (Scheduler::Finish) on the draw recording thread. The range is the game's direct memory heaps
# (PS4 0x1048000000.., relocated by +0x6000000000 here). TLG_UNIFIED_MEMORY=0 turns it off.
export TLG_UNIFIED_MEMORY=${TLG_UNIFIED_MEMORY:-1}
export TLG_UNIFIED_RANGE=${TLG_UNIFIED_RANGE:-0x7048000000:0xc0000000}
# Shader math: the recompiler marks every float add/mul NoContraction and asks for signed
# zero/inf/nan preservation, and KosmicKrisp then wraps them in Metal's "safe" math mode, guards
# every multiply and makes every buffer access coherent. Without those (TLG_FAST_FP=1 and KK
# workarounds 6, 14, 17 off) the cannery went from ~24 to ~30 FPS (the 60 Hz vblank cap) with no
# visible difference. ISS_STRICT_SHADERS=1 restores the exact behaviour.
if [[ ${ISS_STRICT_SHADERS:-0} != 1 ]]; then
    # TLG_FAST_FP=1 (no NoContraction, no inf/nan preserve) breaks Delsin's vest: off.
    export TLG_FAST_FP=${TLG_FAST_FP:-0}
    export MESA_KK_DISABLE_WORKAROUNDS=${MESA_KK_DISABLE_WORKAROUNDS:-6,14,17}
fi
GUARD=$WORK/wsguard
if [[ ${ISS_WSGUARD:-1} != 0 && ( ! -x $GUARD || $ROOT/tests/wsguard.swift -nt $GUARD ) ]]; then
    swiftc -O "$ROOT/tests/wsguard.swift" -o "$GUARD" || echo "run.sh: could not build wsguard" >&2
fi
# Started by the app that install-app.sh puts in /Applications (its launcher sets
# ISS_APP_BIN to the binary inside it): this process becomes the game, so macOS sees that app
# (its icon, Game Mode). Output goes to work/game.log.
if [[ -n ${ISS_APP_BIN:-} ]]; then
    cd "$WORK"
    # F9 starts and stops a pad recording (with the motion: the spray can) for scripted tests.
    export TLG_PAD_RECORD=${TLG_PAD_RECORD:-$WORK/pad-recording.txt}
    exec >"$WORK/game.log" 2>&1
    if [[ ${ISS_WSGUARD:-1} != 0 && -x $GUARD ]]; then
        "$GUARD" $$ "$WORK/wsguard.log" &
    fi
    exec "$ISS_APP_BIN" "$OUT/boot-linked.bin" --content-profile "$OUT/content.bin" --app0 "$GAME" \
        --user "$WORK/user" "$@"
fi
# Run from an app bundle: an unbundled binary is a background process to macOS
# (RunningBoard "anon<...> running-NotVisible"), whose GPU memory gets evicted and paged
# back in under the kernel GPU lock (a desktop-wide freeze), and which gets no Game Mode.
# ISS_METAL=1: the native Metal renderer build (TLG_METAL=1 ./build.sh), its own bundle.
SRC_BIN=$WORK/iss-recomp
APP=$WORK/inFAMOUS.app
if [[ ${ISS_METAL:-0} == 1 ]]; then SRC_BIN=$WORK/iss-recomp-metal; APP=$WORK/inFAMOUS-metal.app; fi
BIN=$APP/Contents/MacOS/iss-recomp
if [[ ! -x $BIN || ! -x $APP/Contents/MacOS/inFAMOUS || $SRC_BIN -nt $BIN || $ROOT/run.sh -nt $APP/Contents/Info.plist ]]; then
    mkdir -p "$APP/Contents/MacOS"
    # A new file, not an overwrite: the kernel keeps the old file's code signature (SIGKILL,
    # "Code Signature Invalid").
    rm -f "$BIN"
    cp "$SRC_BIN" "$BIN"
    # open starts apps in /; the game resolves paths against its working directory.
    printf '#!/bin/sh\ncd "${ISS_CWD:-$(dirname "$0")/../../..}" && exec "$(dirname "$0")/iss-recomp" "$@"\n' \
        > "$APP/Contents/MacOS/inFAMOUS"
    chmod +x "$APP/Contents/MacOS/inFAMOUS"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.iss-recomp</string>
    <key>CFBundleName</key><string>inFAMOUS</string>
    <key>CFBundleExecutable</key><string>inFAMOUS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
    <key>GCSupportsGameMode</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
    codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "run.sh: ad-hoc signing failed" >&2
fi
cd "$WORK"
ARGS=("$OUT/boot-linked.bin" --content-profile "$OUT/content.bin" --app0 "$GAME" --user "$WORK/user" "$@")
# ISS_DIRECT=1 runs the binary directly (debuggers, sample); macOS then treats it as a
# background process (see above).
if [[ ${ISS_DIRECT:-0} == 1 ]]; then
    exec "$BIN" "${ARGS[@]}"
fi
# ISS_RAW_BINARY=1: the build output itself, unbundled (short tests; see ISS_DIRECT).
if [[ ${ISS_RAW_BINARY:-0} == 1 ]]; then
    exec "$SRC_BIN" "${ARGS[@]}"
fi
# Launched through LaunchServices (open), which gives the process its app identity.
# open starts it with a clean environment, so pass ours through; output goes to a log
# that is echoed here.
LOG=$WORK/game.log
: > "$LOG"
ENVS=()
while IFS= read -r v; do ENVS+=(--env "$v"); done < <(env | grep -E "^(TLG_|KK_|VK_|ISS_|MESA_|MVK_|MTL_|DYLD_)")
ENVS+=(--env "HOME=$HOME" --env "ISS_CWD=$WORK")
open -n -W -a "$APP" --stdout "$LOG" --stderr "$LOG" "${ENVS[@]}" --args "${ARGS[@]}" &
OPEN_PID=$!
tail -n +1 -f "$LOG" &
TAIL_PID=$!
GAME_PID=
for _ in $(seq 1 100); do
    GAME_PID=$(pgrep -n -f "^$BIN") && break
    sleep 0.1
done
trap '[[ -n $GAME_PID ]] && { kill -CONT $GAME_PID; kill $GAME_PID; } 2>/dev/null; exit 130' INT TERM
trap 'kill $TAIL_PID 2>/dev/null' EXIT
# WindowServer guard (tests/wsguard.swift): pauses the game while WindowServer stops
# answering, so a GPU-lock stall cannot run into WindowServer's 40 s watchdog (which ends
# the desktop session). ISS_WSGUARD=0 disables it.
if [[ -n $GAME_PID && ${ISS_WSGUARD:-1} != 0 && -x $GUARD ]]; then
    "$GUARD" "$GAME_PID" "$WORK/wsguard.log" &
fi
wait $OPEN_PID
