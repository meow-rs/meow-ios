#!/usr/bin/env bash
# Build meow-ios-ffi for iOS + tvOS (device and simulator) and pack the four
# static libs into a single XCFramework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CRATE_DIR="$ROOT/core/rust/meow-ios-ffi"
OUT_DIR="$ROOT/MeowCore/Frameworks"
HEADER_SRC="$CRATE_DIR/include/meow_core.h"
HEADER_DST="$ROOT/MeowCore/include/meow_core.h"

# iOS first so a failure on the tvOS slices — the newer, less-exercised pair —
# never silently costs us the shipping platform.
TARGETS_REQUIRED=(
    aarch64-apple-ios
    aarch64-apple-ios-sim
    aarch64-apple-tvos
    aarch64-apple-tvos-sim
)
PROFILE="release"

# Match the deployment targets declared in project.yml so the Rust static libs
# and the Xcode targets agree on LC_BUILD_VERSION minos.
#
# These are read here and then unexported on purpose: clang's driver rejects an
# environment carrying more than one *_DEPLOYMENT_TARGET
# ("conflicting deployment targets, both '18.0' and '17.0' are present in
# environment"), and boring-sys reaches clang through CMake. Each cargo build
# below is handed exactly the one variable its platform needs.
IPHONEOS_MIN="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"
TVOS_MIN="${TVOS_DEPLOYMENT_TARGET:-17.0}"
unset IPHONEOS_DEPLOYMENT_TARGET TVOS_DEPLOYMENT_TARGET

for target in "${TARGETS_REQUIRED[@]}"; do
    if ! rustup target list --installed | grep -qx "$target"; then
        echo "==> Adding rust target $target"
        rustup target add "$target"
    fi
done

cd "$CRATE_DIR"

# boring-sys 4.x (pinned through quiche, which meow-rs uses for hysteria2)
# predates tvOS support, and two of its gaps bite the tvOS slices. Both are
# closed from the environment rather than by forking the crate:
#
#   * Its C++-runtime table knows macos/ios/freebsd and answers "stdc++" for
#     everything else, so a tvOS build emits -lstdc++ and the link dies with
#     "library 'stdc++' not found" (Apple SDKs ship libc++ only).
#     BORING_BSSL_RUST_CPPLIB overrides that answer.
#   * Its CMake table has no tvOS rows, so CMake falls back to the platform
#     default SDK for CMAKE_SYSTEM_NAME=tvOS, which is the *device* SDK even
#     when the simulator is being built. cmake/tvos-simulator.cmake pins the
#     simulator SDK instead. boring-sys, the cmake crate and aws-lc-sys all
#     honor CMAKE_TOOLCHAIN_FILE_<target_with_underscores>, so the variable is
#     scoped to the simulator slice and the device slice keeps the stock path.
#
# Drop both once the tree resolves boring-sys >= 5 (boring 5.x supports tvOS
# natively; waiting on quiche to move off boring ^4).
TVOS_SIM_TOOLCHAIN="$CRATE_DIR/cmake/tvos-simulator.cmake"

LIBS=()
for target in "${TARGETS_REQUIRED[@]}"; do
    case "$target" in
        aarch64-apple-tvos-sim)
            build_env=(
                "TVOS_DEPLOYMENT_TARGET=$TVOS_MIN"
                "BORING_BSSL_RUST_CPPLIB=c++"
                "CMAKE_TOOLCHAIN_FILE_aarch64_apple_tvos_sim=$TVOS_SIM_TOOLCHAIN"
            )
            ;;
        *-apple-tvos*)
            build_env=(
                "TVOS_DEPLOYMENT_TARGET=$TVOS_MIN"
                "BORING_BSSL_RUST_CPPLIB=c++"
            )
            ;;
        *)
            build_env=("IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_MIN")
            ;;
    esac

    echo "==> cargo build --target $target (${build_env[*]})"
    env "${build_env[@]}" cargo build --release --target "$target"

    lib="$CRATE_DIR/target/$target/$PROFILE/libmeow_ios_ffi.a"
    if [[ ! -f "$lib" ]]; then
        echo "error: expected static lib missing: $lib" >&2
        exit 1
    fi
    LIBS+=("$lib")
done

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/MeowCore.xcframework" "$OUT_DIR/MihomoCore.xcframework"

# Ensure the header we ship to Swift matches what cbindgen emitted.
if [[ -f "$HEADER_SRC" ]]; then
    cp "$HEADER_SRC" "$HEADER_DST"
fi
# Drop the old header path if a stale copy lingers from before the rename.
rm -f "$ROOT/MeowCore/include/mihomo_core.h"

HEADERS_STAGE="$(mktemp -d)"
cp "$HEADER_DST" "$HEADERS_STAGE/meow_core.h"

CREATE_ARGS=()
for lib in "${LIBS[@]}"; do
    CREATE_ARGS+=(-library "$lib" -headers "$HEADERS_STAGE")
done

echo "==> xcodebuild -create-xcframework (${#LIBS[@]} slices)"
xcodebuild -create-xcframework "${CREATE_ARGS[@]}" \
    -output "$OUT_DIR/MeowCore.xcframework"

rm -rf "$HEADERS_STAGE"
echo "==> wrote $OUT_DIR/MeowCore.xcframework"
