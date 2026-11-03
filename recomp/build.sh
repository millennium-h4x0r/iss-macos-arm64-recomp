#!/usr/bin/env bash
# Builds the Apple Silicon executable: recompiled guest code + recompiler runtime + the port's
# PS4 runtime (port/src) + the GPU library (port/gpu, built with CMake into work/gpu).
#   ./build.sh            incremental build of everything
#   ./build.sh runtime    only the runtime/link step (generated code objects reused)
set -euo pipefail
cd -- "$(dirname -- "$0")"
ROOT=$PWD
PORT=$ROOT/../port
WORK=$ROOT/work
GEN=$WORK/gen
OBJ=$WORK/obj
mkdir -p "$OBJ/gen" "$OBJ/rt" "$OBJ/port" "$OBJ/atrac9"
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
GEN_OPT=${GEN_OPT:--O1}
PKGS="vulkan sdl3 libavcodec libavutil libswscale libavformat libswresample freetype2"
read -r -a PKG_CFLAGS <<< "$(pkg-config --cflags $PKGS)"
read -r -a PKG_LIBS <<< "$(pkg-config --libs $PKGS)"
COMPAT="-include $ROOT/rt/compat_include/darwin_linux_compat.h"
CFLAGS_RT=(-std=gnu11 -O2 -g -I"$ROOT/rt" -I"$ROOT/third_party/simde" -I"$GEN" -Wall -Wno-unused-function)
CFLAGS_PORT=(-std=gnu11 -O2 -g -DTLG_RECOMP=1 -D_DARWIN_C_SOURCE -D_XOPEN_SOURCE=700 $COMPAT -I"$PORT" -I"$PORT/src" -I"$ROOT/rt"
             -I"$ROOT/third_party/simde" -I"$ROOT/rt/compat_include" "${PKG_CFLAGS[@]}" -Wno-deprecated-declarations)

# objects older than any runtime header are rebuilt (no per-file dependency tracking)
NEWEST_HDR=$(ls -t "$ROOT"/rt/*.h "$ROOT"/rt/compat_include/*.h "$PORT"/src/*.h | head -1)
export NEWEST_HDR
compile() { # src obj flags...
    local src=$1 obj=$2; shift 2
    if [[ ! -f $obj || $src -nt $obj || $NEWEST_HDR -nt $obj || ${FORCE:-} == 1 ]]; then
        echo "  cc $(basename "$src")"
        clang "$@" -c "$src" -o "$obj"
    fi
}
export -f compile

# 1. generated guest code (parallel); objects of chunks that no longer exist are removed
for o in "$OBJ"/gen/*.o; do [[ -e $o ]] || continue; [[ -f $GEN/$(basename "$o" .o).c ]] || rm -f "$o"; done
if [[ ${1:-} != runtime ]]; then
    ls "$GEN"/f*.c "$GEN"/table.c | xargs -P "$JOBS" -I{} bash -c \
        'compile "$1" "$2/$(basename "$1" .c).o" -std=gnu11 '"$GEN_OPT"' -g0 -I'"$ROOT"'/rt -I'"$ROOT"'/third_party/simde -I'"$GEN"' -Wno-parentheses-equality -Wno-pass-failed -w' _ {} "$OBJ/gen"
fi
# 2. recompiler runtime
for s in "$ROOT"/rt/*.c; do compile "$s" "$OBJ/rt/$(basename "$s" .c).o" "${CFLAGS_RT[@]}" "${PKG_CFLAGS[@]}" -I"$PORT" -I"$PORT/src" -DTLG_RECOMP=1; done
compile "$ROOT/rt/hostcall.S" "$OBJ/rt/hostcall.o"
compile "$ROOT/rt/guest_reserve.S" "$OBJ/rt/guest_reserve.o"
# 3. the port's PS4 runtime
for s in "$PORT"/src/runtime*.c; do compile "$s" "$OBJ/port/$(basename "$s" .c).o" "${CFLAGS_PORT[@]}"; done
for s in "$PORT"/third_party/LibAtrac9/C/src/*.c; do compile "$s" "$OBJ/atrac9/$(basename "$s" .c).o" -std=c99 -O2 -w; done
# 4. GPU library (TLG_METAL=1: the native Metal renderer, built into work/gpu-metal and linked
#    as work/iss-recomp-metal)
GPU=$WORK/gpu; EXE=$WORK/iss-recomp; METAL_FLAG=OFF; EXTRA_LIBS=()
if [[ ${TLG_METAL:-0} == 1 ]]; then
    GPU=$WORK/gpu-metal; EXE=$WORK/iss-recomp-metal; METAL_FLAG=ON
    EXTRA_LIBS=(-lspirv-cross-msl -lspirv-cross-glsl -lspirv-cross-core)
fi
if [[ ! -f $GPU/build.ninja ]]; then
    cmake -S "$PORT/gpu" -B "$GPU" -G Ninja -DCMAKE_BUILD_TYPE=Release -DTLG_LTO=OFF -DTLG_METAL=$METAL_FLAG \
        -DCMAKE_PREFIX_PATH=/opt/homebrew -DVMA_INCLUDE_DIR="$ROOT/third_party/vma/include" >/dev/null
fi
ninja -C "$GPU" tlggpu > "$GPU-build.log" 2>&1 || { grep -E "error|FAILED" "$GPU-build.log" | head -30; exit 1; }
# 5. link
GPU_LIBS=("$GPU/libtlggpu.a")
while IFS= read -r lib; do GPU_LIBS+=("$lib"); done < <(find "$GPU" -name '*.a' ! -name libtlggpu.a)
echo "  link $(basename "$EXE")"
clang++ -o "$EXE" "$OBJ"/gen/*.o "$OBJ"/rt/*.o "$OBJ"/port/*.o "$OBJ"/atrac9/*.o \
    -Wl,-force_load,"$GPU/libtlggpu.a" "${GPU_LIBS[@]:1}" \
    -L/opt/homebrew/lib "${EXTRA_LIBS[@]}" -lfmt -lZydis -lxxhash "${PKG_LIBS[@]}" \
    -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreGraphics -framework Foundation -framework IOKit -framework CoreFoundation \
    -Wl,-stack_size,0x4000000 -Wl,-segaddr,__TLGUSER,0x7000000000 -Wl,-segaddr,__TLGEND,0xfe00000000
echo "Built $EXE"
