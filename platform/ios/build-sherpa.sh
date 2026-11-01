#!/bin/bash
# Builds the speech engine behind the Kokoro voices into build/sherpa, which the
# Xcode project links. Only needs running once. Simulator builds leave it out.
#
#   platform/ios/build-sherpa.sh
#
# Stay on 1.x: sherpa-onnx 2.0 dropped espeak-ng, and with it reading plain text.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=v1.13.8
ONNXRUNTIME=1.28.2
ROOT="$PWD/build/sherpa"
SRC="$ROOT/src"

if [ ! -d "$SRC" ]; then
    git clone --depth 1 --branch "$VERSION" https://github.com/k2-fsa/sherpa-onnx "$SRC"
fi

RUNTIME="$ROOT/onnxruntime.xcframework"
if [ ! -d "$RUNTIME" ]; then
    curl -fL -o "$ROOT/onnxruntime.zip" \
        "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v$ONNXRUNTIME/onnxruntime-ios-static-xcframework-$ONNXRUNTIME.xcframework.zip"
    unzip -q "$ROOT/onnxruntime.zip" -d "$ROOT"
    rm "$ROOT/onnxruntime.zip"
fi

build() {
    local platform="$1" runtime="$2" out="$ROOT/$3"
    SHERPA_ONNXRUNTIME_LIB_DIR="$RUNTIME/$runtime" \
    SHERPA_ONNXRUNTIME_INCLUDE_DIR="$RUNTIME/$runtime/onnxruntime.framework/Headers" \
    cmake -S "$SRC" -B "$out" \
        -DCMAKE_TOOLCHAIN_FILE="$SRC/toolchains/ios.toolchain.cmake" \
        -DPLATFORM="$platform" \
        -DDEPLOYMENT_TARGET=13.0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$ROOT/install" \
        -DENABLE_BITCODE=0 -DENABLE_ARC=1 -DENABLE_VISIBILITY=0 \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_PIPER_PHONMIZE_EXE=OFF -DBUILD_PIPER_PHONMIZE_TESTS=OFF \
        -DBUILD_ESPEAK_NG_EXE=OFF -DBUILD_ESPEAK_NG_TESTS=OFF \
        -DSHERPA_ONNX_ENABLE_PYTHON=OFF -DSHERPA_ONNX_ENABLE_BINARY=OFF \
        -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_CHECK=OFF \
        -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF -DSHERPA_ONNX_ENABLE_JNI=OFF \
        -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF
    cmake --build "$out" -j 8
    cmake --build "$out" --target install
    xcrun libtool -static -o "$out/libsherpa-onnx-all.a" "$out"/lib/*.a
    cp "$RUNTIME/$runtime/onnxruntime.framework/onnxruntime" "$out/libonnxruntime.a"
}

build OS64 ios-arm64 os64
