import Foundation
import MeowIPC
import NetworkExtension
import os

/// Carries probes to the PacketTunnel extension, where the engine and its
/// proxies live (`ProxyProbeIPC`).
protocol ProxyProbeTransport: Sendable {
    /// Runs one probe and returns its JSON answer, once the probe has ended.
    /// Throws when the extension cannot be reached.
    func probe(_ request: ProxyProbeRequest) async throws -> Data

    /// Ends probe `id` early; a no-op once it has ended.
    func cancel(id: Int64) async
}

/// A probe that ran and measured nothing. `code` says why, as the engine
/// side reports it.
struct ProxyProbeError: Error, LocalizedError, Equatable {
    static let timeout = "timeout"
    static let udpUnsupported = "udp-unsupported"
    static let engineStopped = "engine-stopped"
    static let failed = "failed"

    let message: String
    let code: String

    var errorDescription: String? {
        message
    }
}

/// How a NAT treats one internal endpoint's traffic (RFC 4787 terms).
enum NatBehavior: String {
    case endpointIndependent = "endpoint-independent"
    case addressDependent = "address-dependent"
    case addressAndPortDependent = "address-and-port-dependent"
    /// Depends on the destination, but servers without RFC 5780 cannot tell how.
    case dependent
    case unknown

    init(wire: String?) {
        self = wire.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

/// The NAT a proxy's UDP relay presents, as STUN servers saw it.
struct NatType: Equatable {
    let mapping: NatBehavior
    let filtering: NatBehavior
    /// The relay's public address, `ip:port`.
    let mappedAddress: String?
    let server: String?
    /// The relay does not report where replies come from, so no test could
    /// tell its filtering (or mapping) apart.
    let sourceHidden: Bool
}

/// `bytes` moved in `millis`.
struct Throughput: Equatable {
    let bytes: Int64
    let millis: Int64

    var bitsPerSecond: Double {
        Double(bytes) * 8000 / Double(max(millis, 1))
    }
}

struct ProbeHTTPResponse: Equatable {
    let status: Int
    let body: String
}

/// Diagnostics through one named proxy of the running engine, for the proxy
/// detail page. Each call dials that proxy directly — rules and group
/// selections play no part — and measures inside the extension, so the
/// numbers are the proxy's own rather than the tunnel's.
///
/// Cancelling the calling task ends the probe in the extension as well,
/// rather than leaving it to run out its budget there.
struct ProxyProber: Sendable {
    /// The extension keys running probes by id and outlives this process, so
    /// ids start at random: a relaunched app must not reuse the id of a probe
    /// its predecessor left running. Below 2^52 so they stay exact through
    /// `NSJSONSerialization` on the extension side.
    private static let ids = OSAllocatedUnfairLock(initialState: Int64.random(in: 1 ..< 1 << 51))

    let transport: any ProxyProbeTransport

    /// Over the tunnel extension; canned answers in the simulator, where no
    /// engine runs (same switch as `MeowAPI.usesMockTransport`).
    static func live() -> ProxyProber {
        ProxyProber(transport: MeowAPI.usesMockTransport ? MockProxyProbeTransport() : TunnelProxyProbeTransport())
    }

    /// A DNS query's round trip over the proxy's UDP relay, dial included.
    func udpLatency(proxy: String) async throws -> Int {
        try await Int(run(proxy, .udpLatency).require(\.ms, "ms"))
    }

    /// A GET of `url` through `proxy`; any status is an answer.
    func get(proxy: String, url: URL) async throws -> ProbeHTTPResponse {
        let answer = try await run(proxy, .httpGet, url.absoluteString)
        return try ProbeHTTPResponse(status: answer.require(\.status, "status"), body: answer.body ?? "")
    }

    func natType(proxy: String) async throws -> NatType {
        let answer = try await run(proxy, .nat)
        return NatType(
            mapping: NatBehavior(wire: answer.mapping),
            filtering: NatBehavior(wire: answer.filtering),
            mappedAddress: answer.mapped,
            server: answer.server,
            sourceHidden: answer.note == "source-hidden",
        )
    }

    func download(proxy: String) async throws -> Throughput {
        try await run(proxy, .download).throughput()
    }

    func upload(proxy: String) async throws -> Throughput {
        try await run(proxy, .upload).throughput()
    }

    /// Fetches exit-IP sources through `proxy` instead of the app's sockets.
    func exitIPFetcher(proxy: String) -> @Sendable (URL) async throws -> String {
        { url in
            let response = try await get(proxy: proxy, url: url)
            // Rate limits come back as 403 (ip.sb) or 429 (ipinfo.io).
            guard (200 ..< 300).contains(response.status) else {
                throw ExitIPLookupError(message: "\(url.host() ?? "?") returned HTTP \(response.status)")
            }
            return response.body
        }
    }

    private func run(_ proxy: String, _ kind: ProxyProbeKind, _ arg: String = "") async throws -> ProbeAnswer {
        let id = Self.ids.withLock { id in
            id += 1
            return id
        }
        let request = ProxyProbeRequest(id: id, proxy: proxy, kind: kind, arg: arg)
        let transport = transport
        // The call returns once the extension has ended the probe, so
        // nothing outlives the caller.
        let data = try await withTaskCancellationHandler {
            try await transport.probe(request)
        } onCancel: {
            Task { await transport.cancel(id: id) }
        }
        guard let answer = try? JSONDecoder().decode(ProbeAnswer.self, from: data) else {
            throw ProxyProbeError(message: "unreadable \(kind.rawValue) answer", code: ProxyProbeError.failed)
        }
        if let message = answer.error {
            throw ProxyProbeError(message: message, code: answer.code ?? ProxyProbeError.failed)
        }
        return answer
    }
}

/// Every field any probe answers with; each kind fills its own.
private struct ProbeAnswer: Decodable {
    let error: String?
    let code: String?
    let ms: Int64?
    let status: Int?
    let body: String?
    let bytes: Int64?
    let mapping: String?
    let filtering: String?
    let mapped: String?
    let server: String?
    let note: String?

    func require<T>(_ field: KeyPath<ProbeAnswer, T?>, _ name: String) throws -> T {
        guard let value = self[keyPath: field] else {
            throw ProxyProbeError(message: "probe answer has no \(name)", code: ProxyProbeError.failed)
        }
        return value
    }

    func throughput() throws -> Throughput {
        try Throughput(bytes: require(\.bytes, "bytes"), millis: require(\.ms, "ms"))
    }
}

/// `sendProviderMessage` to the running tunnel's extension.
struct TunnelProxyProbeTransport: ProxyProbeTransport {
    func probe(_ request: ProxyProbeRequest) async throws -> Data {
        try await send(ProxyProbeIPC.encodeProbe(request))
    }

    func cancel(id: Int64) async {
        guard let payload = try? ProxyProbeIPC.encodeCancel(id: id) else { return }
        _ = try? await send(payload)
    }

    private func send(_ payload: Data) async throws -> Data {
        guard let session = await MeowAPI.tunnelSession() else {
            throw ProxyProbeError(message: "the VPN is not running", code: ProxyProbeError.engineStopped)
        }
        return try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(payload) { data in
                    if let data {
                        cont.resume(returning: data)
                    } else {
                        // An extension too old to know the tag answers nil.
                        cont.resume(throwing: ProxyProbeError(
                            message: "no answer from the tunnel extension",
                            code: ProxyProbeError.failed,
                        ))
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Canned answers for the simulator, which runs no engine — enough for UI
/// tests and screenshots to show every row filled in.
struct MockProxyProbeTransport: ProxyProbeTransport {
    func probe(_ request: ProxyProbeRequest) async throws -> Data {
        try await Task.sleep(for: .milliseconds(600))
        let answer = switch request.kind {
        case .udpLatency:
            #"{"ms":64}"#
        case .httpGet:
            #"{"status":200,"body":"{\"ip\":\"203.0.113.7\",\"country_code\":\"JP\",\"country\":\"Japan\","#
                + #"\"asn\":64500,\"isp\":\"Example Networks\"}"}"#
        case .nat:
            #"{"mapping":"endpoint-independent","filtering":"address-and-port-dependent","#
                + #""mapped":"203.0.113.7:40000","server":"stun.example.net:3478"}"#
        case .download:
            #"{"bytes":50000000,"ms":4210}"#
        case .upload:
            #"{"bytes":16777216,"ms":2630}"#
        }
        return Data(answer.utf8)
    }

    func cancel(id _: Int64) async {}
}
