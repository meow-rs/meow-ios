# CMake toolchain file for the aarch64-apple-tvos-sim slice of meow-ios-ffi.
#
# boring-sys 4.x (pinned through quiche, which meow-rs uses for hysteria2)
# predates tvOS support: its CMAKE_PARAMS_APPLE table has iOS and macOS rows
# only, so it never tells CMake which SDK a tvOS build wants. CMake then falls
# back to the platform default for CMAKE_SYSTEM_NAME=tvOS, which is the
# *device* SDK (appletvos). That is right for aarch64-apple-tvos and wrong for
# the simulator, whose BoringSSL would be configured against AppleTVOS.sdk.
#
# These four lines are what boring-sys 5.x's tvOS-simulator row plus the cmake
# crate's CMAKE_SYSTEM_NAME detection would have set. Both boring-sys and the
# cmake crate honor CMAKE_TOOLCHAIN_FILE_<target_with_underscores>, which is how
# scripts/build-rust.sh hands this file to the simulator build only.
#
# Drop this file once the tree resolves boring-sys >= 5.
set(CMAKE_SYSTEM_NAME tvOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_SYSROOT appletvsimulator)
