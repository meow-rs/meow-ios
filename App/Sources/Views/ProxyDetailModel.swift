import Foundation
import Observation

/// The tests a proxy's detail page offers, in the order it lists them.
enum ProxyProbe: CaseIterable {
    case tcpLatency, udpLatency, exitIP, nat, download, upload

    /// Bound to fail on a proxy without a UDP relay.
    var needsUDP: Bool {
        self == .udpLatency || self == .nat
    }

    /// Download and upload take turns: run together, each would eat into
    /// the other's sample.
    var takesTurns: Bool {
        self == .download || self == .upload
    }
}

enum ProbeResult: Equatable {
    case latency(ms: Int)
    case exit(ExitIP)
    case nat(NatType)
    case bandwidth(Throughput)
}

enum ProbeFailure: Equatable {
    case timedOut, udpUnsupported, failed
}

enum ProbeState: Equatable {
    case idle
    case running
    case done(ProbeResult)
    /// `detail`: the engine's own words, for failures with no friendlier name.
    case failed(ProbeFailure, detail: String? = nil)
}

/// One proxy's detail page: what it is, and on-demand tests through it alone.
///
/// The TCP test is the engine's own delay test, against the URL the page's
/// group tests with, so it lands in the same history the group list shows.
/// The rest run inside the tunnel extension through `prober`. Leaving the
/// page (`stopAll`), or the VPN going down, ends whatever is running.
@MainActor
@Observable
final class ProxyDetailModel {
    let name: String
    /// Nil until the engine has described the proxy.
    private(set) var type: String?
    private(set) var udp: Bool?
    /// Tests need the engine; they are offered only while connected.
    private(set) var connected = false
    private(set) var probes: [ProxyProbe: ProbeState] = [:]

    /// The health-check URL of the group the page was opened from, if it has one.
    @ObservationIgnored private let testURL: String?
    @ObservationIgnored private let describe: @Sendable (String) async throws -> Proxy
    @ObservationIgnored private let tcpDelay: @Sendable (_ proxy: String, _ url: String) async throws -> Int
    @ObservationIgnored private let prober: ProxyProber
    @ObservationIgnored private var running: [ProxyProbe: Task<Void, Never>] = [:]
    /// The last download or upload started; the next one waits for it.
    @ObservationIgnored private var turnTail: Task<Void, Never>?

    init(
        name: String,
        testURL: String?,
        describe: @escaping @Sendable (String) async throws -> Proxy,
        tcpDelay: @escaping @Sendable (_ proxy: String, _ url: String) async throws -> Int,
        prober: ProxyProber,
    ) {
        self.name = name
        self.testURL = testURL
        self.describe = describe
        self.tcpDelay = tcpDelay
        self.prober = prober
    }

    /// Against the running engine: its controller describes the proxy and
    /// runs the TCP test, the tunnel extension runs the rest.
    convenience init(name: String, testURL: String?, api: MeowAPI) {
        self.init(
            name: name,
            testURL: testURL,
            describe: { try await api.getProxy(name: $0) },
            tcpDelay: { try await api.testDelay(proxy: $0, url: $1) },
            prober: .live(),
        )
    }

    func state(of probe: ProxyProbe) -> ProbeState {
        probes[probe] ?? .idle
    }

    /// The VPN came up or went down. Up, the engine describes the proxy;
    /// down, every running test ends.
    func setConnected(_ connected: Bool) async {
        self.connected = connected
        if connected {
            await loadDescription()
        } else {
            stopAll()
        }
    }

    /// A tap on a test. Ignored while that test runs or the VPN is down.
    func test(_ probe: ProxyProbe) {
        guard connected, running[probe] == nil else { return }
        probes[probe] = .running
        let previous = probe.takesTurns ? turnTail : nil
        let task = Task {
            _ = await previous?.value
            let outcome: ProbeState
            do {
                outcome = try await .done(measure(probe))
            } catch {
                outcome = Self.failure(error)
            }
            // Stopped: `stopAll` has already put the row back, and a new
            // run of the same test may own it by now.
            guard !Task.isCancelled else { return }
            probes[probe] = outcome
            running[probe] = nil
        }
        running[probe] = task
        if probe.takesTurns {
            turnTail = task
        }
    }

    /// Ends every running test, here and in the extension. Finished results stay.
    func stopAll() {
        for task in running.values {
            task.cancel()
        }
        running = [:]
        for (probe, state) in probes where state == .running {
            probes[probe] = .idle
        }
    }

    private func loadDescription() async {
        // The tests still run without it; the header just stays blank.
        guard let proxy = try? await describe(name) else { return }
        type = proxy.type
        udp = proxy.udp
    }

    private func measure(_ probe: ProxyProbe) async throws -> ProbeResult {
        // Stopped while waiting its turn.
        try Task.checkCancellation()
        switch probe {
        case .tcpLatency:
            let ms = try await tcpDelay(name, testURL ?? MeowAPI.delayTestURL)
            // The engine reports a test that got no answer in time as no delay.
            guard ms > 0 else {
                throw ProxyProbeError(message: "no answer in time", code: ProxyProbeError.timeout)
            }
            return .latency(ms: ms)
        case .udpLatency:
            return try await .latency(ms: prober.udpLatency(proxy: name))
        case .exitIP:
            return try await .exit(ExitIPLookup(fetcher: prober.exitIPFetcher(proxy: name)).lookup())
        case .nat:
            return try await .nat(prober.natType(proxy: name))
        case .download:
            return try await .bandwidth(prober.download(proxy: name))
        case .upload:
            return try await .bandwidth(prober.upload(proxy: name))
        }
    }

    private static func failure(_ error: any Error) -> ProbeState {
        if let probeError = error as? ProxyProbeError {
            switch probeError.code {
            case ProxyProbeError.timeout: return .failed(.timedOut)
            case ProxyProbeError.udpUnsupported: return .failed(.udpUnsupported)
            default: return .failed(.failed, detail: probeError.message)
            }
        }
        if case let .http(status)? = error as? MeowAPIError {
            // The engine's delay test answers a timeout with a bare 504.
            return status == 504 ? .failed(.timedOut) : .failed(.failed, detail: "HTTP \(status)")
        }
        return .failed(.failed, detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}

/// The classic cone / symmetric names, which is what users look the result up by.
enum NatClass: Equatable {
    case fullCone, restrictedCone, portRestrictedCone
    /// Endpoint-independent mapping, filtering not measured.
    case cone
    case symmetric, unknown
}

extension NatType {
    var natClass: NatClass {
        switch mapping {
        case .endpointIndependent:
            switch filtering {
            case .endpointIndependent: .fullCone
            case .addressDependent: .restrictedCone
            case .addressAndPortDependent: .portRestrictedCone
            case .dependent, .unknown: .cone
            }
        case .addressDependent, .addressAndPortDependent, .dependent: .symmetric
        case .unknown: .unknown
        }
    }
}
