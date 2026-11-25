#!/bin/sh
# Build the iOS app of one game (COLO_GAME=xd or colosseum) from a checkout of the port in ./port with
# patches/*.patch applied, on a Mac with Xcode (the iOS 27.1 SDK or newer). Writes build/<Name>.ipa: unsigned (ad-hoc),
# for a sideloader to sign. No game files are used or included: the app reads the disc from its own folder.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "${COLO_GAME:=colosseum}" in
    xd) NAME="Pokemon XD"; EXE=xd; BUNDLE_ID=com.xdios.xd; DECOMP_DIR=pkmn-xd ;;
    *)  NAME="Pokemon Colosseum"; EXE=colosseum; BUNDLE_ID=com.xdios.colosseum; DECOMP_DIR=pkmn-colosseum ;;
esac
IOS_MIN=${COLO_IOS_MIN:-17.0}
cd "$ROOT/port"
export COLO_PORT="$PWD" SMS_PORT="$PWD/deps/sms-pc-port" DECOMP="$PWD/deps/$DECOMP_DIR"
. tools/env.sh

echo "== game code (the same objects as the Mac build)"
mkdir -p build "$GB"
$PY -I tools/cflags.py
if [ "$COLO_GAME" = xd ]; then
    [ -f "$DECOMP/objdiff.json" ] || (cd "$DECOMP" && $PY configure.py > /dev/null)
else
    [ -f "$DECOMP/build.ninja" ] || (cd "$DECOMP" && $PY configure.py > /dev/null)
    $PY -I tools/colo-tools/manifest.py "$DECOMP" manifest.json > /dev/null
fi
$PY -I tools/symbols.py "$DECOMP/config/$GAME_ID" "$GB/syms_main.json" $([ "$COLO_GAME" = xd ] && echo --cxx)
[ "$COLO_GAME" = xd ] || $PY -I tools/rels.py > /dev/null
$PY -I tools/units.py > /dev/null
$PY -I tools/unit_cache.py id
$PY -I tools/decomp_patch.py apply
$PY -I tools/gen_build.py
ninja -C "$GB" -f build.ninja -j"$JOBS" game
$PY -I tools/check_calls.py

echo "== SDL2 for iOS (with UIKit scenes: ios/sdl2-scenes.patch)"
SDL_SRC=$PWD/build/ios-deps/SDL
if [ ! -d "$SDL_SRC" ]; then
    mkdir -p build/ios-deps
    git clone -q --depth 1 -b release-2.32.10 https://github.com/libsdl-org/SDL.git "$SDL_SRC"
    git -C "$SDL_SRC" apply "$ROOT/ios/sdl2-scenes.patch"
fi
SDL_OUT=$PWD/build/ios-deps/sdl-install
cmake -G Ninja -S "$SDL_SRC" -B build/ios-deps/sdl-build -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" -DCMAKE_BUILD_TYPE=Release -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF \
    -DSDL2_DISABLE_SDL2MAIN=ON -DCMAKE_INSTALL_PREFIX="$SDL_OUT" > /dev/null
cmake --build build/ios-deps/sdl-build
cmake --install build/ios-deps/sdl-build > /dev/null
export COLO_IOS_SDL="$SDL_OUT"

echo "== the renderer for iOS"
# (Vulkan is built too, as the Metal backend needs its shader compiler; with no Vulkan on iOS it never starts)
cmake -G Ninja -S ext/sms_gx -B build/sms_gx -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DSMS_GX_BUILD_TESTS=OFF \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DSDL2_DIR="$SDL_OUT/lib/cmake/SDL2"
ninja -C build/sms_gx -j"$JOBS" -k 0   # (-k 0: every error at once)

echo "== the app"
COLO_IOS=1 COLO_IOS_MIN="$IOS_MIN" $PY -I tools/link.py
APP=$ROOT/build/Payload/$EXE.app
rm -rf "$ROOT/build/Payload"; mkdir -p "$APP"
cp "build/$EXE" "$APP/$EXE"
sed -e "s|@NAME@|$NAME|g" -e "s|@EXE@|$EXE|g" -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@IOS_MIN@|$IOS_MIN|g" \
    -e "s|@SDK@|$(xcrun --sdk iphoneos --show-sdk-version)|g" "$ROOT/ios/Info.plist.in" > "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
cp bindings.txt "$APP/" 2>/dev/null || true
codesign -f -s - --entitlements "$ROOT/ios/entitlements.plist" "$APP"
(cd "$ROOT/build" && rm -f "$EXE.ipa" && zip -qry "$EXE.ipa" Payload)
ls -la "$ROOT/build/$EXE.ipa"
