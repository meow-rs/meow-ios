import Foundation
@testable import MeowModels
import Testing

struct CrashReportStoreTests {
    private func makeStore() -> CrashReportStore {
        CrashReportStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "crash-report-store-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func payload(end: String, crashes: Int = 1, hangs: Int = 0) throws -> Data {
        let crash: [String: Any] = ["diagnosticMetaData": [
            "bundleIdentifier": "com.tangzixiang.meow.PacketTunnel",
            "appVersion": "2.0",
            "appBuildVersion": "2026100401",
            "osVersion": "iPhone OS 26.0 (23A341)",
            "exceptionType": 1,
            "signal": 11,
            "terminationReason": "Namespace SIGNAL, Code 11",
        ]]
        let hang: [String: Any] = ["diagnosticMetaData": ["hangDuration": "3.2 sec"]]
        let root: [String: Any] = [
            "timeStampBegin": "2026-10-03 00:00:00 +0000",
            "timeStampEnd": end,
            "crashDiagnostics": Array(repeating: crash, count: crashes),
            "hangDiagnostics": Array(repeating: hang, count: hangs),
        ]
        return try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
    }

    @Test func `file name is truncated SHA 256`() {
        // Must match MWMetricKitSubscriber.fileNameForJSON: (CC_SHA256, 16 bytes).
        let name = CrashReportStore.fileName(for: Data(#"{"a":1}"#.utf8))
        #expect(name == "metrickit-015abd7f5cc57a2dd94b7590f04ad808.json")
    }

    @Test func `saving the same payload twice keeps one file`() throws {
        let store = makeStore()
        let json = try payload(end: "2026-10-03 12:00:00 +0000")
        try store.save(json)
        try store.save(json)
        #expect(store.reports().count == 1)
    }

    @Test func `reports are newest first with summaries`() throws {
        let store = makeStore()
        try store.save(payload(end: "2026-10-01 12:00:00 +0000"))
        try store.save(payload(end: "2026-10-03 12:00:00 +0000", crashes: 2, hangs: 1))
        let reports = store.reports()
        #expect(reports.count == 2)
        #expect(reports[0].date > reports[1].date)
        #expect(reports[0].count(of: .crash) == 2)
        #expect(reports[0].count(of: .hang) == 1)
        let crash = try #require(reports[0].diagnostics.first)
        #expect(crash.bundleIdentifier == "com.tangzixiang.meow.PacketTunnel")
        #expect(crash.appBuildVersion == "2026100401")
        #expect(crash.detail == "Namespace SIGNAL, Code 11 · exception 1 · signal 11")
        #expect(reports[0].diagnostics.last?.detail == "3.2 sec")
    }

    @Test func `empty and malformed payloads are skipped`() throws {
        let store = makeStore()
        try store.save(Data("not json".utf8))
        try store.save(payload(end: "2026-10-03 12:00:00 +0000", crashes: 0))
        #expect(store.reports().isEmpty)
    }

    @Test func `prune keeps the newest`() throws {
        let store = makeStore()
        for day in 1 ... CrashReportStore.maxReports + 3 {
            let end = String(format: "2026-%02d-%02d 12:00:00 +0000", 1 + day / 28, 1 + day % 28)
            try store.save(payload(end: end))
        }
        let reports = store.reports()
        #expect(reports.count == CrashReportStore.maxReports)
        let oldestKept = try #require(CrashReport.parseDate("2026-01-04 12:00:00 +0000"))
        #expect(reports.last.map { oldestKept <= $0.date } == true)
    }

    @Test func `delete all empties the store`() throws {
        let store = makeStore()
        try store.save(payload(end: "2026-10-03 12:00:00 +0000"))
        store.deleteAll()
        #expect(store.reports().isEmpty)
    }
}
