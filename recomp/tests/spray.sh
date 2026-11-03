#!/usr/bin/env bash
# Drives the opening into the graffiti (spray can) step under a WindowServer guard: if a
# CGWindowList query (tests/wsping) takes over 4 s, the game is killed before WindowServer's
# 40 s watchdog fires. Logs GPU memory and dumps a frame every 10 s to work/spray/.
#   tests/spray.sh [seconds]
set -uo pipefail
cd -- "$(dirname -- "$0")/.."
TOTAL=${1:-240}
OUT=$PWD/work/spray
mkdir -p "$OUT"
WSPING=${WSPING:-$PWD/work/wsping}
[[ -x $WSPING ]] || swiftc -O tests/wsping.swift -o "$WSPING"
export TLG_PAD_FILE=$OUT/pad.txt TLG_DUMP_DIR=$OUT TLG_FRAME_DUMP_TRIGGER=$OUT/go TLG_FRAME_DUMP_COUNT=1
: > "$TLG_PAD_FILE"
: > "$OUT/guard.txt"
./run.sh > "$OUT/log.txt" 2>&1 &
PID=$!
pad() { echo "$*" > "$TLG_PAD_FILE"; }
start=$(date +%s); last_step=-1
while kill -0 $PID 2>/dev/null; do
    now=$(( $(date +%s) - start )); (( now >= TOTAL )) && break
    # WindowServer guard
    "$WSPING" > "$OUT/ws.txt" 2>&1 & WP=$!
    for _ in 1 2 3 4 5 6 7 8; do kill -0 $WP 2>/dev/null || break; sleep 0.5; done
    if kill -0 $WP 2>/dev/null; then
        # run.sh's wsguard pauses the game; killing it would tear down its GPU memory under
        # the stalled kernel lock and make things worse.
        echo "t=$now WindowServer slow (>4 s); wsguard should have paused the game" | tee -a "$OUT/guard.txt"
        wait $WP 2>/dev/null
    fi
    step=$(( now / 10 ))
    if (( step != last_step )); then
        last_step=$step
        mem=$(ioreg -r -d 1 -c IOAccelerator | grep -o '"In use system memory"=[0-9]*' | head -1 | cut -d= -f2)
        echo "t=$now ws=$(cut -d' ' -f1 "$OUT/ws.txt") gpu_in_use_MB=$(( ${mem:-0} / 1048576 ))" | tee -a "$OUT/guard.txt"
        # route: cross until the billboard, hold sideways, shake, then spray (L2) while aiming
        if (( now >= 40 && now < 70 )); then pad cross; sleep 0.3; pad
        elif (( now >= 70 && now < 100 )); then pad tilt_right
        elif (( now >= 100 && now < 160 )); then pad tilt_right shake
        elif (( now >= 160 )); then pad l2 rx=$(( 64 + (now * 37) % 128 )) ry=$(( 64 + (now * 23) % 128 ))
        fi
        touch "$OUT/go"
    fi
    sleep 1
    for f in "$OUT"/display_*.raw; do [[ -e $f ]] && mv "$f" "$OUT/frame_t$(printf %04d $now).raw"; done
    rm -f "$OUT"/output_*.raw
done
kill $PID 2>/dev/null; sleep 2; pkill -x iss-recomp 2>/dev/null; sleep 2; kill -9 $PID 2>/dev/null
"${PY:-python3}" - "$OUT" <<'PYEOF'
import sys, glob, os
from PIL import Image
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'frame_t*.raw'))):
    b, g, r, _ = Image.frombytes('RGBA', (1920, 1080), open(f, 'rb').read()).split()
    Image.merge('RGB', (r, g, b)).resize((640, 360)).save(f[:-4] + '.png'); os.remove(f)
PYEOF
grep -E "STOP|FATAL|Assertion|Recomp:" "$OUT/log.txt" | head
