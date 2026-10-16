import Foundation

struct Proxy: Decodable, Identifiable {
    var id: String {
        name
    }

    let name: String
    let type: String
    let now: String?
    let all: [String]?
    let history: [History]?
    /// Whether the proxy relays UDP. Nil from engines that predate the field.
    var udp: Bool?
    /// A group's health-check URL; nil for plain proxies and for groups
    /// without one.
    var testUrl: String?

    /// `history[].time` is deliberately not decoded: the UI only reads
    /// `delay`, and the engine's `time` wire format changed once already
    /// (serde's default `SystemTime` object → RFC 3339 string, meow-rs
    /// #290). Decoding it made the WHOLE /proxies payload undecodable the
    /// moment any probe recorded history — proxy groups froze with no
    /// delays (issue #255 follow-up).
    struct History: Decodable {
        let delay: Int
    }
}

struct ProxiesResponse: Decodable {
    let proxies: [String: Proxy]
}

struct Connection: Decodable, Identifiable {
    let id: String
    // Optional so an idle engine (or an older build without meow-rs#241,
    // which added the block) still decodes.
    let metadata: Metadata?
    let upload: Int64
    let download: Int64
    let start: String
    let chains: [String]
    let rule: String
    let rulePayload: String

    /// Only the fields ConnectionsView and ConnectionDetailView read — same
    /// lesson as `Proxy.History.time` above: every extra field decoded here
    /// is a way for the WHOLE /connections payload to become undecodable.
    /// meow-rs serializes `Metadata` (meow-common metadata.rs) with ports as
    /// JSON numbers (`u16`) and `sourceIP`/`destinationIP` as nullable —
    /// decoding the port as `String` blanked the screen the moment any
    /// connection was active. Every field here is optional on the wire.
    struct Metadata: Decodable {
        let network: String
        let host: String
        /// Kept as `String` for display; accepts both the engine's numeric
        /// port and mihomo-compat string ports.
        let destinationPort: String
        /// Nullable on the wire (`Option<IpAddr>`); shown when `host` is
        /// empty (no SNI/DNS sniff, direct-IP connection). The engine clears
        /// it when it turns a fake IP back into `host`.
        let destinationIP: String?
        /// Nullable on the wire. Loopback on iOS: tun2socks hands every flow
        /// to the engine's local mixed listener.
        let sourceIP: String?
        /// `normal`, `fake-ip`, or `mapping` (what configs call redir-host).
        let dnsMode: String
        /// The host name sniffed from the first bytes (TLS SNI, HTTP Host);
        /// empty when sniffing is off or found nothing.
        let sniffHost: String

        init(
            network: String,
            host: String,
            destinationPort: String,
            destinationIP: String?,
            sourceIP: String? = nil,
            dnsMode: String = "",
            sniffHost: String = "",
        ) {
            self.network = network
            self.host = host
            self.destinationPort = destinationPort
            self.destinationIP = destinationIP
            self.sourceIP = sourceIP
            self.dnsMode = dnsMode
            self.sniffHost = sniffHost
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ConnectionMetadataKeys.self)
            network = try container.decodeIfPresent(String.self, forKey: .network) ?? ""
            host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
            destinationIP = try container.decodeIfPresent(String.self, forKey: .destinationIP)
            sourceIP = try? container.decodeIfPresent(String.self, forKey: .sourceIP)
            dnsMode = (try? container.decodeIfPresent(String.self, forKey: .dnsMode)) ?? ""
            sniffHost = (try? container.decodeIfPresent(String.self, forKey: .sniffHost)) ?? ""
            if let port = try? container.decode(String.self, forKey: .destinationPort) {
                destinationPort = port
            } else if let port = try? container.decode(Int.self, forKey: .destinationPort) {
                destinationPort = String(port)
            } else {
                destinationPort = ""
            }
        }
    }
}

/// Top-level so `Connection.Metadata` stays within swiftlint's 1-level
/// type-nesting budget.
private enum ConnectionMetadataKeys: String, CodingKey {
    case network, host, destinationPort, destinationIP, sourceIP, dnsMode, sniffHost
}

struct ConnectionsResponse: Decodable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [Connection]?

    init(downloadTotal: Int64, uploadTotal: Int64, connections: [Connection]?) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
    }

    /// The engine has spelled the totals both ways: meow-rs 498967e emitted
    /// serde's default `download_total` / `upload_total`, and the 0.21.2 pin
    /// (`a663364`, meow-api routes.rs `#[serde(rename_all = "camelCase")]`)
    /// emits mihomo's `downloadTotal` / `uploadTotal`. Requiring either
    /// spelling threw `keyNotFound` ("data is missing") and blanked the
    /// Connections screen — the same whole-payload failure as
    /// `Proxy.History.time` and `Metadata.destinationPort`. The UI does not
    /// read the totals, so accept both and default to 0.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ConnectionsResponseKeys.self)
        downloadTotal = try container.decodeIfPresent(Int64.self, forKey: .downloadTotal)
            ?? container.decodeIfPresent(Int64.self, forKey: .downloadTotalSnake)
            ?? 0
        uploadTotal = try container.decodeIfPresent(Int64.self, forKey: .uploadTotal)
            ?? container.decodeIfPresent(Int64.self, forKey: .uploadTotalSnake)
            ?? 0
        connections = try container.decodeIfPresent([Connection].self, forKey: .connections)
    }
}

/// Top-level so `ConnectionsResponse` stays within swiftlint's 1-level
/// type-nesting budget.
private enum ConnectionsResponseKeys: String, CodingKey {
    case downloadTotal
    case uploadTotal
    case downloadTotalSnake = "download_total"
    case uploadTotalSnake = "upload_total"
    case connections
}

struct Rule: Decodable, Identifiable {
    var id: String {
        "\(type)\(payload)\(proxy)"
    }

    let type: String
    let payload: String
    let proxy: String
}

struct RulesResponse: Decodable {
    let rules: [Rule]
}

struct Provider: Decodable {
    let name: String
    let type: String
    let vehicleType: String?
    let proxies: [Proxy]?
}

struct ProvidersResponse: Decodable {
    let providers: [String: Provider]
}

struct ConfigsResponse: Decodable {
    let mode: String
}

struct LogEntry: Decodable {
    let type: String
    let payload: String

    static func from(jsonString: String) -> LogEntry? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LogEntry.self, from: data)
    }
}

/// Cached DNS lookup surfaced by `GET /dns/results` (meow-api routes.rs).
struct DnsResult: Decodable, Identifiable {
    var id: String {
        name
    }

    let name: String
    let ips: [String]
    let fromServer: String?
    let ttl: UInt64

    enum CodingKeys: String, CodingKey {
        case name, ips, ttl
        case fromServer = "from_server"
    }
}
