import MeowModels
import SwiftUI

/// Settings › Crash Reports: MetricKit diagnostic payloads the app and the
/// tunnel extension saved into `CrashReportStore`. iOS delivers them on a
/// later launch (at most daily), so a crash usually appears here a day after
/// it happened. Each report can be shared as its raw JSON — what a bug report
/// needs — or deleted.
struct CrashReportsView: View {
    @State private var reports: [CrashReport] = []
    @State private var confirmingDeleteAll = false
    private let store = CrashReportStore()

    var body: some View {
        Form {
            if reports.isEmpty {
                ContentUnavailableView(
                    "crashReports.empty.title",
                    systemImage: "checkmark.shield",
                    description: Text("crashReports.empty.description"),
                )
            } else {
                Section {
                    ForEach(reports) { report in
                        NavigationLink {
                            CrashReportDetailView(report: report)
                        } label: {
                            CrashReportRow(report: report)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            store.delete(reports[index])
                        }
                        reload()
                    }
                } footer: {
                    Text("crashReports.footer")
                }
            }
        }
        .readableColumn()
        .navigationTitle("crashReports.nav.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !reports.isEmpty {
                Button("crashReports.button.deleteAll", role: .destructive) {
                    confirmingDeleteAll = true
                }
                .accessibilityIdentifier("crashReports.button.deleteAll")
            }
        }
        .confirmationDialog(
            "crashReports.deleteAll.title",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible,
        ) {
            Button("crashReports.button.deleteAll", role: .destructive) {
                store.deleteAll()
                reload()
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        reports = store.reports()
    }
}

private struct CrashReportRow: View {
    let report: CrashReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(report.date, format: .dateTime.year().month().day().hour().minute())
                .font(.body)
            Text(report.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CrashReportDetailView: View {
    let report: CrashReport

    var body: some View {
        Form {
            ForEach(Array(report.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Section(diagnostic.kind.title) {
                    if let bundle = diagnostic.bundleIdentifier {
                        LabeledContent("crashReports.detail.process", value: bundle)
                    }
                    if let version = diagnostic.appVersion {
                        LabeledContent(
                            "crashReports.detail.version",
                            value: [version, diagnostic.appBuildVersion.map { "(\($0))" }]
                                .compactMap(\.self).joined(separator: " "),
                        )
                    }
                    if let os = diagnostic.osVersion {
                        LabeledContent("crashReports.detail.os", value: os)
                    }
                    if let detail = diagnostic.detail {
                        Text(detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .readableColumn()
        .navigationTitle(Text(report.date, format: .dateTime.month().day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: report.url) {
                Label("crashReports.button.share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("crashReports.button.share")
        }
    }
}

extension CrashReport {
    /// "1 crash · 2 hangs", counting only the kinds present.
    var summary: String {
        CrashDiagnosticKind.allCases.compactMap { kind in
            let n = count(of: kind)
            return n == 0 ? nil : "\(kind.title) × \(n)"
        }
        .joined(separator: " · ")
    }
}

extension CrashDiagnosticKind {
    var title: String {
        switch self {
        case .crash: String(localized: "crashReports.kind.crash")
        case .hang: String(localized: "crashReports.kind.hang")
        case .cpuException: String(localized: "crashReports.kind.cpu")
        case .diskWriteException: String(localized: "crashReports.kind.diskWrite")
        case .appLaunch: String(localized: "crashReports.kind.launch")
        }
    }
}
