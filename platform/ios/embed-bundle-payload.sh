#!/bin/bash
# Post-build hook for the Xcode project.
#
# Xcode has just built the .app shell (a folder with KOReader, Info.plist,
# and signing metadata). We populate it with the Lua frontend, the koreader
# data tree, and the prebuilt dylibs from base/build/, then re-sign every
# dylib with the same identity Xcode used for the app so the bundle
# verifies as a unit at install time.

set -euo pipefail

: "${SRCROOT:?Xcode env var SRCROOT not set; this script must run from a build phase}"
: "${TARGET_BUILD_DIR:?Xcode env var TARGET_BUILD_DIR not set}"
: "${WRAPPER_NAME:?Xcode env var WRAPPER_NAME not set}"

# Override per-config / per-arch if needed; defaults match make/ios.mk.
IOS_ARCH="${IOS_ARCH:-arm64}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-14.0}"

APP_DIR="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
STAGING="${SRCROOT}/koreader-ios-${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}"
STAGING_KOREADER="${STAGING}/koreader"
LIBS_SRC="${SRCROOT}/base/build/${IOS_ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}/libs"

if [ ! -d "${STAGING_KOREADER}" ]; then
    echo "error: staging tree not found at ${STAGING_KOREADER}" >&2
    echo "       run \`make TARGET=ios all\` first (or check the pre-build phase)." >&2
    exit 1
fi

if [ ! -d "${LIBS_SRC}" ]; then
    echo "error: prebuilt libs not found at ${LIBS_SRC}" >&2
    exit 1
fi

echo "[*] Embedding payload into ${APP_DIR}"

# --- 1) Copy the asset tree.
# Using `app/` rather than `koreader/` because APFS is case-insensitive by
# default and CFBundleExecutable=KOReader would collide with `koreader/`.
mkdir -p "${APP_DIR}/app"
rsync -aL --delete --delete-excluded \
    --exclude '.git' \
    --exclude 'cache' \
    --exclude 'history' \
    --exclude 'screenshots' \
    --exclude 'spec' \
    --exclude 'tools' \
    --exclude '*.dSYM' \
    --exclude '/koreader' \
    --exclude '/libs/*.dylib' \
    --exclude '/luajit' \
    --exclude '/sdcv' \
    --exclude 'plugins/SSH.koplugin' \
    --exclude 'plugins/autofrontlight.koplugin' \
    --exclude 'plugins/hello.koplugin' \
    --exclude 'plugins/timesync.koplugin' \
    "${STAGING_KOREADER}/" "${APP_DIR}/app/"

"${SRCROOT}/platform/ios/write-git-rev.sh" "${SRCROOT}" "${APP_DIR}/app"

# --- 1.5) Precompile every .lua to LuaJIT bytecode in place. Skips if
# we don't have a host luajit available; only a perf optimisation.
"${SRCROOT}/platform/ios/precompile-lua.sh" "${APP_DIR}/app" || true

# --- 1.6) First-run seeds. ios_loader.m copies app/seed/plugins/* into the
# writable Documents/plugins on first launch, so plugins that update
# themselves (Storefront) are never loaded from the read-only bundle.
# Copied after the precompile step so the seeds stay plain source.
rsync -a --delete "${SRCROOT}/platform/ios/seed/" "${APP_DIR}/app/seed/"

# --- 2) Re-sign every embedded dylib with the same identity as the app.
# Pick the most-resolved identity Xcode passed us, falling back to ad-hoc
# when signing is disabled or no real identity is wired up.
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"

# CODE_SIGNING_ALLOWED=NO (e.g. CI builds) → ad-hoc.
# Bare "iPhone Developer" / "Apple Development" / etc. without a resolved
# identity also means no real cert is available.
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] \
    || [ -z "${SIGN_IDENTITY}" ] \
    || [ "${SIGN_IDENTITY}" = "iPhone Developer" ] \
    || [ "${SIGN_IDENTITY}" = "Apple Development" ] \
    || [ "${SIGN_IDENTITY}" = "-" ]; then
    SIGN_IDENTITY="-"
    KEYCHAIN_FLAG=""
else
    KEYCHAIN_FLAG="${OTHER_CODE_SIGN_FLAGS:-}"
fi

# --- 1.7) Wrap the prebuilt dylibs in frameworks: App Store processing rejects
# standalone libraries and executables anywhere else in the bundle. Lua finds
# them through the redirect in setupkoenv.lua, keep the two lists in sync.
FRAMEWORKS_DIR="${APP_DIR}/Frameworks"
rm -rf "${FRAMEWORKS_DIR}"
LINKED_BINARIES=("${APP_DIR}/${EXECUTABLE_NAME}")
if [ -f "${APP_DIR}/${EXECUTABLE_NAME}.debug.dylib" ]; then
    LINKED_BINARIES+=("${APP_DIR}/${EXECUTABLE_NAME}.debug.dylib")
fi
for entry in libSDL3.0.dylib:SDL3 libluajit.dylib:luajit libkoreader-monolibtic.dylib:koreader-monolibtic; do
    dylib="${entry%%:*}"
    name="${entry##*:}"
    framework="${FRAMEWORKS_DIR}/${name}.framework"
    mkdir -p "${framework}"
    cp "${LIBS_SRC}/${dylib}" "${framework}/${name}"
    /usr/bin/install_name_tool -id "@rpath/${name}.framework/${name}" "${framework}/${name}"
    LINKED_BINARIES+=("${framework}/${name}")
    cat >"${framework}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>${PRODUCT_BUNDLE_IDENTIFIER}.${name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>CFBundleVersion</key>
    <string>${CURRENT_PROJECT_VERSION}</string>
    <key>MinimumOSVersion</key>
    <string>${IPHONEOS_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
PLIST
done
for binary in "${LINKED_BINARIES[@]}"; do
    /usr/bin/install_name_tool \
        -change @rpath/libSDL3.0.dylib @rpath/SDL3.framework/SDL3 \
        -change @rpath/libluajit.dylib @rpath/luajit.framework/luajit \
        -change @rpath/libkoreader-monolibtic.dylib @rpath/koreader-monolibtic.framework/koreader-monolibtic \
        "${binary}"
done

echo "[*] Re-signing every Mach-O in the bundle with identity: ${SIGN_IDENTITY}"
# We have to sign every .dylib and .so, not just app/libs/ — KOReader
# also dlopens Lua C modules from app/common/ (lpeg.so, rapidjson.so,
# etc.) and per-plugin .so's. iOS refuses any unsigned Mach-O at dlopen
# time ("mapped file has no cdhash").
while IFS= read -r -d '' lib; do
    /usr/bin/codesign \
        --force \
        --sign "${SIGN_IDENTITY}" \
        --timestamp=none \
        ${KEYCHAIN_FLAG} \
        "${lib}" >/dev/null
done < <(find "${APP_DIR}/app" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
for framework in "${FRAMEWORKS_DIR}"/*.framework; do
    /usr/bin/codesign \
        --force \
        --sign "${SIGN_IDENTITY}" \
        --timestamp=none \
        ${KEYCHAIN_FLAG} \
        "${framework}" >/dev/null
done

echo "[*] Payload embedded."
