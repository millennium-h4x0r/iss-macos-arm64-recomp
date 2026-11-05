#!/usr/bin/env bash
# Installs the game as an app ("/Applications/inFAMOUS Second Son.app" by default), started
# from Finder, Launchpad or Spotlight like any other app. The app holds a copy of the built
# binary and a launcher; the game files, saves and settings stay where run.sh has them
# (work/user, work/tlg.ini), and its output goes to work/game.log.
#   ./install-app.sh [--vulkan] [destination.app]
# Metal build (TLG_METAL=1 ./build.sh runtime) by default; --vulkan installs the Vulkan one.
# Run it again after a rebuild (the app keeps its own copy of the binary).
set -euo pipefail
cd -- "$(dirname -- "$0")"
ROOT=$PWD
WORK=$ROOT/work
METAL=1
if [[ ${1:-} == --vulkan ]]; then METAL=0; shift; fi
if (( METAL )); then
    SRC=$WORK/iss-recomp-metal; NAME="inFAMOUS Second Son"; ID=local.iss-recomp.app
else
    SRC=$WORK/iss-recomp; NAME="inFAMOUS Second Son (Vulkan)"; ID=local.iss-recomp.app.vulkan
fi
APP=${1:-/Applications/$NAME.app}
GAME=${ISS_GAME_DIR:-$ROOT/../../CUSA00004[Infamous Second Son]/extracted/uroot}
[[ -x $SRC ]] || { echo "No $SRC: build it first (see README)" >&2; exit 1; }
[[ -f $WORK/out/boot-linked.bin ]] || { echo "Run ./run.sh once first (it prepares work/out)" >&2; exit 1; }
# Never replace the binary of a running game.
if pgrep -f "^$APP/Contents/MacOS/iss-recomp" >/dev/null; then
    echo "$APP is running: quit the game first" >&2; exit 1
fi
# The WindowServer guard run.sh starts next to the game.
if [[ ! -x $WORK/wsguard || $ROOT/tests/wsguard.swift -nt $WORK/wsguard ]]; then
    swiftc -O "$ROOT/tests/wsguard.swift" -o "$WORK/wsguard"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STAGE=$TMP/$NAME.app
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$SRC" "$STAGE/Contents/MacOS/iss-recomp"
cat > "$STAGE/Contents/Resources/launcher" <<LAUNCH
#!/bin/bash
# Written by install-app.sh: starts the game through run.sh (its environment and arguments).
export ISS_APP_BIN="\$(cd "\$(dirname "\$0")/../MacOS" && pwd)/iss-recomp"
export ISS_METAL=$METAL
exec "$ROOT/run.sh" "\$@"
LAUNCH
chmod +x "$STAGE/Contents/Resources/launcher"

# Icon: the game's own (sce_sys/icon0.png).
ICON=$GAME/sce_sys/icon0.png
if [[ -f $ICON ]]; then
    SET=$TMP/AppIcon.iconset
    mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON" --out "$SET/icon_${s}x${s}.png" >/dev/null
        d=$(( s * 2 ))
        if (( d <= 512 )); then sips -z $d $d "$ICON" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
        else cp "$ICON" "$SET/icon_${s}x${s}@2x.png"; fi
    done
    iconutil -c icns "$SET" -o "$STAGE/Contents/Resources/AppIcon.icns"
fi

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>iss-recomp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.07</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
    <key>GCSupportsGameMode</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$STAGE" >/dev/null

# Replace the installed app (a new binary file: the kernel caches code signatures by file).
rm -rf "$APP"
mv "$STAGE" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "Installed $APP"
