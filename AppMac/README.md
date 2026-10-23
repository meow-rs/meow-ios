# AppMac — the native macOS app

`meow-macos` is a native Mac app (SwiftUI, macOS 15+, Apple Silicon only),
not the iPad app running on a Mac. It ships outside the Mac App Store with a
Developer ID signature, so it is unsandboxed and runs its tunnel as a
NetworkExtension **system extension** (`PacketTunnelMac`) rather than an app
extension.

| | Bundle identifier |
|---|---|
| App | `com.tangzixiang.meow.mac` |
| System extension | `com.tangzixiang.meow.mac.PacketTunnel` |

The Mac app has its own identifiers so it never shares a VPN configuration or
a defaults domain with the iOS app, which can also run on Apple Silicon Macs.

## What it reuses

| Layer | Path | Shared? |
|---|---|---|
| Rust engine | `MeowCore.xcframework` | yes — `scripts/build-rust.sh` also packs an `aarch64-apple-darwin` slice |
| Tunnel provider | `PacketTunnel/Sources` | yes, plus `PacketTunnelMac/main.m` (`+[NEProvider startSystemExtensionMode]`) |
| Models, services, app composition | `App/Sources/{Models,Services}`, `AppModel.swift`, `AppModelContainer.swift` | yes |
| Strings | `App/Resources` (minus the asset catalog and GeoData) | yes |
| GeoIP / geosite data | `App/Resources/GeoData` | bundled into the **extension**, which stages it (`MWGeoAssets`) |
| Views | `App/Sources/Views` | **no** — replaced by `AppMac/Sources` |

## How the app and the extension talk

Both the app and the extension are unsandboxed (as Surge's are). The
extension runs as root, though, so the App Group container that iOS shares
between app and extension doesn't exist here: the extension keeps its files
under root's `Application Support/meow` (`MWAppGroup`), and the app keeps its
own in `~/Library/Application Support/meow` (`AppGroup.containerURL`). Darwin
notifications don't reliably cross from root to the user either. Everything
goes over provider messages instead (`MeowIPC/TunnelHostIPC.swift`):

- **Start.** The start options carry a `TunnelHostIntent`: the selected
  profile's YAML plus the tunnel-side preferences (`TunnelHostIntent.current`).
  The extension saves the preferences, so an on-demand start without the app
  still has the latest ones.
- **Intents** (reload, stop, …) go as a `0x08` message with the same payload.
- **State.** `AppIPCBridge` pulls a `0x07` snapshot every second while
  connected and mirrors it into the app's own `state.json`, `traffic.json`
  and REST credentials, so the shared services read them as on iOS.
- **Tunnel log** export is a `0x09` message.

## The app

`AppMac/Sources`:

- `MeowMacApp.swift` — scenes: the main `Window`, the `MenuBarExtra`
  (window style), `Settings`, and the Connection menu (⇧⌘K, route mode).
- `Window/` — the `NavigationSplitView` shell, sidebar, connect button and the
  extension-approval banners.
- `Pages/` — Configs, Proxy Groups, Connections, Rules, Providers, Traffic,
  Statistics, Logs, DNS.
- `MenuBar/` — the status item (paw outline / filled / breathing / error
  badge, optional live rate) and the popover.
- `Settings/` — General, Network, Appearance, Diagnostics, About.
- `Services/MacController.swift` — connect/disconnect, profile and route mode
  switching, Mac-only preferences (menu bar vs. Dock, appearance).
- `Services/SystemExtensionInstaller.swift` — `OSSystemExtensionRequest`
  activation; the first connect asks for approval in System Settings.

## Building and running

```sh
scripts/build-rust.sh            # once, or after a meow-rs bump
xcodegen generate
xcodebuild -project meow-ios.xcodeproj -scheme meow-macos \
  -destination 'platform=macOS,arch=arm64' build
```

An unsigned build (`CODE_SIGNING_ALLOWED=NO`) compiles but can't activate the
extension. To run the tunnel:

1. Enable **Network Extensions** and **System Extension** on the App ID
   `com.tangzixiang.meow.mac`, and **Network Extensions** on
   `com.tangzixiang.meow.mac.PacketTunnel`. The extension also claims the
   team-prefixed app group `<TeamID>.com.tangzixiang.meow.mac`, which its
   `NEMachServiceName` has to start with.
2. Sign both with a Developer ID Application certificate and provisioning
   profiles carrying those capabilities. Exporting for Developer ID rewrites
   the extension's `packet-tunnel-provider` entitlement to
   `packet-tunnel-provider-systemextension`.
3. Move `meow.app` to `/Applications` — macOS only activates system
   extensions of apps there. While developing, `systemextensionsctl developer
   on` (with SIP adjusted) lifts that requirement.
4. Connect once and allow the extension in System Settings › General ›
   Login Items & Extensions.

Notarize the exported app (`xcrun notarytool submit … --wait`, then
`xcrun stapler staple`) before handing it to anyone else.
