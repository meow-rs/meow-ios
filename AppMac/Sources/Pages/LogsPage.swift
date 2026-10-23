import SwiftUI

enum LogLevel: String, CaseIterable, Identifiable {
    case debug
    case info
    case warning
    case error

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var badge: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    var tint: Color {
        switch self {
        case .debug: MacTheme.secondaryInk
        case .info: Color.accentColor
        case .warning: MacTheme.warning
        case .error: MacTheme.danger
        }
    }

    init(entryType: String) {
        switch entryType.lowercased() {
        case "debug", "trace": self = .debug
        case "warning", "warn": self = .warning
        case "error", "fatal": self = .error
        default: self = .info
        }
    }
}

struct LogsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var filter = ""

    var body: some View {
        let store = appModel.utilityLogs
        let lines = visibleLines
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        LogLineRow(line: line)
                            .id(line.id)
                    }
                    if store.autoScroll {
                        Label("Following new lines", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(MacTheme.secondaryInk)
                            .labelStyle(FollowingLabelStyle())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .id("tail")
                    }
                }
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
            .macCard(padding: 0)
            .padding(24)
            .overlay {
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No Log Lines",
                        systemImage: "list.bullet",
                        description: Text(store.errorMessage ?? "Lines appear here while meow is connected."),
                    )
                }
            }
            .onChange(of: lines.last?.id) {
                guard store.autoScroll else { return }
                proxy.scrollTo("tail", anchor: .bottom)
            }
        }
        .navigationTitle("Logs")
        .navigationSubtitle("\(lines.count.formatted()) lines · showing \(level.title) and above")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Level", selection: Binding(get: { level }, set: { store.level = $0.rawValue })) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { store.autoScroll }, set: { store.autoScroll = $0 })) {
                    Label("Follow", systemImage: "arrow.down.to.line")
                }
                .help("Follow new lines")
                Button {
                    store.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear the log")
                Button(action: export) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the visible lines")
                .disabled(lines.isEmpty)
            }
        }
    }

    private var level: LogLevel {
        LogLevel(rawValue: appModel.utilityLogs.level) ?? .info
    }

    private var visibleLines: [LogLine] {
        let minimum = level.rank
        let query = filter.trimmingCharacters(in: .whitespaces)
        return appModel.utilityLogs.allEntries.compactMap { entry in
            let entryLevel = LogLevel(entryType: entry.type)
            guard entryLevel.rank >= minimum else { return nil }
            if !query.isEmpty, !entry.payload.localizedCaseInsensitiveContains(query) {
                return nil
            }
            // Stable across the store trimming its oldest lines, unlike an index.
            let id = "\(entry.receivedAt.timeIntervalSinceReferenceDate)-\(entry.payload.hashValue)"
            return LogLine(id: id, entry: entry, level: entryLevel)
        }
    }

    private func export() {
        let text = visibleLines.map { line in
            "\(line.entry.receivedAt.formatted(.iso8601)) \(line.level.badge) \(line.entry.payload)"
        }
        .joined(separator: "\n")
        MacSavePanel.save(Data(text.utf8), suggestedName: "meow.log", contentType: .log)
    }
}

struct LogLine: Identifiable {
    let id: String
    let entry: LogEntry
    let level: LogLevel
}

private struct LogLineRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(line.entry.receivedAt, format: MacFormat.clock)
                .foregroundStyle(MacTheme.secondaryInk)
            Text(line.level.badge)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(line.level.tint)
                .frame(width: 48)
                .padding(.vertical, 1)
                .background(line.level.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            Text(line.entry.payload)
                .foregroundStyle(MacTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(rowTint)
    }

    private var rowTint: Color {
        switch line.level {
        case .warning: MacTheme.warning.opacity(0.07)
        case .error: MacTheme.danger.opacity(0.07)
        case .debug, .info: .clear
        }
    }
}

private struct FollowingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 6))
                .foregroundStyle(MacTheme.connected)
            configuration.title
        }
    }
}
