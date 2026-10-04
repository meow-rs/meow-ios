import CryptoKit
import Foundation

/// MetricKit diagnostic payloads (crashes, hangs, CPU / disk-write exceptions)
/// saved as the raw `MXDiagnosticPayload.jsonRepresentation()` in the App
/// Group, so reports the packet-tunnel extension receives show up in the app
/// next to the app's own.
///
/// iOS delivers each payload once — to whichever process subscribed when it
/// was ready, usually on the next launch and at most once a day — so these
/// files are the only copy. The file name is a digest of the JSON:
/// re-saving a payload (e.g. `pastDiagnosticPayloads` replaying one the
/// subscriber already saw) overwrites the same file instead of duplicating
/// it. `MWMetricKitSubscriber.m` (the extension) mirrors the directory and
/// naming scheme.
///
/// Plain Foundation so it compiles for tvOS too, where MetricKit doesn't
/// exist and the directory just stays empty.
public struct CrashReportStore: Sendable {
    /// Newest reports kept; older ones are pruned on save.
    public static let maxReports = 50

    public let directory: URL

    public init(directory: URL = AppGroup.metricKitDirectoryURL) {
        self.directory = directory
    }

    /// Writes `json` and prunes past `maxReports`. Returns the stored file.
    @discardableResult
    public func save(_ json: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: Self.fileName(for: json))
        try json.write(to: url, options: .atomic)
        prune()
        return url
    }

    /// Reports newest first. Files that don't parse as a diagnostic payload
    /// are skipped rather than failing the whole list.
    public func reports() -> [CrashReport] {
        reportURLs()
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return CrashReport(url: url, json: data)
            }
            .sorted { $0.date > $1.date }
    }

    public func delete(_ report: CrashReport) {
        try? FileManager.default.removeItem(at: report.url)
    }

    public func deleteAll() {
        for url in reportURLs() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `metrickit-<first 16 bytes of SHA-256, hex>.json`.
    public static func fileName(for json: Data) -> String {
        let hex = SHA256.hash(data: json).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "metrickit-\(hex).json"
    }

    private func reportURLs() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
        )) ?? []
        return urls.filter { $0.pathExtension == "json" }
    }

    private func prune() {
        for report in reports().dropFirst(Self.maxReports) {
            delete(report)
        }
    }
}

/// MetricKit diagnostic families, keyed by their array name in the payload JSON.
public enum CrashDiagnosticKind: String, Sendable, CaseIterable {
    case crash = "crashDiagnostics"
    case hang = "hangDiagnostics"
    case cpuException = "cpuExceptionDiagnostics"
    case diskWriteException = "diskWriteExceptionDiagnostics"
    case appLaunch = "appLaunchDiagnostics"
}

/// One crash / hang / exception inside a payload.
public struct CrashDiagnostic: Hashable, Sendable {
    public let kind: CrashDiagnosticKind
    public let bundleIdentifier: String?
    public let appVersion: String?
    public let appBuildVersion: String?
    public let osVersion: String?
    /// One-line cause: termination reason, exception type / signal, or
    /// the hang duration — whichever the diagnostic carries.
    public let detail: String?
}

/// One saved diagnostic payload, summarised for the list UI. `json` keeps the
/// full payload (call-stack trees included) for sharing.
public struct CrashReport: Identifiable, Hashable, Sendable {
    public let url: URL
    public let json: Data
    /// End of the payload's time range, falling back to the file date.
    public let date: Date
    public let diagnostics: [CrashDiagnostic]

    public var id: URL {
        url
    }

    public func count(of kind: CrashDiagnosticKind) -> Int {
        diagnostics.count(where: { $0.kind == kind })
    }

    public init?(url: URL, json: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        var diagnostics: [CrashDiagnostic] = []
        for kind in CrashDiagnosticKind.allCases {
            for entry in root[kind.rawValue] as? [[String: Any]] ?? [] {
                let metaData = entry["diagnosticMetaData"] as? [String: Any] ?? [:]
                diagnostics.append(CrashDiagnostic(kind: kind, metaData: metaData))
            }
        }
        guard !diagnostics.isEmpty else { return nil }
        self.url = url
        self.json = json
        self.diagnostics = diagnostics
        let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        date = Self.parseDate(root["timeStampEnd"])
            ?? Self.parseDate(root["timeStampBegin"])
            ?? fileDate
            ?? .distantPast
    }

    /// MetricKit writes timestamps as `yyyy-MM-dd HH:mm:ss Z`.
    static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: string)
    }
}

extension CrashDiagnostic {
    init(kind: CrashDiagnosticKind, metaData: [String: Any]) {
        self.kind = kind
        bundleIdentifier = metaData["bundleIdentifier"] as? String
        appVersion = metaData["appVersion"] as? String
        appBuildVersion = metaData["appBuildVersion"] as? String
        osVersion = metaData["osVersion"] as? String
        let parts: [String] = switch kind {
        case .crash:
            [
                metaData["terminationReason"],
                metaData["exceptionType"].map { "exception \($0)" },
                metaData["signal"].map { "signal \($0)" },
            ].compactMap { $0.map { "\($0)" } }
        case .hang:
            [metaData["hangDuration"]].compactMap { $0.map { "\($0)" } }
        case .cpuException:
            [metaData["totalCPUTime"]].compactMap { $0.map { "\($0)" } }
        case .diskWriteException:
            [metaData["writesCaused"]].compactMap { $0.map { "\($0)" } }
        case .appLaunch:
            [metaData["launchDuration"]].compactMap { $0.map { "\($0)" } }
        }
        detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
