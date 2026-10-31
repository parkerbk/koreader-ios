#!/bin/bash
# Runs a build on an iOS Simulator, without rebuilding base/ for it: the arm64
# device libraries are retagged for the simulator, and only the launcher is
# compiled. Takes the bundle from a Release archive, the Lua from the repo.
#
#   platform/ios/run-simulator.sh <simulator-udid> [archive]
#
# Simulator's Metal driver crashes on SDL's texture updates, so this uses
# OpenGL ES. Rendering is not representative, input and layout are.
set -euo pipefail
cd "$(dirname "$0")/../.."

DEVICE="${1:?usage: $0 <simulator-udid> [archive]}"
ARCHIVE="${2:-$(ls -td build/KOReader-*.xcarchive | head -1)}"
WORK=build/simulator
BUILD_DIR=base/build/arm64-apple-ios14.0
STAGING=koreader-ios-arm64-apple-ios14.0/koreader
BUNDLE_ID=com.bparker2003.koreaderios
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"

rm -rf "${WORK}"
mkdir -p "${WORK}/libs"
APP="${WORK}/KOReader.app"
cp -R "${ARCHIVE}/Products/Applications/KOReader.app" "${APP}"
rm -rf "${APP}/_CodeSignature" "${APP}/embedded.mobileprovision" "${APP}/KOReader"
rsync -aL \
    --exclude '/koreader' --exclude '/libs' --exclude '/luajit' --exclude '/sdcv' \
    --exclude '*.dSYM' --exclude 'cache' --exclude 'history' --exclude 'screenshots' \
    --exclude 'spec' --exclude 'tools' \
    "${STAGING}/" "${APP}/app/"

platform/ios/write-git-rev.sh . "${APP}/app"

for entry in libluajit.dylib:luajit libSDL3.0.dylib:SDL3 libkoreader-monolibtic.dylib:koreader-monolibtic; do
    dylib="${entry%%:*}"
    name="${entry##*:}"
    xcrun vtool -set-build-version iossim 15.0 "${SDK_VERSION}" -replace \
        -output "${WORK}/libs/${dylib}" "${BUILD_DIR}/libs/${dylib}" >/dev/null
    binary="${APP}/Frameworks/${name}.framework/${name}"
    cp "${WORK}/libs/${dylib}" "${binary}"
    install_name_tool -id "@rpath/${name}.framework/${name}" \
        -change @rpath/libluajit.dylib @rpath/luajit.framework/luajit "${binary}" 2>/dev/null
done
ln -sf libSDL3.0.dylib "${WORK}/libs/libSDL3.dylib"

xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "${SDK_PATH}" \
    -fobjc-arc -O1 -g \
    -I "${BUILD_DIR}/staging/include" -I "${BUILD_DIR}/staging/include/luajit-2.1" \
    -L "${WORK}/libs" -lluajit -lSDL3 \
    -framework AVFoundation -framework Foundation -framework MediaPlayer -framework UIKit -framework CoreFoundation \
    -framework CoreGraphics -framework CoreLocation -framework CoreText -framework UniformTypeIdentifiers \
    -Wl,-headerpad_max_install_names -Wl,-rpath,@executable_path/Frameworks \
    -o "${APP}/KOReader" platform/ios/ios_*.m platform/ios/ios_exit.c platform/ios/ios_statvfs.c
install_name_tool \
    -change @rpath/libSDL3.0.dylib @rpath/SDL3.framework/SDL3 \
    -change @rpath/libluajit.dylib @rpath/luajit.framework/luajit "${APP}/KOReader"

plutil -replace CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "${APP}/Info.plist"
plutil -replace DTPlatformName -string iphonesimulator "${APP}/Info.plist"
for framework in "${APP}"/Frameworks/*.framework; do
    codesign -f -s - --timestamp=none "${framework}" 2>/dev/null
done
codesign -f -s - --timestamp=none "${APP}" 2>/dev/null

xcrun simctl boot "${DEVICE}" 2>/dev/null || true
xcrun simctl bootstatus "${DEVICE}" -b >/dev/null
xcrun simctl install "${DEVICE}" "${APP}"
SIMCTL_CHILD_SDL_RENDER_DRIVER=opengles2 xcrun simctl launch --terminate-running-process "${DEVICE}" "${BUNDLE_ID}"
