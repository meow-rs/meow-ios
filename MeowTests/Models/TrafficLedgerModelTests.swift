import Foundation
@testable import meow_ios
import os
import Testing

private struct Read: Equatable, Sendable {
    var days: ClosedRange<Int>
    var group: TrafficGroup
    var filter: TrafficFilter
}

/// A ledger whose answer and failure the test sets, recording every read
/// and clear in order.
private final class Ledger: Sendable {
    private struct State {
        var report = TrafficReport()
        var reads: [Read] = []
        var clears = 0
        /// What every read fails with, while set.
        var failure: String?
        /// What a clear fails with, while set.
        var clearFailure: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var reads: [Read] {
        state.withLock { $0.reads }
    }

    var clears: Int {
        state.withLock { $0.clears }
    }

    func answer(_ report: TrafficReport) {
        state.withLock { $0.report = report }
    }

    func fail(_ message: String?) {
        state.withLock { $0.failure = message }
    }

    func failClear(_ message: String?) {
        state.withLock { $0.clearFailure = message }
    }

    func read(_ days: ClosedRange<Int>, _ group: TrafficGroup, _ filter: TrafficFilter) throws -> TrafficReport {
        try state.withLock { ledger in
            ledger.reads.append(Read(days: days, group: group, filter: filter))
            if let failure = ledger.failure {
                throw TrafficLedgerError(message: failure)
            }
            return ledger.report
        }
    }

    func clear() throws {
        try state.withLock { ledger in
            ledger.clears += 1
            if let failure = ledger.clearFailure {
                throw TrafficLedgerError(message: failure)
            }
            ledger.report = TrafficReport()
        }
    }
}

private func row(_ name: String, _ upload: Int64 = 1, _ download: Int64 = 2, requests: Int64 = 1) -> TrafficLedgerRow {
    TrafficLedgerRow(name: name, upload: upload, download: download, requests: requests)
}

/// Shanghai has no daylight saving, so its offset is +8 all year.
private let shanghai: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    shanghai.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// The Traffic page's reads of the engine's traffic ledger over a faked
/// one: periods as the engine counts days, polls, failures, drilling into a
/// row and clearing. Ported from meow-android's `TrafficDetailsViewModelTest`.
@MainActor
@Suite("TrafficLedgerModel", .tags(.model))
struct TrafficLedgerModelTests {
    private let ledger = Ledger()

    private func makeModel(
        filter: TrafficFilter = TrafficFilter(),
        period: TrafficPeriod = .today,
        group: TrafficGroup = .host,
        now: Date = local(2026, 11, 10),
    ) -> TrafficLedgerModel {
        let ledger = ledger
        return TrafficLedgerModel(
            filter: filter,
            period: period,
            group: group,
            read: { days, group, filter in try ledger.read(days, group, filter) },
            clear: { try ledger.clear() },
            now: { now },
            calendar: { shanghai },
        )
    }

    @Test
    func `periods are local dates as days since 1970`() {
        let now = local(2026, 11, 10)
        #expect(TrafficPeriod.today.days(at: now, calendar: shanghai) == 20767 ... 20767)
        #expect(TrafficPeriod.thisMonth.days(at: now, calendar: shanghai) == 20758 ... 20767)
        #expect(TrafficPeriod.lastMonth.days(at: now, calendar: shanghai) == 20727 ... 20757)
    }

    @Test
    func `just after local midnight is already the new day, in UTC still the old one`() {
        // 2026-10-31 16:30 UTC.
        let now = local(2026, 11, 1, 0, 30)
        #expect(TrafficPeriod.today.days(at: now, calendar: shanghai) == 20758 ... 20758)
        #expect(TrafficPeriod.thisMonth.days(at: now, calendar: shanghai) == 20758 ... 20758)
        #expect(TrafficPeriod.lastMonth.days(at: now, calendar: shanghai) == 20727 ... 20757)
    }

    @Test
    func `last month in January is December of the year before`() {
        let now = local(2026, 1, 15)
        #expect(TrafficPeriod.lastMonth.days(at: now, calendar: shanghai) == 20423 ... 20453)
        #expect(TrafficPeriod.thisMonth.days(at: now, calendar: shanghai) == 20454 ... 20468)
    }

    @Test
    func `reads the period and grouping, and keeps the last report when a poll fails`() async {
        ledger.answer(TrafficReport(upload: 1, download: 2, requests: 1, rows: [row("example.com")]))
        let model = makeModel()
        await model.poll(model.query)
        #expect(model.report?.rows.map(\.name) == ["example.com"])
        #expect(ledger.reads == [Read(days: 20767 ... 20767, group: .host, filter: TrafficFilter())])

        ledger.fail("database is locked")
        await model.poll(model.query)
        #expect(model.report?.rows.map(\.name) == ["example.com"], "a failed poll keeps what it showed")
        #expect(model.error == "database is locked")

        // Another period's failed read has no report to keep.
        model.period = .lastMonth
        await model.poll(model.query)
        #expect(model.report == nil)
        #expect(model.error == "database is locked")
        #expect(ledger.reads.last?.days == 20727 ... 20757)

        ledger.fail(nil)
        await model.poll(model.query)
        #expect(model.report != nil)
        #expect(model.error == nil)
    }

    @Test
    func `a row's page groups by what its filter leaves`() {
        #expect(TrafficFilter().groups == [.host, .policy, .network])
        let host = TrafficFilter().with(.host, "example.com")
        #expect(host.groups == [.policy, .network])
        #expect(host.with(.network, "Wi-Fi").groups == [.policy])

        let model = makeModel(filter: host, group: .host)
        #expect(model.group == .policy, "the grouping it was opened from is pinned")
        #expect(model.canOpen(row("HK 01")))
        #expect(!model.canOpen(row("")), "an empty filter reads as none")

        let last = makeModel(filter: host.with(.network, "Wi-Fi"), group: .policy)
        #expect(last.group == .policy)
        #expect(!last.canOpen(row("HK 01")), "no grouping left to show it by")
    }

    @Test
    func `a narrowed page reads with its filter`() async {
        let filter = TrafficFilter(policy: "HK 01")
        let model = makeModel(filter: filter, period: .thisMonth, group: .network)
        await model.poll(model.query)
        #expect(ledger.reads == [Read(days: 20758 ... 20767, group: .network, filter: filter)])
    }

    @Test
    func `clearing deletes the ledger and reads again`() async {
        ledger.answer(TrafficReport(upload: 1, download: 2, requests: 1, rows: [row("example.com")]))
        let model = makeModel()
        await model.poll(model.query)

        await model.clear()
        #expect(ledger.clears == 1)
        #expect(ledger.reads.count == 2)
        #expect(model.report?.rows.isEmpty == true)
        #expect(model.clearError == nil)

        ledger.failClear("read-only file system")
        await model.clear()
        #expect(model.clearError == "read-only file system")
    }

    @Test
    func `decodes the engine's report and its errors`() throws {
        let json = """
        {"from":"2026-11-10","to":"2026-11-10","by":"policy","upload":11,"download":22,"requests":2,
         "rows":[{"name":"HK 01","upload":11,"download":22,"requests":2,"via_upload":1,"via_download":2,
                  "via_requests":1},{"name":"JP 02","upload":1,"download":2,"requests":1}]}
        """
        let report = try TrafficLedgerReader.decode(json)
        #expect(report.total == 33)
        #expect(report.requests == 2)
        #expect(report.rows.map(\.name) == ["HK 01", "JP 02"])
        #expect(report.rows.first?.total == 33)

        #expect(throws: TrafficLedgerError.self) {
            try TrafficLedgerReader.decode(#"{"error":"unknown grouping"}"#)
        }
        #expect(throws: TrafficLedgerError.self) {
            try TrafficLedgerReader.decode("not json")
        }
    }

    @Test
    func `rows read in the user's language`() {
        #expect(TrafficNames.name(of: "", in: .host) == String(localized: "traffic.details.unknown"))
        #expect(TrafficNames.name(of: "*", in: .host) == String(localized: "traffic.details.otherIPs"))
        #expect(TrafficNames.name(of: "example.com", in: .host) == "example.com")
        #expect(TrafficNames.name(of: "", in: .policy) == String(localized: "traffic.details.unknown"))
        #expect(TrafficNames.name(of: "DIRECT", in: .policy) == "DIRECT")
        #expect(TrafficNames.name(of: "Wi-Fi", in: .network) == String(localized: "traffic.network.wifi"))
        #expect(TrafficNames.name(of: "Ethernet", in: .network) == String(localized: "traffic.network.ethernet"))
        #expect(TrafficNames.name(of: "Cellular", in: .network) == String(localized: "statistics.cellular"))
        #expect(TrafficNames.name(of: "", in: .network) == String(localized: "statistics.otherNetworks"))
        #expect(TrafficNames.name(of: "en0", in: .network) == "en0")
    }
}
