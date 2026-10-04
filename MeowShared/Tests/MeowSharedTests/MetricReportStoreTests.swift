import Foundation
@testable import MeowModels
import Testing

struct MetricReportStoreTests {
    private func makeStore() -> MetricReportStore {
        MetricReportStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "metric-report-store-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func summary(day: Int, peak: Double = 30_000_000) -> MetricSummary {
        let end = Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86400)
        var summary = MetricSummary(begin: end.addingTimeInterval(-86400), end: end)
        summary.peakMemoryBytes = peak
        summary.cpuTimeSeconds = 42
        summary.foregroundExits = ["normal": 3, "memoryLimit": 1]
        summary.backgroundExits = ["normal": 1, "memoryLimit": 2, "watchdog": 1]
        return summary
    }

    private func rawPayload(_ tag: Int) -> Data {
        let end = "2026-10-0\(tag) 00:00:00 +0000"
        return Data(#"{"timeStampEnd":"\#(end)","memoryMetrics":{"peakMemoryUsage":"30,000 kB"}}"#.utf8)
    }

    @Test func `saved record round trips`() throws {
        let store = makeStore()
        try store.save(source: .app, summary: summary(day: 1), payload: rawPayload(1))
        let record = try #require(store.records().first)
        #expect(record.source == .app)
        #expect(record.summary == summary(day: 1))
        #expect(record.url.lastPathComponent == MetricReportStore.fileName(for: rawPayload(1)))
        // The raw payload rides along for sharing.
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: record.url)) as? [String: Any]
        #expect(envelope?["payload"] is [String: Any])
    }

    @Test func `same payload twice keeps one file`() throws {
        let store = makeStore()
        try store.save(source: .app, summary: summary(day: 1), payload: rawPayload(1))
        try store.save(source: .app, summary: summary(day: 1), payload: rawPayload(1))
        #expect(store.records().count == 1)
    }

    @Test func `decodes the tunnel envelope`() throws {
        // The shape MWMetricKitSubscriber.m writes: NSNumber values (integer
        // counts, fractional seconds), absent metrics left out.
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let json = #"""
        {"payload":{},"source":"tunnel","summary":{"begin":1790000000.5,"end":1790086400,
        "bundleIdentifier":"com.tangzixiang.meow.PacketTunnel","peakMemoryBytes":48234496,
        "cpuTimeSeconds":812.25,"backgroundExits":{"normal":0,"memoryLimit":3,"cpuLimit":0}}}
        """#
        try Data(json.utf8).write(to: store.directory.appending(path: "metrics-tunnel.json"))
        let record = try #require(store.records().first)
        #expect(record.source == .tunnel)
        #expect(record.summary.peakMemoryBytes == 48_234_496)
        #expect(record.summary.cpuTimeSeconds == 812.25)
        #expect(record.summary.exits(.memoryLimit) == 3)
        #expect(record.summary.launchMedianSeconds == nil)
    }

    @Test func `exit counts combine foreground and background`() {
        let s = summary(day: 1)
        #expect(s.exits(.memoryLimit) == 3)
        #expect(s.exits(.normal) == 4)
        #expect(s.abnormalExitCount == 4)
    }

    @Test func `records are newest first and pruned`() throws {
        let store = makeStore()
        for day in 0 ..< MetricReportStore.maxReports + 2 {
            try store.save(source: .tunnel, summary: summary(day: day), payload: Data("{\"d\":\(day)}".utf8))
        }
        let records = store.records()
        #expect(records.count == MetricReportStore.maxReports)
        #expect(records.first?.summary == summary(day: MetricReportStore.maxReports + 1))
        #expect(records.last?.summary == summary(day: 2))
    }

    @Test func `undecodable files are skipped`() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.directory.appending(path: "metrics-bad.json"))
        #expect(store.records().isEmpty)
    }
}
