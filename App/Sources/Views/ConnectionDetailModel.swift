import Foundation
import Observation

/// The engine's names for a route no listed rule chose (meow-tunnel
/// `resolve_proxy`).
enum UnlistedRoute: String {
    /// No rule matched, so the flow went DIRECT.
    case final = "Final"
    /// Global route mode: everything through the GLOBAL group.
    case global = "Global"
    /// Direct route mode.
    case direct = "Direct"

    init?(_ connection: Connection) {
        self.init(rawValue: connection.rule)
    }
}

/// The far end of a connection, as far as this device can tell.
enum RemoteIP: Equatable {
    /// `ip` is where the flow went: the engine's destination IP, or, when
    /// the engine dialed a host name DIRECT without reporting one
    /// (`fromDNSCache`), what its DNS cache holds for the name. `geo`
    /// arrives after `ip`.
    case known(ip: String, fromDNSCache: Bool, geo: IPGeo?)
    /// The proxy server resolves the host name; this device never learns
    /// the address.
    case resolvedByProxy
}

/// What a connection's detail page reads from the engine.
struct ConnectionDetailSources: Sendable {
    var connections: @Sendable () async throws -> [Connection]
    var rules: @Sendable () async throws -> [Rule]
    var proxies: @Sendable () async throws -> [String: Proxy]
    /// The engine's DNS cache entries matching a host name.
    var dnsCache: @Sendable (_ host: String) async throws -> [DnsResult]
    var ipGeo: @Sendable (_ ip: String) async -> IPGeo
    var close: @Sendable (_ id: String) async throws -> Void

    static func live(api: MeowAPI) -> Self {
        .init(
            connections: { try await api.getConnections().connections ?? [] },
            rules: { try await api.getRules().rules },
            proxies: { try await api.getProxies().proxies },
            dnsCache: { try await api.getDnsResults(search: $0) },
            ipGeo: { await IPGeoLookup.lookup($0) },
            close: { try await api.closeConnection(id: $0) },
        )
    }
}

/// One connection's detail page: where it went, and which rule sent it there.
///
/// Opens on the list's snapshot and polls `/connections` while shown, so the
/// traffic keeps counting, and a connection that closes under the page
/// turns into a closed one with its last numbers kept.
@MainActor
@Observable
final class ConnectionDetailModel {
    /// The latest snapshot that listed the connection.
    private(set) var connection: Connection
    /// When a poll last listed it, once it has closed; nil while it is open.
    /// `/connections` does not report a close time, so it closed somewhere
    /// after this.
    private(set) var lastSeen: Date?
    /// The matched rule's place in the engine's rule list (0-based), once
    /// found.
    private(set) var ruleIndex: Int?
    /// Nil until worked out, and when there is nothing to say (no host,
    /// rejected…).
    private(set) var remote: RemoteIP?
    /// When the flow opened; nil if the engine's timestamp does not parse.
    let started: Date?

    var active: Bool {
        lastSeen == nil
    }

    @ObservationIgnored private let sources: ConnectionDetailSources
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// When a poll last listed the connection; to begin with, the list's.
    @ObservationIgnored private var lastListed: Date
    /// Closed from this page: a poll already in flight must not reopen it.
    @ObservationIgnored private var closedHere = false

    init(
        connection: Connection,
        sources: ConnectionDetailSources,
        clock: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.connection = connection
        started = connection.startDate
        self.sources = sources
        self.clock = clock
        lastListed = clock()
    }

    convenience init(connection: Connection, api: MeowAPI) {
        self.init(connection: connection, sources: .live(api: api))
    }

    /// Looks up the rule and the far end once, both fixed when the flow
    /// opened, and polls every second until cancelled.
    func run() async {
        async let rule: Void = findRule()
        async let remote: Void = findRemote()
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1))
        }
        _ = await (rule, remote)
    }

    func refresh() async {
        let id = connection.id
        let listed: Connection?
        do {
            listed = try await sources.connections().first { $0.id == id }
        } catch is URLError {
            // The controller is gone (VPN stopped), and its flows with it.
            // A later poll that lists this one puts it back.
            listed = nil
        } catch {
            return
        }
        if let listed, !closedHere {
            connection = listed
            lastSeen = nil
            lastListed = clock()
        } else if lastSeen == nil {
            lastSeen = lastListed
        }
    }

    /// Closes the connection; the page shows it closed at once.
    func close() async {
        guard active else { return }
        closedHere = true
        lastSeen = clock()
        try? await sources.close(connection.id)
    }

    // The page reruns these each time it comes back into view (from Rules);
    // what an earlier run found stays.

    private func findRule() async {
        let connection = connection
        guard ruleIndex == nil, !connection.rule.isEmpty, UnlistedRoute(connection) == nil,
              let rules = try? await sources.rules()
        else { return }
        ruleIndex = rules.indexOfMatch(connection)
    }

    private func findRemote() async {
        if remote == nil {
            remote = await remoteIP(of: connection)
        }
        guard case let .known(ip, fromDNSCache, .none) = remote else { return }
        let geo = await sources.ipGeo(ip)
        remote = .known(ip: ip, fromDNSCache: fromDNSCache, geo: geo)
    }

    /// Where `connection` went, when the engine did not report the address:
    /// a host name dialed DIRECT was resolved by the engine, so its DNS cache
    /// still holds the answer while the record lives; any other policy hands
    /// the name to a proxy server. Nil when there is nothing to say, e.g.
    /// the flow was rejected or the engine is gone.
    private func remoteIP(of connection: Connection) async -> RemoteIP? {
        guard let meta = connection.metadata else { return nil }
        if let ip = meta.destinationIP, !ip.isEmpty {
            return .known(ip: ip, fromDNSCache: false, geo: nil)
        }
        guard !meta.host.isEmpty, let policy = connection.chains.last else { return nil }
        do {
            switch try await sources.proxies().leafType(of: policy) {
            case "Direct":
                let cached = try await sources.dnsCache(meta.host).ip(of: meta.host)
                return cached.map { RemoteIP.known(ip: $0, fromDNSCache: true, geo: nil) }
            case nil, "Reject", "RejectDrop":
                return nil
            default:
                return .resolvedByProxy
            }
        } catch {
            return nil
        }
    }
}

extension Connection {
    /// `start` as a date: RFC 3339 from current engines, epoch seconds from
    /// older ones.
    var startDate: Date? {
        if let seconds = TimeInterval(start) {
            return Date(timeIntervalSince1970: seconds)
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: start) {
            return date
        }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: start)
    }
}

extension [Rule] {
    /// Where `connection`'s rule sits in the engine's rule list: the first
    /// rule of its type and payload that targets its policy, as matching
    /// runs top-down. Nil when there is none, e.g. after a config reload.
    func indexOfMatch(_ connection: Connection) -> Int? {
        guard let policy = connection.chains.last else { return nil }
        return firstIndex {
            $0.type == connection.rule && $0.payload == connection.rulePayload && $0.proxy == policy
        }
    }
}

extension [String: Proxy] {
    /// The type of the proxy `name` currently routes through: a group's
    /// selection, followed down to a leaf. Nil when `name` is unknown or
    /// the groups loop.
    func leafType(of name: String) -> String? {
        var current = name
        for _ in 0 ..< 16 {
            guard let proxy = self[current] else { return nil }
            // A group without a single pick (load-balance) stands for its
            // members.
            guard let now = proxy.now, !now.isEmpty else { return proxy.type }
            current = now
        }
        return nil
    }
}

extension [DnsResult] {
    /// The first address the cache holds for exactly `host`; the engine's
    /// search also matches substrings.
    func ip(of host: String) -> String? {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return first {
            $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .caseInsensitiveCompare(name) == .orderedSame && !$0.ips.isEmpty
        }?.ips.first
    }
}
