import Foundation

/// Payload used between the app's proxy detail page and the PacketTunnel
/// extension's `handleAppMessage` for per-node diagnostics. Each probe dials
/// one named proxy of the running engine directly (`meow_probe_proxy`), so
/// it has to run inside the extension, where the engine and its proxies
/// live.
///
/// - `0x05` + JSON ``ProxyProbeRequest`` — run one probe. The extension
///   answers when the probe ends (20 s at most) with the FFI's JSON answer
///   verbatim: a measurement, or `{"error": …, "code": …}`.
/// - `0x06` + JSON `{"id": …}` — end probe `id` early. Its `0x05` call then
///   answers with code `cancelled`. A cancel that reaches the extension
///   before its probe still ends that probe.
///
/// Tags extend `ProxyControlIPC`'s 0x04 without collision.
public enum ProxyProbeIPC {
    public static let probeTag: UInt8 = 0x05
    public static let cancelTag: UInt8 = 0x06

    public static func encodeProbe(_ request: ProxyProbeRequest) throws -> Data {
        try tagged(probeTag, request)
    }

    public static func encodeCancel(id: Int64) throws -> Data {
        try tagged(cancelTag, ProxyProbeCancel(id: id))
    }

    public static func isProbe(_ data: Data) -> Bool {
        data.count >= 2 && data.first == probeTag
    }

    public static func isCancel(_ data: Data) -> Bool {
        data.count >= 2 && data.first == cancelTag
    }

    public static func decodeProbe(_ data: Data) throws -> ProxyProbeRequest {
        guard isProbe(data) else {
            throw ProxyProbeIPCError.tagMismatch
        }
        return try JSONDecoder().decode(ProxyProbeRequest.self, from: Data(data.dropFirst()))
    }

    public static func decodeCancel(_ data: Data) throws -> Int64 {
        guard isCancel(data) else {
            throw ProxyProbeIPCError.tagMismatch
        }
        return try JSONDecoder().decode(ProxyProbeCancel.self, from: Data(data.dropFirst())).id
    }

    private static func tagged(_ tag: UInt8, _ body: some Encodable) throws -> Data {
        var data = Data([tag])
        try data.append(JSONEncoder().encode(body))
        return data
    }
}

/// What a probe measures, by its wire name in `meow_probe_proxy`.
public enum ProxyProbeKind: String, Codable, Sendable, CaseIterable {
    /// A DNS query's round trip over the node's UDP relay.
    case udpLatency = "udp-latency"
    /// A GET of `arg` through the node (the exit-IP lookup).
    case httpGet = "http-get"
    /// The NAT behaviour the node's UDP relay presents (RFC 5780).
    case nat
    case download
    case upload
}

public struct ProxyProbeRequest: Codable, Sendable, Equatable {
    /// Names the probe for a later cancel. Kept below 2^53 by the app so it
    /// survives `NSJSONSerialization` in the extension exactly.
    public var id: Int64
    /// The proxy's name, matched byte-for-byte against the engine's proxies.
    public var proxy: String
    public var kind: ProxyProbeKind
    public var arg: String

    public init(id: Int64, proxy: String, kind: ProxyProbeKind, arg: String = "") {
        self.id = id
        self.proxy = proxy
        self.kind = kind
        self.arg = arg
    }
}

private struct ProxyProbeCancel: Codable {
    var id: Int64
}

public enum ProxyProbeIPCError: Error, Sendable {
    case tagMismatch
}
