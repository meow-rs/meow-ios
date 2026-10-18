import Foundation
import MeowIPC
import MeowModels
import Observation
import os

/// App-side IPC: posts tunnel intents to the extension and observes the state
/// and traffic snapshots the extension writes to the shared container.
@MainActor
@Observable
final class AppIPCBridge {
    private(set) var currentState: VpnState = .init()
    private(set) var currentTraffic: TrafficSnapshot = .init()

    private static let log = Logger(subsystem: "com.tangzixiang.meow", category: "ipc-bridge")

    private var stateObserver: DarwinObserver?
    private var trafficObserver: DarwinObserver?
    private var reloadedObserver: DarwinObserver?
    private var mockTrafficTask: Task<Void, Never>?

    /// Optional hook for long-lived consumers (e.g. the Utility traffic chart)
    /// that must keep sampling while the Traffic screen is off-screen.
    var onTrafficDidUpdate: ((TrafficSnapshot) -> Void)?

    /// Fired when the engine's config state was reset without a NEVPNStatus
    /// transition — either an in-place engine restart (a new `startedAt`
    /// generation while the stage stays `.connected`) or a hot config reload
    /// (the extension's `reloaded` notification). Both rebuild the engine's
    /// proxy groups, so consumers that re-sync engine state after a start
    /// (proxy-selection replay) must listen here too.
    var onEngineDidRestart: (() -> Void)?

    func start() {
        if Self.usesMockIPC {
            startMockIPC()
            return
        }

        reloadState()
        reloadTraffic()
        stateObserver = DarwinBridge.addObserver(for: .state) { [weak self] in
            Task { @MainActor in self?.reloadState() }
        }
        trafficObserver = DarwinBridge.addObserver(for: .traffic) { [weak self] in
            Task { @MainActor in self?.reloadTraffic() }
        }
        reloadedObserver = DarwinBridge.addObserver(for: .reloaded) { [weak self] in
            Task { @MainActor in self?.onEngineDidRestart?() }
        }
    }

    func stop() {
        mockTrafficTask?.cancel()
        mockTrafficTask = nil
        stateObserver.map { DarwinBridge.removeObserver($0) }
        trafficObserver.map { DarwinBridge.removeObserver($0) }
        reloadedObserver.map { DarwinBridge.removeObserver($0) }
        stateObserver = nil
        trafficObserver = nil
        reloadedObserver = nil
    }

    /// Post an intent to the extension. The extension reads it on the next
    /// `com.meow.vpn.command` notification — this call queues the intent in
    /// shared UserDefaults first and posts the notification second so the
    /// receiver always sees the payload.
    func send(_ command: TunnelCommand, profileID: UUID? = nil) {
        if Self.usesMockIPC {
            sendMock(command, profileID: profileID)
            return
        }

        let intent = TunnelIntent(command: command, profileID: profileID?.uuidString)
        do {
            try SharedStore.queueIntent(intent)
            DarwinBridge.post(.command)
        } catch {
            // Queue failures are local-only (JSON encoding, disk write); log
            // via OSLog in a real build. The observable-state layer is the
            // user-visible surface, so we don't need to elevate here.
            Self.log.error("failed to queue intent: \(String(describing: error), privacy: .public)")
        }
    }

    private func reloadState() {
        if let state = SharedStore.readState() {
            let previous = currentState
            currentState = state
            if previous.stage == .connected,
               state.stage == .connected,
               state.startedAt != previous.startedAt
            {
                onEngineDidRestart?()
            }
        }
    }

    private func reloadTraffic() {
        if let traffic = SharedStore.readTraffic() {
            currentTraffic = traffic
            relayMemstats(traffic)
            onTrafficDidUpdate?(traffic)
        }
    }

    /// Write memstats to the app's Documents folder so `xcrun devicectl device
    /// copy from --domain-type appDataContainer` can pull it from the Mac.
    private nonisolated func relayMemstats(_ t: TrafficSnapshot) {
        let line = "tick=\(t.pumpTick) footprint=\(t.footprintMB)MB " +
            "heap_used=\(t.heapUsedKB)KB heap_free=\(t.heapFreeKB)KB " +
            "tcp_conns=\(t.tcpConns) " +
            "up=\(t.uploadRate)B/s down=\(t.downloadRate)B/s " +
            "totalUp=\(t.uploadBytes)B totalDown=\(t.downloadBytes)B\n"
        guard let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appending(path: "memstats.txt")
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

private extension AppIPCBridge {
    nonisolated static var usesMockIPC: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }

    nonisolated static var shouldResetMockState: Bool {
        ProcessInfo.processInfo.arguments.contains("-ResetState")
    }

    func startMockIPC() {
        if Self.screenshotDemoRequested {
            currentState = .init(stage: .connected, startedAt: Date(timeIntervalSinceNow: -3600))
            try? SharedStore.writeState(currentState)
            currentTraffic = Self.mockTraffic(tick: 0)
            relayMemstats(currentTraffic)
            onTrafficDidUpdate?(currentTraffic)
            configureMockTrafficTask()
            return
        }

        let persisted = Self.shouldResetMockState ? nil : SharedStore.readState()
        currentState = if let persisted, persisted.errorMessage == nil {
            persisted
        } else {
            .init(stage: .stopped)
        }
        try? SharedStore.writeState(currentState)

        currentTraffic = Self.shouldRunMockTraffic(for: currentState) ? Self.mockTraffic(tick: 0) : .init()
        relayMemstats(currentTraffic)
        // Only chart live snapshots — a synthetic `.init()` reset would seed
        // the Utility traffic chart and hide its fresh-install empty state.
        if Self.shouldRunMockTraffic(for: currentState) {
            onTrafficDidUpdate?(currentTraffic)
        }

        configureMockTrafficTask()
    }

    func sendMock(_ command: TunnelCommand, profileID: UUID?) {
        switch command {
        case .start, .reload:
            currentState = .init(
                stage: .connected,
                profileID: profileID?.uuidString,
                profileName: nil,
                startedAt: Date(),
            )
        case .stop:
            currentState = .init(stage: .stopped)
        }
        try? SharedStore.writeState(currentState)
        currentTraffic = Self.shouldRunMockTraffic(for: currentState) ? Self.mockTraffic(tick: 0) : .init()
        relayMemstats(currentTraffic)
        if Self.shouldRunMockTraffic(for: currentState) {
            onTrafficDidUpdate?(currentTraffic)
        }
        configureMockTrafficTask()
    }

    func configureMockTrafficTask() {
        mockTrafficTask?.cancel()
        guard Self.shouldRunMockTraffic(for: currentState) else {
            mockTrafficTask = nil
            return
        }

        mockTrafficTask = Task { @MainActor [weak self] in
            var tick: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                guard let self else { return }
                currentTraffic = Self.mockTraffic(tick: tick)
                relayMemstats(currentTraffic)
                onTrafficDidUpdate?(currentTraffic)
            }
        }
    }

    nonisolated static func shouldRunMockTraffic(for state: VpnState) -> Bool {
        state.stage == .connected || screenshotTrafficRequested
    }

    nonisolated static var screenshotTrafficRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshotTab"), i + 1 < args.count else { return false }
        return args[i + 1] == "traffic"
    }

    /// Mirrors `VpnManager.screenshotDemoRequested` — the screenshot harness
    /// launches already connected, with the mock traffic ticker running.
    nonisolated static var screenshotDemoRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-UITests") && args.contains("-ScreenshotDemo")
    }

    nonisolated static func mockTraffic(tick: Int64) -> TrafficSnapshot {
        TrafficSnapshot(
            uploadBytes: 486_539_264 + (tick * 94208),
            downloadBytes: 3_842_146_304 + (tick * 524_288),
            uploadRate: 42496 + ((tick % 5) * 8192),
            downloadRate: 384_000 + ((tick % 7) * 65536),
            ingressPackets: 18420 + (tick * 14),
            egressPackets: 12906 + (tick * 9),
            timestamp: Date(),
            footprintMB: 84,
            heapUsedKB: 19456,
            heapFreeKB: 8192,
            tcpConns: 24,
            pumpTick: tick,
            interfaces: InterfaceTraffic(
                wifiEthernet: ByteTotals(
                    upload: 412_090_368 + (tick * 94208),
                    download: 3_221_225_472 + (tick * 524_288),
                ),
                cellular: ByteTotals(upload: 74_448_896, download: 620_920_832),
            ),
        )
    }
}
