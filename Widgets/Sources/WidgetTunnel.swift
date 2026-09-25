import Foundation
import MeowIPC
import MeowModels
import NetworkExtension

/// The widgets' handle on meow's tunnel: the same saved
/// `NETunnelProviderManager` the app drives, through the same
/// `TunnelControl` start/stop path.
///
/// The simulator has no packet tunnel, so there it flips the mock state the
/// app's `VpnManager` keeps in `state.json` instead.
@MainActor
enum WidgetTunnel {
    struct Status {
        let stage: VpnStage
        let isConfigured: Bool
    }

    enum Failure: Error {
        case notConfigured
    }

    /// How long an intent waits for the tunnel to finish starting or
    /// stopping before it lets the widgets reload.
    private static let settleTimeout: Duration = .seconds(10)

    static func status() async -> Status {
        #if targetEnvironment(simulator)
            let current = SharedStore.readState()?.stage ?? .stopped
        #else
            guard let manager = try? await TunnelControl.loadManager() else {
                return Status(stage: .idle, isConfigured: false)
            }
            let current = stage(of: manager)
        #endif
        // A running tunnel keeps its switch even if its profile has since
        // been removed — it still has to be possible to turn it off.
        return Status(stage: current, isConfigured: hasProfile || current.isActive)
    }

    /// Start or stop the tunnel, then wait (bounded) for it to settle so the
    /// reload that follows shows where it landed rather than "Connecting".
    static func setRunning(_ running: Bool) async throws {
        if running, !hasProfile {
            throw Failure.notConfigured
        }
        #if targetEnvironment(simulator)
            try setMockRunning(running)
        #else
            guard let manager = try await TunnelControl.loadManager() else { throw Failure.notConfigured }
            if running {
                let onDemand = Preferences.load(from: AppGroup.defaults).onDemand
                try await TunnelControl.start(manager, onDemand: onDemand)
            } else {
                await TunnelControl.disableOnDemand(manager)
                guard TunnelControl.canStop(manager.connection.status) else { return }
                manager.connection.stopVPNTunnel()
            }
            await waitUntilSettled(manager, running: running)
        #endif
    }

    /// The app writes the selected profile's YAML here; the tunnel has
    /// nothing to run without it.
    private static var hasProfile: Bool {
        FileManager.default.fileExists(atPath: AppGroup.configURL.path)
    }

    /// NE status, plus the extension's own verdict when a start failed: it
    /// aborts to `.disconnected` without an error, but leaves `.error` in
    /// the shared state — the same signal the app surfaces.
    private static func stage(of manager: NETunnelProviderManager) -> VpnStage {
        let stage = TunnelControl.stage(for: manager.connection.status)
        if stage == .stopped, SharedStore.readState()?.stage == .error {
            return .error
        }
        return stage
    }

    private static func waitUntilSettled(_ manager: NETunnelProviderManager, running: Bool) async {
        let deadline = ContinuousClock.now + settleTimeout
        var hasStarted = false
        while ContinuousClock.now < deadline {
            let status = manager.connection.status
            let isLive = TunnelControl.canStop(status)
            if running {
                // A start can sit at `.disconnected` for a moment before it
                // turns `.connecting`; only after that does falling back to
                // `.disconnected` mean the start failed.
                if status == .connected || (hasStarted && !isLive) {
                    return
                }
                hasStarted = hasStarted || isLive
            } else if !isLive {
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    #if targetEnvironment(simulator)
        private static func setMockRunning(_ running: Bool) throws {
            let current = SharedStore.readState()
            try SharedStore.writeState(VpnState(
                stage: running ? .connected : .stopped,
                profileID: current?.profileID,
                profileName: current?.profileName,
                startedAt: running ? Date() : nil,
            ))
        }
    #endif
}
