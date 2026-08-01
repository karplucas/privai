#!/usr/bin/env bash
#
# Builds Chatterbox.xcframework for the Flutter iOS app. Run on a Mac with
# Xcode; there is no cross-compiling this from Linux.
#
#   ./build_xcframework.sh [--metal] [--simulator]
#
# Produces two XCFrameworks: the public Chatterbox FFI shim and its isolated
# TTS backbone. codec.cpp and its ggml are linked statically into the shim;
# the separately isolated llama/ggml backbone remains a second dylib so its
# incompatible ggml ABI cannot collide with codec.cpp's copy.
#
# NOTE: this script has never been run. It is written from the Android build
# that is known to work, adapted for Apple's toolchain, and every step is
# there for a reason established on that platform — but expect to debug it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILD="$HERE/build"
OUT="$HERE/Chatterbox.xcframework"
BACKBONE_OUT="$HERE/ChatterboxBackbone.xcframework"

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
        -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCHATTERBOX_METAL="$METAL" \
        -DBUILD_SHARED_LIBS=OFF
    # These unsigned build products are embedded and signed by the Runner
    # target later; requiring a development team here breaks CI and clean
    # machines before the app's signing settings are available.
    # Xcode does not always materialize a transitive static archive before a
    # dylib target that refers to its path in OTHER_LDFLAGS. Build codec first
    # so libcodec.a is present when the FFI shim reaches its link phase.
    cmake --build "$dir" --config Release --target codec -- \
        -quiet CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
    cmake --build "$dir" --config Release --target chatterbox_ffi -- \
        -quiet CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
}

rm -rf "$BUILD" "$OUT" "$BACKBONE_OUT"
build_slice device iphoneos arm64

ARGS=()
BACKBONE_ARGS=()
stage_framework() {
    local dir="$1" name="$2" binary="$3"
    local framework="$BUILD/$dir/staged/$name.framework"
    local plist="$framework/Info.plist"
    rm -rf "$framework"
    mkdir -p "$framework"
    cp "$binary" "$framework/$name"
    install_name_tool -id "@rpath/$name.framework/$name" "$framework/$name"
    if [[ "$name" == "Chatterbox" ]]; then
        install_name_tool -change \
            @rpath/libttsbackbone.dylib \
            @rpath/ChatterboxBackbone.framework/ChatterboxBackbone \
            "$framework/$name"
    fi
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string "$name" "$plist"
    plutil -insert CFBundleIdentifier -string "ai.privai.$name" "$plist"
    plutil -insert CFBundleInfoDictionaryVersion -string '6.0' "$plist"
    plutil -insert CFBundleName -string "$name" "$plist"
    plutil -insert CFBundlePackageType -string FMWK "$plist"
    plutil -insert CFBundleShortVersionString -string '0.1.0' "$plist"
    plutil -insert CFBundleVersion -string '1' "$plist"
    printf '%s\n' "$framework"
}
collect() {
    local dir="$1" label="$2"
    local libdir="$BUILD/$dir/Release-$label"
    [[ -d "$libdir" ]] || libdir="$BUILD/$dir"
    local chatterbox backbone
    chatterbox="$(stage_framework "$dir" Chatterbox "$libdir/libchatterbox_ffi.dylib")"
    backbone="$(stage_framework "$dir" ChatterboxBackbone "$BUILD/$dir/ttsbackbone/libttsbackbone.dylib")"
    ARGS+=(-framework "$chatterbox")
    BACKBONE_ARGS+=(-framework "$backbone")
}
collect device iphoneos

if [[ "$WANT_SIM" == "1" ]]; then
    # The simulator has no Metal-capable path worth using; build it CPU-only.
    METAL=OFF build_slice simulator iphonesimulator "arm64;x86_64"
    collect simulator iphonesimulator
fi

xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT"
xcodebuild -create-xcframework "${BACKBONE_ARGS[@]}" -output "$BACKBONE_OUT"

echo
echo "Built $OUT and $BACKBONE_OUT"
echo
echo "Next, in ios/Runner.xcodeproj:"
echo "  Run 'cd ios && pod install'. The Podfile embeds both frameworks."
echo
echo "The Dart side opens iOS symbols with DynamicLibrary.process(), so the"
echo "framework must be linked into the app binary, not loaded lazily."
