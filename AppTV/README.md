# AppTV — the tvOS app target

`meow-tvos` is a second application target, not a second app. It ships the same
engine, the same App Group, and the same bundle identifier as `meow-ios`
(`com.tangzixiang.meow`) so the two are a universal purchase: one App Store
record, one price, both platform binaries.

## What it reuses

| Layer | Path | Shared? |
|---|---|---|
| Rust engine | `MeowCore.xcframework` | yes — `scripts/build-rust.sh` now packs `aarch64-apple-tvos{,-sim}` slices alongside the iOS pair |
| Tunnel provider | `PacketTunnel/Sources` | yes, byte-for-byte — pure Objective-C over NetworkExtension, no UIKit |
| Models | `App/Sources/Models` | yes |
| Services | `App/Sources/Services` | yes |
| App composition | `App/Sources/AppModel.swift`, `AppModelContainer.swift` | yes |
| Strings, GeoIP data | `App/Resources` (minus `Assets.xcassets`) | yes |
| Views | `App/Sources/Views` | **no** — replaced by `AppTV/Sources` |

Nothing under `Models/` or `Services/` imports UIKit or SwiftUI, which is what
makes the split above possible; keep it that way, or the tvOS target stops
building. `MeowTests` covers those files once, from the iOS target, and that
coverage carries over.

## What it replaces

`App/Sources/Views` is iPhone-shaped end to end — tab bar, sheets, swipe
actions, a camera QR scanner — so `AppTV/Sources` reimplements the one screen
Apple TV needs instead:

- `MeowTVApp.swift` — `@main`, identical service graph to `MeowApp`.
- `TVContentView.swift` — title, connect button, subscription-URL field,
  profile list (long-press a row to refresh or delete it).
- `TVICloudImportView.swift` — "Import from iCloud Drive": the configs the
  iPhone app relayed (see below).
- `Assets.xcassets` — the tvOS accent and launch colors, copied from the iOS
  catalog. The Brand Assets stack belongs here too.

Layout follows the tvOS HIG: no padding beyond the system TV safe area, one
`focusSection()` per panel, focus lands on Connect at launch, the connect
button is never `.disabled` (a disabled control can't take focus; with no
profile it sends focus to the URL field instead), and errors are alerts
rather than inline banners.

The connect/disconnect sequencing in `TVContentView.toggle()` is a deliberate
copy of `GlobalVpnSwitchBar.toggle()`; the IPC intent must be queued before
`VpnManager.connect()` so the extension knows which profile to load on its
first config read. Change one, change both.

## Platform limits

- **tvOS 17.0 floor.** `NEPacketTunnelProvider` isn't available on Apple TV
  before it, and the whole app is the tunnel.
- **Caches-only storage.** tvOS has no writable Application Support, and the
  App Group container root is read-only — only its `Library/Caches` is
  writable. `AppGroup.containerURL` / `MWAppGroup.containerURL` point there on
  tvOS, so `config.yaml`, the engine's home dir, logs and IPC files all live
  in Caches; the SwiftData store sits in the app's own Caches. The system may
  purge either under storage pressure, which is why `TVContentView.toggle()`
  rewrites `config.yaml` from the selected profile before every connect.
- **No QR scan.** Apple TV has no camera. Subscriptions arrive by URL, or
  from iCloud Drive via the iPhone (next item).
- **No iCloud Drive — relayed through CloudKit instead.** tvOS has no iCloud
  Drive (Apple QA1935) and no `fileImporter`. The iOS app publishes
  `iCloud Drive › meow` (`NSUbiquitousContainers`), watches it with an
  `NSMetadataQuery` (`ICloudRelayUploader`), and mirrors each top-level
  `.yaml` / `.yml` into the `ICloudDriveRelay` zone of the
  `iCloud.com.tangzixiang.meow` private CloudKit database; the TV lists that
  zone (`ICloudRelayStore`) and imports with `upsertLocal`, so re-importing an
  edited file updates its profile. On the phone, a Configs row's leading swipe
  action "iCloud Drive" writes that profile into the same folder
  (`ICloudDriveExporter`), so a config added on iPhone reaches the TV too. A file reaches the TV only after meow has
  run on the phone. The container must exist in the developer portal with
  iCloud (CloudKit + iCloud Documents) enabled on the App ID, and the schema
  must be deployed to production in the CloudKit Console before release.
  SwiftData stays `cloudKitDatabase: .none` — see `AppModelContainer`.
- **No alternate app icons.** `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`
  is iOS-only; `AppIcon.swift` still compiles (it's plain `Foundation`) but
  nothing on tvOS calls it.
- **No `.switch` toggle style** on tvOS 17, so the VPN control is a focusable
  button, not a `Toggle`.
- **No Brand Assets yet.** tvOS wants a layered App Icon + Top Shelf stack
  rather than the iOS `.appiconset`s, which is why `App/Resources/Assets.xcassets`
  is excluded from this target's sources. Required before App Store submission;
  not in this MVP.

## Building

```sh
scripts/build-rust.sh          # 4 slices: iOS + tvOS, device + simulator
xcodegen generate
xcodebuild build -project meow-ios.xcodeproj -scheme meow-tvos \
    -destination 'platform=tvOS Simulator,name=Apple TV'
```
