#!/usr/bin/env bash
# Unattended smoke test: runs the game, taps a button every few seconds (TLG_PAD_FILE) and dumps
# the displayed frame periodically (TLG_FRAME_DUMP_TRIGGER), converted to PNG in work/auto/.
#   tests/autoplay.sh [seconds] [button]
set -uo pipefail
cd -- "$(dirname -- "$0")/.."
SECONDS_TOTAL=${1:-240}
BUTTON=${2:-cross}
OUT=$PWD/work/auto
mkdir -p "$OUT"
PY=${PY:-python3}
export TLG_PAD_FILE=$OUT/pad.txt TLG_DUMP_DIR=$OUT TLG_FRAME_DUMP_TRIGGER=$OUT/go TLG_FRAME_DUMP_COUNT=1
: > "$TLG_PAD_FILE"
./run.sh > "$OUT/log.txt" 2>&1 &
PID=$!
t=0
while (( t < SECONDS_TOTAL )) && kill -0 $PID 2>/dev/null; do
    sleep 10; t=$((t + 10))
    if (( t >= 40 )); then echo "$BUTTON" > "$TLG_PAD_FILE"; sleep 0.3; : > "$TLG_PAD_FILE"; fi
    if (( t % 20 == 0 )); then touch "$OUT/go"; sleep 2; for f in "$OUT"/display_*.raw; do [[ -e $f ]] && mv "$f" "$OUT/frame_t$(printf %04d $t).raw"; done; rm -f "$OUT"/output_*.raw; fi
done
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
"$PY" - "$OUT" <<'EOF'
import sys, glob, os
from PIL import Image
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'frame_t*.raw'))):
    b, g, r, _ = Image.frombytes('RGBA', (1920, 1080), open(f, 'rb').read()).split()
    im = Image.merge('RGB', (r, g, b))  # the display image is BGRA
    im.resize((640, 360)).save(f[:-4] + '.png'); os.remove(f)
    print(os.path.basename(f), im.getbbox())
EOF
grep -E "STOP|FATAL|Assertion" "$OUT/log.txt" | head
