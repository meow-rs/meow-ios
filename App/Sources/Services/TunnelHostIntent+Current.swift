#if os(macOS)
    import Foundation
    import MeowIPC
    import MeowModels

    /// What the macOS app hands its system extension with each start and
    /// command, in place of the App Group files the iOS and tvOS builds
    /// share with theirs (see `TunnelHostIPC`).
    extension TunnelHostIntent {
        /// `command` plus the active profile's YAML and the current tunnel
        /// preferences, read from the app's own container.
        static func current(_ command: TunnelCommand, profileID: UUID? = nil) -> TunnelHostIntent {
            TunnelHostIntent(
                command: command,
                profileID: profileID?.uuidString
                    ?? AppGroup.defaults.string(forKey: PreferenceKey.selectedProfileID),
                configYAML: try? String(contentsOf: AppGroup.configURL, encoding: .utf8),
                preferences: TunnelHostPreferences(Preferences.load(from: AppGroup.defaults)),
            )
        }
    }
#endif
