#!/usr/bin/env bash
# Plays the game with simulated controller input (TLG_PAD_FILE) under the WindowServer guard,
# logging FPS, GPU utilization and memory every 10 s and dumping a frame every 10 s.
#   tests/play.sh <route> [seconds] [save]
# route: opening  - fresh start: skip cutscenes, tilt/shake the spray can, spray (L2)
#        intro    - fresh start: Continue at the title, then the intro movie with no input
#        mural    - fresh start: as opening up to the spray can, then the player's recording of
#                   the mural (work/routes/spray-mural.txt, F9 in the installed app), then the
#                   video after it untouched
#        explore  - free roaming: walk, sweep the camera, jump, climb, melee, interact
# save:  fresh (no save: starts at the beginning), keep (whatever work/user has), or a
#        folder name under work/saves (copied in; e.g. cannery-escape). Default: fresh for
#        opening, cannery-escape for explore. The player's own save is moved aside and put
#        back afterwards.
# Output: work/play/<route>/ (log.txt, stats.txt, frame_t*.png, fps.txt).
set -uo pipefail
cd -- "$(dirname -- "$0")/.."
ROUTE=${1:?route: opening|explore}
TOTAL=${2:-240}
case $ROUTE in opening|intro|mural) DEFSAVE=fresh ;; *) DEFSAVE=cannery-escape ;; esac
SAVE=${3:-$DEFSAVE}
WORK=$PWD/work
OUT=$WORK/play/$ROUTE
PY=${PY:-python3}
DUMP_EVERY=${DUMP_EVERY:-10}   # seconds between frame dumps
# DUMP_COUNT=<n>: consecutive frames per dump (frame_t<sec>_<index>.png when above 1)
# DUMP_FROM=<sec>: no dumps before then
mkdir -p "$OUT"
rm -f "$OUT"/frame_t*.png "$OUT"/*.raw "$OUT"/fps.txt

# The installed app runs as iss-recomp too: this script swaps the save folder and kills that
# process name at the end, so never run it while the player's game is open.
if pgrep -x iss-recomp >/dev/null; then echo "play.sh: the game is running (iss-recomp); quit it first" >&2; exit 1; fi

# Save fixture
SAVES=$WORK/user/savedata
STASH=
if [[ $SAVE != keep ]]; then
    if [[ -d $SAVES ]]; then STASH=$WORK/saves/.stash-$$; mv "$SAVES" "$STASH"; fi
    if [[ $SAVE != fresh ]]; then cp -R "$WORK/saves/$SAVE" "$SAVES"; fi
fi
restore_save() {
    [[ $SAVE == keep ]] && return
    rm -rf "$SAVES"
    [[ -n $STASH ]] && mv "$STASH" "$SAVES"
}
trap 'pkill -x iss-recomp; pkill -9 -x iss-recomp-metal; restore_save; exit 1' INT TERM

export TLG_PAD_FILE=$OUT/pad.txt TLG_DUMP_DIR=$OUT TLG_FRAME_DUMP_TRIGGER=$OUT/go TLG_FRAME_DUMP_COUNT=${DUMP_COUNT:-1}
export TLG_PERF_FRAMES=1
[[ $ROUTE == mural ]] && export TLG_PAD_REPLAY=${TLG_PAD_REPLAY:-$WORK/routes/spray-mural.txt}
: > "$TLG_PAD_FILE"
: > "$OUT/stats.txt"
touch "$OUT/.started"   # only perf traces newer than this belong to this run
pad() { echo "$*" > "$TLG_PAD_FILE"; }
tap() { pad "$@"; sleep 0.25; pad; }

./run.sh > "$OUT/log.txt" 2>&1 &
PID=$!

# Route steps: called about every 0.5 s with the elapsed time.
step_opening() {
    local t=$1
    if (( t >= 40 && t < 70 )); then tap cross
    elif (( t >= 70 && t < 100 )); then pad tilt_right
    elif (( t >= 100 && t < 160 )); then pad tilt_right shake
    elif (( t >= 160 )); then
        # the mural: spray (L2) with the can on its side, the aim sweeping rows across the
        # stencil (aim=<yaw>,<pitch> degrees, a 4-degree grid), shaking for a second every 15 s
        local k=$(( t - 160 )) row yaw off
        off=$(( (k / 117) % 2 * 2 ))   # every other pass half a step over: fills the gaps
        row=$(( (k / 13) % 9 )); yaw=$(( (k % 13) * 4 - 24 ))
        (( (k / 13) % 2 )) && yaw=$(( -yaw ))
        if (( k % 15 == 14 )); then pad tilt_right shake aim=$(( yaw + off )),$(( 16 - row * 4 - off ))
        else pad l2 tilt_right aim=$(( yaw + off )),$(( 16 - row * 4 - off )); fi
    fi
}
step_mural() {   # Continue at the title, then the recorded mural from the spray can's first prompt
    local t=$1
    # The cutscenes play to the "hold the controller sideways" prompt (~150 s); the game waits
    # there, so the replay starts a little after it (MURAL_AT). Once: a finished replay restarts.
    local at=${MURAL_AT:-156}
    if (( t >= 40 && t < 70 )); then tap cross
    elif (( t >= at && t < at + 2 )); then pad replay
    elif (( t >= 70 )); then pad; fi
}
step_intro() {   # press Continue once at the title, then watch the intro movie untouched
    local t=$1
    if (( t >= 42 && t < 44 )); then tap cross; fi
}
step_dash() {    # smoke dash: run forward holding circle in 3 s bursts (Delsin's particle form)
    local t=$1
    (( t < ${DASH_FROM:-22} )) && return
    if (( t % 4 < 3 )); then pad ly=0 circle rx=$(( 128 + (t % 8 - 4) * 6 )); else pad; fi
}
step_idle() {    # no input at all: a fixed view of where the save loads (A/B frame comparisons)
    pad
}
step_roam() {    # open-world running (Seattle): long runs with slow turns, jumps and dashes,
    local t=$1    # a full camera turn every 32 s, so new areas (new shaders) keep coming into view
    (( t < 35 )) && { (( t > 20 )) && tap cross; return; }
    local k=$(( t % 32 ))
    if (( k < 12 )); then pad ly=0 rx=$(( 128 + 30 ))
    elif (( k < 14 )); then pad ly=0 cross
    elif (( k < 20 )); then pad ly=0 circle rx=$(( 128 - 20 ))
    elif (( k < 24 )); then pad ly=0 rx=255
    elif (( k < 26 )); then pad ly=0 ry=60
    else pad ly=0 lx=200 rx=$(( 128 + 10 )); fi
}
step_explore() {
    local t=$1
    (( t < 35 )) && { (( t > 20 )) && tap cross; return; }   # load, skip any cutscene
    local phase=$(( (t / 4) % 8 ))
    case $phase in
        0|1) pad ly=0 rx=$(( 128 + ((t % 8) - 4) * 12 )) ;;             # run forward, small turns
        2)   pad ly=0 cross ;;                                           # jump / climb while running
        3)   pad lx=255 ly=40 rx=200 ;;                                  # strafe right, turn
        4)   pad ly=0 ry=90 ;;                                           # forward, look up
        5)   tap square ;;                                               # melee
        6)   pad lx=0 ly=60 rx=40 ;;                                     # strafe left, turn left
        7)   tap triangle ;;                                             # interact
    esac
}

start=$(date +%s); last=-1
while kill -0 $PID 2>/dev/null; do
    now=$(( $(date +%s) - start )); (( now >= TOTAL )) && break
    step_$ROUTE $now
    if (( now / DUMP_EVERY != last && now >= ${DUMP_FROM:-0} )); then
        last=$(( now / DUMP_EVERY ))
        stats=$(ioreg -r -d 1 -c IOAccelerator | tr ',' '\n')
        util=$(grep -o '"Device Utilization %"=[0-9]*' <<<"$stats" | head -1 | cut -d= -f2)
        mem=$(grep -o '"In use system memory"=[0-9]*' <<<"$stats" | head -1 | cut -d= -f2)
        echo "t=$now gpu_util=${util:-?}% gpu_mem_MB=$(( ${mem:-0} / 1048576 ))" >> "$OUT/stats.txt"
        touch "$OUT/go"
    fi
    for f in "$OUT"/display_*.raw; do
        [[ -e $f ]] || continue
        if [[ ${DUMP_COUNT:-1} == 1 ]]; then mv "$f" "$OUT/frame_t$(printf %04d $now).raw"
        else idx=${f##*/display_}; mv "$f" "$OUT/frame_t$(printf %04d $now)_${idx%%_*}.raw"; fi
    done
    rm -f "$OUT"/output_*.raw
    sleep 0.5
done
pkill -x iss-recomp; sleep 3; kill $PID 2>/dev/null
# The Metal test build (ISS_RAW_BINARY=1) runs unbundled under its own name.
pkill -9 -x iss-recomp-metal 2>/dev/null
restore_save

"$PY" - "$OUT" "$WORK/user/perf-traces" "$OUT/.started" <<'PYEOF'
import sys, glob, os, csv, math
out, traces = sys.argv[1], sys.argv[2]
try:
    from PIL import Image
    for f in sorted(glob.glob(os.path.join(out, 'frame_t*.raw'))):
        data = open(f, 'rb').read()
        h = round(math.sqrt(len(data) // 4 * 9 / 16)); w = len(data) // 4 // h   # 16:9 dumps
        b, g, r, _ = Image.frombytes('RGBA', (w, h), data).split()
        im = Image.merge('RGB', (r, g, b))
        if not os.environ.get('FULL_FRAMES'): im = im.resize((640, 360))   # FULL_FRAMES=1 keeps full size
        im.save(f[:-4] + '.png'); os.remove(f)
except ImportError:
    pass
started = os.path.getmtime(sys.argv[3])
sessions = sorted((s for s in glob.glob(os.path.join(traces, 'session-*'))
                   if os.path.getmtime(s) >= started), key=os.path.getmtime)
if sessions:
    rows = []
    for x in csv.DictReader(open(os.path.join(sessions[-1], 'frames.csv'))):
        try: rows.append((int(x['ts_ns']), int(x['interval_ns'])))
        except (ValueError, KeyError, TypeError): pass
    if rows:
        t0 = rows[0][0]; b = {}
        for ts, iv in rows: b.setdefault((ts - t0) // 10**10, []).append(iv)
        with open(os.path.join(out, 'fps.txt'), 'w') as fo:
            for k, v in sorted(b.items()):
                v.sort()
                fo.write(f"{k*10:4d}s fps={len(v)/10:5.1f} median={v[len(v)//2]/1e6:6.1f}ms "
                         f"p95={v[int(len(v)*.95)]/1e6:7.1f}ms\n")
PYEOF
cat "$OUT/stats.txt"; cat "$OUT/fps.txt" 2>/dev/null | tail -20
grep -E "wsguard:|KK GPU watchdog|STOP|FATAL|Assertion" "$OUT/log.txt" | head
