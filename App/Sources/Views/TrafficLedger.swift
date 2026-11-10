import Foundation
import MeowModels

/// How the engine's traffic ledger groups a report. iOS cannot tell which
/// app opened a flow (the engine sees every flow come from the extension),
/// so unlike meow-android there is no App grouping.
enum TrafficGroup: String, CaseIterable, Hashable, Sendable {
    case host
    case policy
    /// The network the traffic went out on, as the PacketTunnel labels it
    /// (`TrafficNetwork`).
    case network = "interface"
}

/// One group of a `TrafficReport`: a host, a policy or a network.
struct TrafficLedgerRow: Decodable, Equatable, Identifiable, Sendable {
    /// A registrable domain or an IP address, a leaf proxy (`DIRECT` too),
    /// or a network label (`TrafficNetwork`). Empty for a flow with no host
    /// or traffic counted before the extension named the network;
    /// `otherIPs` for the bare addresses past a day's cap.
    let name: String
    let upload: Int64
    let download: Int64
    let requests: Int64

    var id: String {
        name
    }

    var total: Int64 {
        upload + download
    }

    static let otherIPs = "*"

    /// The IP addresses a day keeps apart before the rest fold into
    /// `otherIPs`, as `meow_common::traffic_ledger::MAX_IP_HOSTS`; the FFI
    /// test `the_ip_cap_matches_the_app` keeps the two equal.
    static let maxIPHosts = 8192
}

/// The traffic of a span of days, as `meow_common::traffic_ledger::Report`.
/// Grouped by policy, the rows can add up to more than the totals: a flow
/// whose proxy reaches its server through a `dialer-proxy` counts under
/// both, and the totals count it once.
struct TrafficReport: Equatable, Sendable {
    var upload: Int64 = 0
    var download: Int64 = 0
    var requests: Int64 = 0
    /// Largest first.
    var rows: [TrafficLedgerRow] = []

    var total: Int64 {
        upload + download
    }
}

/// The labels the PacketTunnel gives the engine for the network it goes out
/// on (`meow_engine_set_network_kind`), as meow-android does.
enum TrafficNetwork {
    static let wifi = "Wi-Fi"
    static let cellular = "Cellular"
    static let ethernet = "Ethernet"
    static let other = "Other"
}

/// The rows a page is narrowed to: those of one host, policy or network, or
/// of several.
struct TrafficFilter: Hashable, Sendable {
    var host: String?
    var policy: String?
    var network: String?

    /// The groupings the filter does not pin, which the page can still
    /// group by.
    var groups: [TrafficGroup] {
        TrafficGroup.allCases.filter { value(of: $0) == nil }
    }

    func value(of group: TrafficGroup) -> String? {
        switch group {
        case .host: host
        case .policy: policy
        case .network: network
        }
    }

    /// Also narrowed to the row `name` of `group`.
    func with(_ group: TrafficGroup, _ name: String) -> TrafficFilter {
        var filter = self
        switch group {
        case .host: filter.host = name
        case .policy: filter.policy = name
        case .network: filter.network = name
        }
        return filter
    }
}

/// The spans of days the page shows, in the device's calendar and zone,
/// which the PacketTunnel gives the engine for its days
/// (`meow_traffic_set_time_zone`).
enum TrafficPeriod: CaseIterable, Hashable, Sendable {
    case today, thisMonth, lastMonth

    /// The first and last day, both included, as the ledger counts days:
    /// local dates as days since 1970-01-01.
    func days(at now: Date, calendar: Calendar) -> ClosedRange<Int> {
        let today = Self.day(of: now, in: calendar.timeZone)
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? now
        switch self {
        case .today:
            return today ... today
        case .thisMonth:
            return Self.day(of: month, in: calendar.timeZone) ... today
        case .lastMonth:
            let end = month.addingTimeInterval(-1)
            let start = calendar.dateInterval(of: .month, for: end)?.start ?? end
            return Self.day(of: start, in: calendar.timeZone) ... Self.day(of: end, in: calendar.timeZone)
        }
    }

    /// The local date of `date` as days since 1970-01-01: the engine's
    /// `TimeZone::day`.
    static func day(of date: Date, in zone: TimeZone) -> Int {
        let local = date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
        return Int((local / 86400).rounded(.down))
    }
}

struct TrafficLedgerError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// Reads the engine's traffic ledger — every day's traffic by host, policy
/// and network, kept for 62 days — from the database the PacketTunnel keeps
/// in the App Group (`meow_traffic_read`), in this process, so the page also
/// opens while the VPN is down. The engine writes it about once a minute.
enum TrafficLedgerReader {
    static func read(
        from: Int,
        to: Int,
        by group: TrafficGroup,
        filter: TrafficFilter = TrafficFilter(),
        in dir: URL = AppGroup.meowConfigDir,
    ) async throws -> TrafficReport {
        let home = dir.path(percentEncoded: false)
        let json = await Task.detached(priority: .utility) {
            answer(home: home, from: from, to: to, by: group.rawValue, filter: filter)
        }.value
        return try decode(json)
    }

    /// Deletes everything the ledger holds, every day and row. The daily
    /// totals the app keeps itself (`DailyTraffic`) are not part of it.
    static func clear(in dir: URL = AppGroup.meowConfigDir) async throws {
        let home = dir.path(percentEncoded: false)
        let failure: String? = await Task.detached(priority: .utility) {
            // The error is the calling thread's: read it on this one.
            let rc = home.withCString { meow_traffic_clear($0) }
            return rc == 0 ? nil : meow_core_last_error().map { String(cString: $0) } ?? "clear failed"
        }.value
        if let failure {
            throw TrafficLedgerError(message: failure)
        }
    }

    static func decode(_ json: String) throws -> TrafficReport {
        struct Answer: Decodable {
            var upload: Int64?
            var download: Int64?
            var requests: Int64?
            var rows: [TrafficLedgerRow]?
            var error: String?
        }
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        } catch {
            throw TrafficLedgerError(message: error.localizedDescription)
        }
        if let error = answer.error {
            throw TrafficLedgerError(message: error)
        }
        return TrafficReport(
            upload: answer.upload ?? 0,
            download: answer.download ?? 0,
            requests: answer.requests ?? 0,
            rows: answer.rows ?? [],
        )
    }

    private static func answer(home: String, from: Int, to: Int, by: String, filter: TrafficFilter) -> String {
        let raw: UnsafeMutablePointer<CChar>? = home.withCString { home in
            by.withCString { by in
                (filter.host ?? "").withCString { host in
                    (filter.policy ?? "").withCString { policy in
                        (filter.network ?? "").withCString { network in
                            meow_traffic_read(
                                home,
                                Int32(clamping: from),
                                Int32(clamping: to),
                                by,
                                host,
                                policy,
                                network,
                            )
                        }
                    }
                }
            }
        }
        guard let raw else { return "{}" }
        defer { meow_string_free(raw) }
        return String(cString: raw)
    }
}
