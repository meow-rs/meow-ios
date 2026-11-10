import Foundation
import Observation

/// The engine's traffic ledger for one span of days, grouped by host, policy
/// or network, optionally narrowed by `filter` to a row picked on the page
/// before. Read from the database the PacketTunnel keeps in the App Group,
/// so it also opens while the VPN is down; re-read every `pollInterval`
/// while shown, as the engine writes about once a minute.
@MainActor
@Observable
final class TrafficLedgerModel {
    static let pollInterval: Duration = .seconds(15)

    /// Reads a span of days grouped by a grouping, narrowed by a filter.
    typealias Read = @Sendable (_ days: ClosedRange<Int>, _ group: TrafficGroup, _ filter: TrafficFilter)
        async throws -> TrafficReport

    /// A period and a grouping: what a report answers.
    struct Query: Hashable, Sendable {
        var period: TrafficPeriod
        var group: TrafficGroup
    }

    let filter: TrafficFilter
    var period: TrafficPeriod
    /// One of `groups`.
    var group: TrafficGroup
    /// Nil until the first read, and after a failed read of a query no
    /// report answered yet.
    private(set) var report: TrafficReport?
    /// Why the ledger could not be read; shown only while there is no
    /// report.
    private(set) var error: String?
    /// Why the last clear failed, until dismissed.
    var clearError: String?
    /// The query `report` answers.
    private(set) var shown: Query?

    @ObservationIgnored private let read: Read
    @ObservationIgnored private let clearLedger: @Sendable () async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: @Sendable () -> Calendar

    init(
        filter: TrafficFilter = TrafficFilter(),
        period: TrafficPeriod = .today,
        group: TrafficGroup = .host,
        read: @escaping Read,
        clear: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { .current },
    ) {
        self.filter = filter
        self.period = period
        // A row's page groups by what is left of the grouping it was
        // opened from.
        self.group = filter.groups.contains(group) ? group : filter.groups.first ?? group
        self.read = read
        clearLedger = clear
        self.now = now
        self.calendar = calendar
    }

    convenience init(
        filter: TrafficFilter = TrafficFilter(),
        period: TrafficPeriod = .today,
        group: TrafficGroup = .host,
    ) {
        self.init(
            filter: filter,
            period: period,
            group: group,
            read: { days, group, filter in
                try await TrafficLedgerReader.read(
                    from: days.lowerBound,
                    to: days.upperBound,
                    by: group,
                    filter: filter,
                )
            },
            clear: { try await TrafficLedgerReader.clear() },
        )
    }

    /// What the page can group by: every grouping the filter leaves.
    var groups: [TrafficGroup] {
        filter.groups
    }

    var query: Query {
        Query(period: period, group: group)
    }

    /// Whether a row can open a page narrowed to it: that needs a grouping
    /// left to show it by, and a name, as the ledger reads an empty filter
    /// as none.
    func canOpen(_ row: TrafficLedgerRow) -> Bool {
        groups.count > 1 && !row.name.isEmpty
    }

    /// Reads `query`, then again every `pollInterval` until cancelled; the
    /// page restarts it whenever the period or the grouping changes.
    func run() async {
        let query = query
        while !Task.isCancelled {
            await poll(query)
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func poll(_ query: Query) async {
        let days = query.period.days(at: now(), calendar: calendar())
        do {
            let report = try await read(days, query.group, filter)
            try Task.checkCancellation()
            self.report = report
            shown = query
            error = nil
        } catch is CancellationError {
            // Restarted for another query, which reads for itself.
        } catch {
            guard !Task.isCancelled else { return }
            // A failed poll keeps the last report of this query; another
            // query's does not answer it.
            if shown != query {
                report = nil
                shown = query
            }
            self.error = error.localizedDescription
        }
    }

    /// Deletes the whole ledger, every period and filter, then reads again.
    func clear() async {
        do {
            try await clearLedger()
        } catch {
            clearError = error.localizedDescription
        }
        await poll(query)
    }
}
