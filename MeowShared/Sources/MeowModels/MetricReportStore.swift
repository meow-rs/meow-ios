import CryptoKit
import Foundation

/// Daily MetricKit metric payloads (`MXMetricPayload`) saved by the app and
/// the packet-tunnel extension, one file per payload per process, under
/// `AppGroup.metricKitMetricsDirectoryURL`. Settings › Performance Metrics
/// reads them back.
///
/// Each file is a `MetricRecord` envelope: which process received it, a
/// `MetricSummary` in base units (bytes, seconds) written from MetricKit's
/// typed API, and the raw `jsonRepresentation()` for sharing. The summary
/// exists because the raw JSON spells measurements as formatted strings
/// ("200,000 kB"), which are not reliable to parse back.
///
/// `MWMetricKitSubscriber.m` (the extension) writes the same envelope with the
/// same keys and the same digest-based name, so a payload replayed by
/// `pastPayloads` overwrites its own file. Plain Foundation so it compiles for
/// tvOS too, where MetricKit doesn't exist and the directory stays empty.
public struct MetricReportStore: Sendable {
    /// Daily payloads from two processes: about six weeks of history.
    public static let maxReports = 90

    public let directory: URL

    public init(directory: URL = AppGroup.metricKitMetricsDirectoryURL) {
        self.directory = directory
    }

    /// Wraps `payload` (the raw MetricKit JSON) with its summary and writes
    /// it. Returns the stored file.
    @discardableResult
    public func save(source: MetricSource, summary: MetricSummary, payload: Data) throws -> URL {
        var envelope: [String: Any] = try [
            "source": source.rawValue,
            "summary": JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)),
        ]
        envelope["payload"] = try? JSONSerialization.jsonObject(with: payload)
        let data = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: Self.fileName(for: payload))
        try data.write(to: url, options: .atomic)
        prune()
        return url
    }

    /// Records newest first; files that don't decode are skipped.
    public func records() -> [MetricRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return MetricRecord(url: url, data: data)
            }
            .sorted { $0.summary.end > $1.summary.end }
    }

    public func delete(_ record: MetricRecord) {
        try? FileManager.default.removeItem(at: record.url)
    }

    public func deleteAll() {
        for record in records() {
            delete(record)
        }
    }

    /// `metrics-<first 16 bytes of SHA-256 of the raw payload, hex>.json`.
    public static func fileName(for payload: Data) -> String {
        let hex = SHA256.hash(data: payload).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "metrics-\(hex).json"
    }

    private func prune() {
        for record in records().dropFirst(Self.maxReports) {
            delete(record)
        }
    }
}

/// Which process MetricKit delivered the payload to.
public enum MetricSource: String, Codable, Sendable, CaseIterable {
    case app
    case tunnel
}

/// The numbers worth reading from one `MXMetricPayload`, in base units.
/// Every metric is optional: MetricKit leaves out what a process didn't do
/// (the tunnel never draws a frame, so it has no launch or hang data).
public struct MetricSummary: Codable, Hashable, Sendable {
    /// Seconds since 1970 — written by Obj-C too, so no `Date` coding.
    public var begin: Double
    public var end: Double
    public var bundleIdentifier: String?
    public var appVersion: String?
    public var appBuildVersion: String?
    public var osVersion: String?

    public var peakMemoryBytes: Double?
    public var averageSuspendedMemoryBytes: Double?
    public var cpuTimeSeconds: Double?
    public var foregroundTimeSeconds: Double?
    public var backgroundTimeSeconds: Double?
    public var wifiUploadBytes: Double?
    public var wifiDownloadBytes: Double?
    public var cellularUploadBytes: Double?
    public var cellularDownloadBytes: Double?
    public var logicalWritesBytes: Double?
    /// Median time to first draw on launch, from the launch histogram.
    public var launchMedianSeconds: Double?
    /// Number of hangs in the responsiveness histogram.
    public var hangCount: Int?
    /// Exit counts keyed by `MetricExitReason.rawValue`.
    public var foregroundExits: [String: Int]?
    public var backgroundExits: [String: Int]?

    public init(begin: Date, end: Date) {
        self.begin = begin.timeIntervalSince1970
        self.end = end.timeIntervalSince1970
    }

    public var beginDate: Date {
        Date(timeIntervalSince1970: begin)
    }

    public var endDate: Date {
        Date(timeIntervalSince1970: end)
    }

    /// Foreground and background exits combined, for every reason except a
    /// normal exit: crashes, watchdog kills, memory-limit kills and the rest.
    public var abnormalExitCount: Int {
        [foregroundExits, backgroundExits]
            .compactMap(\.self)
            .flatMap(\.self)
            .filter { $0.key != MetricExitReason.normal.rawValue }
            .reduce(0) { $0 + $1.value }
    }

    public func exits(_ reason: MetricExitReason) -> Int {
        (foregroundExits?[reason.rawValue] ?? 0) + (backgroundExits?[reason.rawValue] ?? 0)
    }
}

/// `MXForegroundExitData` / `MXBackgroundExitData` counters. Raw values are
/// the JSON keys both writers use.
public enum MetricExitReason: String, Sendable, CaseIterable {
    case normal
    case abnormal
    case memoryLimit
    case memoryPressure
    case watchdog
    case cpuLimit
    case badAccess
    case illegalInstruction
    case lockedFile
    case taskAssertionTimeout
}

/// One saved metric payload. `data` is the whole envelope file, raw payload
/// included, for sharing.
public struct MetricRecord: Identifiable, Hashable, Sendable {
    public let url: URL
    public let source: MetricSource
    public let summary: MetricSummary

    public var id: URL {
        url
    }

    public init?(url: URL, data: Data) {
        struct Envelope: Decodable {
            let source: MetricSource
            let summary: MetricSummary
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        self.url = url
        source = envelope.source
        summary = envelope.summary
    }
}
