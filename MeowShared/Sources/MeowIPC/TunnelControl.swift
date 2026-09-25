#if canImport(NetworkExtension)
    import MeowModels
    import NetworkExtension

    /// `NETunnelProviderManager` plumbing shared by the app (`VpnManager`) and
    /// the Home Screen widgets, so a tunnel started from either place gets the
    /// same slot-claiming, on-demand, and stale-configuration handling.
    ///
    /// MainActor-isolated because the NetworkExtension objects aren't `Sendable`
    /// and both callers already drive them from the main actor.
    @MainActor
    public enum TunnelControl {
        /// meow's saved tunnel configuration, or `nil` if the app has never
        /// created one. Loading never saves, so it can't steal the VPN slot
        /// from another app.
        public static func loadManager() async throws -> NETunnelProviderManager? {
            try await NETunnelProviderManager.loadAllFromPreferences().first
        }

        /// Claim the VPN slot and start the tunnel. Re-enables the
        /// configuration if another VPN app took the slot, restores the
        /// on-demand rule, and syncs on-demand to the user's pref — saving
        /// only when something changed.
        public static func start(_ manager: NETunnelProviderManager, onDemand: Bool) async throws {
            var dirty = false
            if !manager.isEnabled {
                manager.isEnabled = true
                dirty = true
            }
            if (manager.onDemandRules ?? []).isEmpty {
                manager.onDemandRules = [NEOnDemandRuleConnect()]
                dirty = true
            }
            if manager.isOnDemandEnabled != onDemand {
                manager.isOnDemandEnabled = onDemand
                dirty = true
            }
            if dirty {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            try await startTunnel(manager)
        }

        /// Turn on-demand off before an intentional stop. iOS reclaims the NE
        /// under media/CPU/network pressure and normally auto-reconnects via
        /// the on-demand rule — so it has to be disabled when the user
        /// actually wants the VPN off, or iOS brings it straight back.
        public static func disableOnDemand(_ manager: NETunnelProviderManager) async {
            // The app and the widgets each save this configuration, so the
            // caller's copy can predate the other's start — check what's
            // saved, not what was loaded.
            try? await manager.loadFromPreferences()
            guard manager.isOnDemandEnabled else { return }
            manager.isOnDemandEnabled = false
            try? await manager.saveToPreferences()
        }

        /// Whether `status` describes a tunnel a stop request can act on. For
        /// `.invalid` / `.disconnected` a stop produces no status notification.
        public nonisolated static func canStop(_ status: NEVPNStatus) -> Bool {
            switch status {
            case .connected, .connecting, .reasserting, .disconnecting:
                true
            case .invalid, .disconnected:
                false
            @unknown default:
                false
            }
        }

        public nonisolated static func stage(for status: NEVPNStatus) -> VpnStage {
            switch status {
            case .invalid: .idle
            case .disconnected: .stopped
            case .connecting: .connecting
            case .connected: .connected
            case .reasserting: .connecting
            case .disconnecting: .stopping
            @unknown default: .idle
            }
        }

        /// Start the tunnel, reloading once and retrying if iOS reports the
        /// local configuration is stale. Even after a fresh load, another VPN
        /// app mutating the shared VPN preferences between our load and our
        /// `startVPNTunnel()` call can leave the object stale; the documented
        /// recovery is to reload from preferences and try again.
        private static func startTunnel(_ manager: NETunnelProviderManager) async throws {
            do {
                try manager.connection.startVPNTunnel()
            } catch let error as NEVPNError where error.code == .configurationStale {
                try await manager.loadFromPreferences()
                try manager.connection.startVPNTunnel()
            }
        }
    }
#endif
