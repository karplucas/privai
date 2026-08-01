#!/usr/bin/env bash
#
# Builds Chatterbox.xcframework for the Flutter iOS app. Run on a Mac with
# Xcode; there is no cross-compiling this from Linux.
#
#   ./build_xcframework.sh [--metal] [--simulator]
#
# Produces native/chatterbox/ios/Chatterbox.xcframework containing, per slice,
# libchatterbox_ffi.dylib and the libraries it pulls in (libttsbackbone,
# libcodec, libggml*).
#
# NOTE: this script has never been run. It is written from the Android build
# that is known to work, adapted for Apple's toolchain, and every step is
# there for a reason established on that platform — but expect to debug it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILD="$HERE/build"
OUT="$HERE/Chatterbox.xcframework"

METAL=OFF
WANT_SIM=0
for arg in "$@"; do
    case "$arg" in
        --metal)     METAL=ON ;;
        --simulator) WANT_SIM=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$ROOT/vendor/codec.cpp/CMakeLists.txt" ]]; then
    echo "codec.cpp is not checked out. Run:" >&2
    echo "  git submodule update --init --recursive" >&2
    exit 1
fi

# The submodule needs its patches applied — see ../README.md. Checked rather
# than applied, so this never silently rewrites a tree you are editing.
if ! grep -q "CODEC_BACKBONE_METAL" "$ROOT/vendor/codec.cpp/cmake/SetupTtsBackbone.cmake"; then
    echo "codec.cpp is missing its patches. Run:" >&2
    echo "  (cd $ROOT/vendor/codec.cpp && git apply ../../patches/codec.cpp.patch)" >&2
    exit 1
fi

# Apple's own toolchain file, so no third-party ios.toolchain.cmake is needed.
# CMAKE_OSX_DEPLOYMENT_TARGET must match the Podfile's platform :ios line.
build_slice() {
    local name="$1" sysroot="$2" archs="$3"
    local dir="$BUILD/$name"

    echo "==> $name ($archs, sysroot=$sysroot, metal=$METAL)"
    cmake -S "$ROOT" -B "$dir" -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$sysroot" \
        -DCMAKE_OSX_ARCHITECTURES="$archs" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCHATTERBOX_METAL="$METAL" \
        -DBUILD_SHARED_LIBS=ON
    cmake --build "$dir" --config Release --target chatterbox_ffi -- -quiet
}

rm -rf "$BUILD" "$OUT"
build_slice device iphoneos arm64

ARGS=()
collect() {
    local dir="$1" label="$2"
    local libdir="$BUILD/$dir/Release-$label"
    [[ -d "$libdir" ]] || libdir="$BUILD/$dir"
    ARGS+=(-library "$libdir/libchatterbox_ffi.dylib")
}
collect device iphoneos

if [[ "$WANT_SIM" == "1" ]]; then
    # The simulator has no Metal-capable path worth using; build it CPU-only.
    METAL=OFF build_slice simulator iphonesimulator "arm64;x86_64"
    collect simulator iphonesimulator
fi

xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT"

echo
echo "Built $OUT"
echo
echo "Next, in ios/Runner.xcodeproj:"
echo "  1. Drag Chatterbox.xcframework into the Runner target."
echo "  2. Set it to 'Embed & Sign' — the app dlopens nothing, so the dylibs"
echo "     must be embedded and signed or the app is rejected at launch."
echo "  3. Add the sibling dylibs (libttsbackbone, libcodec, libggml*) the"
echo "     same way; libchatterbox_ffi links against them by @rpath."
echo
echo "The Dart side opens iOS symbols with DynamicLibrary.process(), so the"
echo "framework must be linked into the app binary, not loaded lazily."
