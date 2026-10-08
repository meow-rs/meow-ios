#!/usr/bin/env bash
# Capture App Store screenshots for the Apple TV app from the tvOS Simulator.
#
# Companion to capture-screenshots.sh (iOS). The TV app is a single screen,
# so there is one capture per locale, taken with the `-UITests -ScreenshotDemo`
# launch args that seed two demo profiles and a mock connected tunnel.
#
# Output: fastlane/screenshots/tvos/<locale>/AppleTV-01Home.png at 1920x1080
# (the APP_APPLE_TV display type).
#
# Prereq: build the app for the Apple TV simulator first — Release, arm64,
# ad-hoc signed (CODE_SIGNING_ALLOWED=NO strips the App Group entitlement and
# the app traps in AppGroup.swift at launch):
#   xcodebuild build -project meow-ios.xcodeproj -scheme meow-tvos \
#     -configuration Release -destination 'generic/platform=tvOS Simulator' \
#     -derivedDataPath build/DerivedData-tvsnapshot ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
#     CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.tangzixiang.meow"
APP="${APP:-$(find build/DerivedData-tvsnapshot/Build/Products -name 'meow-tvos.app' -path '*Release-appletvsimulator*' 2>/dev/null | head -1)}"
OUT_ROOT="$ROOT/fastlane/screenshots/tvos"
# The "(at 1080p)" device renders at exactly 1920x1080; the plain 4K device
# would produce 3840x2160, which App Store Connect also accepts.
DEVICE_NAME="${DEVICE_NAME:-Apple TV 4K (3rd generation) (at 1080p)}"
LOCALES=("en-US" "zh-Hans")

[[ -d "$APP" ]] || { echo "error: Release tvOS simulator app not found ($APP). Build it first (see prereq above)." >&2; exit 1; }
case "$APP" in *Debug-appletvsimulator*) echo "error: $APP is a Debug build." >&2; exit 1;; esac
echo "==> App: $APP"

udid="$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
[[ -n "$udid" ]] || { echo "error: no simulator '$DEVICE_NAME'" >&2; exit 1; }
echo "==> $DEVICE_NAME ($udid)"

rm -rf "$OUT_ROOT"
xcrun simctl boot "$udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$udid" >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$APP" || { echo "error: install failed" >&2; exit 1; }

for locale in "${LOCALES[@]}"; do
    mkdir -p "$OUT_ROOT/$locale"
    loc_underscore="${locale//-/_}"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$BUNDLE_ID" \
        -UITests -ResetState -ScreenshotDemo \
        -AppleLanguages "($locale)" -AppleLocale "$loc_underscore" >/dev/null
    # tvOS focus animations settle slower than the iPhone tab switch.
    sleep 5
    out="$OUT_ROOT/$locale/AppleTV-01Home.png"
    # simctl io is sandboxed and cannot write onto /Volumes/*: capture to /tmp.
    tmp="/tmp/meowshot-tv-$$-${locale}.png"
    if xcrun simctl io "$udid" screenshot "$tmp" >/dev/null 2>&1 && [[ -s "$tmp" ]]; then
        cp "$tmp" "$out"
        echo "    $locale/AppleTV-01Home.png $(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/{printf "%s ", $2}')"
    else
        echo "    FAILED $locale/AppleTV-01Home.png" >&2
    fi
    rm -f "$tmp"
done
xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Done. $(find "$OUT_ROOT" -name '*.png' | wc -l | tr -d ' ') screenshots in $OUT_ROOT"
