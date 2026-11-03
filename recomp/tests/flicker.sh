#!/usr/bin/env bash
# Flicker hunt: runs the game with autoplay taps, then at each time in AT dumps N consecutive
# frames (guest display buffer + presented image) and reports per-frame brightness and
# frame-to-frame differences.   tests/flicker.sh "120 200" [N] [button]
set -uo pipefail
cd -- "$(dirname -- "$0")/.."
AT=${1:-"150"}
N=${2:-40}
BUTTON=${3:-cross}
OUT=$PWD/work/flicker
mkdir -p "$OUT"
PY=${PY:-python3}
export TLG_PAD_FILE=$OUT/pad.txt TLG_DUMP_DIR=$OUT TLG_FRAME_DUMP_TRIGGER=$OUT/go TLG_FRAME_DUMP_COUNT=$N
: > "$TLG_PAD_FILE"
./run.sh "${@:4}" > "$OUT/log.txt" 2>&1 &
PID=$!
last=0
for at in $AT; do
    t=$last
    while (( t < at )) && kill -0 $PID 2>/dev/null; do
        sleep 5; t=$((t + 5))
        if (( t >= 40 && t % 10 == 0 )); then echo "$BUTTON" > "$TLG_PAD_FILE"; sleep 0.3; : > "$TLG_PAD_FILE"; fi
    done
    last=$t
    mkdir -p "$OUT/t$at"
    touch "$OUT/go"; sleep 8
    for f in "$OUT"/display_*.raw "$OUT"/output_*.raw; do [[ -e $f ]] && mv "$f" "$OUT/t$at/"; done
done
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
"$PY" - "$OUT" $AT <<'PYEOF'
import sys, glob, os, re
from PIL import Image, ImageStat, ImageChops
out = sys.argv[1]
for at in sys.argv[2:]:
    d = os.path.join(out, 't' + at)
    for kind in ('display', 'output'):
        files = sorted(glob.glob(os.path.join(d, kind + '_*.raw')))
        prev = None
        print(f'== t{at} {kind}: {len(files)} frames')
        for f in files:
            m = re.search(r'_(\d+)x(\d+)\.raw$', f)
            w, h = int(m.group(1)), int(m.group(2))
            b, g, r, _ = Image.frombytes('RGBA', (w, h), open(f, 'rb').read()).split()
            im = Image.merge('RGB', (r, g, b)).resize((480, 270))
            mean = sum(ImageStat.Stat(im).mean) / 3
            diff = sum(ImageStat.Stat(ImageChops.difference(im, prev)).mean) / 3 if prev else 0
            print(f'  {os.path.basename(f)} mean={mean:6.1f} diff_prev={diff:6.2f}')
            im.save(f[:-4] + '.png'); os.remove(f)
            prev = im
PYEOF
grep -E "STOP|FATAL|Assertion" "$OUT/log.txt" | head
