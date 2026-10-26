import SwiftUI

/// Utility > Paw Print (`LogbookModel`): the engine's record of notable
/// events, newest first under day headers. Each entry leads with its event,
/// drawn by kind and tinted by how it went; a tap shows its times and the
/// details the engine recorded. The search finds entries by any word of
/// them; the top bar's menu shows one event.
struct LogbookView: View {
    @State private var model: LogbookModel

    init(model: LogbookModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if !model.loaded {
                Color.clear
            } else if model.entries.isEmpty {
                empty
            } else {
                entryList
            }
        }
        .background(AppTheme.screenBackground)
        .navigationTitle("utility.nav.pawPrint")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: Text("logbook.search"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
        }
        // Restarted by every change of search or event; a search waits for
        // a pause in typing first.
        .task(id: model.filter) { await model.run() }
    }

    /// Every event, or one kind of it.
    private var filterMenu: some View {
        Menu {
            Picker("logbook.filter", selection: $model.kind) {
                Label("logbook.filterAll", systemImage: "pawprint")
                    .tag(String?.none)
                ForEach(LogbookKinds.all, id: \.kind) { event in
                    Label { Text(event.name) } icon: { Image(systemName: event.icon) }
                        .tag(String?.some(event.kind))
                }
            }
        } label: {
            // Filled while an event is picked, so one event's entries do not
            // pass for the whole logbook.
            Label(
                "logbook.filter",
                systemImage: model.kind == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill",
            )
        }
        .accessibilityIdentifier("logbook.filter")
    }

    @ViewBuilder
    private var empty: some View {
        if let error = model.error {
            ContentUnavailableView(
                "utility.nav.pawPrint",
                systemImage: "exclamationmark.triangle",
                description: Text("logbook.readFailed \(error)"),
            )
            .accessibilityIdentifier("logbook.empty")
        } else if !model.shown.search.isEmpty {
            ContentUnavailableView.search(text: model.shown.search)
                .accessibilityIdentifier("logbook.empty")
        } else if let kind = model.kind {
            ContentUnavailableView(
                "logbook.filterEmpty \(LogbookKinds.name(of: kind))",
                systemImage: LogbookKinds.icon(of: kind),
            )
            .accessibilityIdentifier("logbook.empty")
        } else {
            ContentUnavailableView(
                "logbook.empty",
                systemImage: "pawprint",
                description: Text("logbook.emptyHint"),
            )
            .accessibilityIdentifier("logbook.empty")
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                    // A day header above the first entry of each day.
                    if index == 0 || !Calendar.current.isDate(
                        entry.time,
                        inSameDayAs: model.entries[index - 1].time,
                    ) {
                        Text(entry.time.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedText)
                            .textCase(.uppercase)
                            .padding(.leading, 4)
                            .padding(.top, index == 0 ? 0 : 8)
                    }
                    LogbookEntryCard(entry: entry)
                }
                if model.more {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        // Again after every change to the list: a re-read
                        // can overtake a page back.
                        .task(id: model.generation) { await model.loadMore() }
                }
            }
            .padding(16)
            .readableColumn()
        }
        .scrollContentBackground(.hidden)
    }
}

/// One entry: what happened, to what, and when; a tap shows the rest.
private struct LogbookEntryCard: View {
    let entry: LogbookEntry

    @State private var expanded = false

    private var tint: Color {
        switch entry.level {
        case .info: AppTheme.accent
        case .warning: AppTheme.warning
        case .error: AppTheme.danger
        }
    }

    var body: some View {
        GlassCard {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: LogbookKinds.icon(of: entry))
                        .font(.subheadline)
                        .foregroundStyle(tint)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        header
                        Text(entry.message)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(expanded ? nil : 3)
                            .multilineTextAlignment(.leading)
                        if expanded {
                            details
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityIdentifier("logbook.entry")
    }

    /// "Dialer Proxy Switch · US Home", then the repeats and the time.
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Text(LogbookKinds.name(of: entry.kind))
                    .foregroundStyle(tint)
                    .fontWeight(.semibold)
                if let subject = entry.subject {
                    Text(verbatim: " · \(subject)")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .font(.caption)
            .lineLimit(1)
            Spacer(minLength: 8)
            Text((entry.count > 1 ? "×\(entry.count)  " : "") + entry.time.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("logbook.first \(entry.time.formatted(date: .abbreviated, time: .standard))")
            if let last = entry.last {
                Text("logbook.last \(last.formatted(date: .abbreviated, time: .standard))")
            }
            ForEach((entry.fields ?? [:]).sorted { $0.key < $1.key }, id: \.key) { field in
                Text(verbatim: "\(field.key): \(field.value.text)")
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(AppTheme.mutedText)
        .padding(.top, 4)
    }
}

/// How the page names and draws the engine's event kinds
/// (`meow_common::logbook::kind`). A kind is never renamed once released, so
/// the table only grows; one it lacks (a newer engine's) shows its raw name
/// under its level's icon.
enum LogbookKinds {
    struct Event: Sendable {
        let kind: String
        let name: LocalizedStringResource
        let icon: String
    }

    /// Every kind, in the filter menu's order: the engine, its config and
    /// sources, then dialer-proxy chains and the network.
    static let all: [Event] = [
        Event(kind: "engine.start", name: "logbook.kind.engineStart", icon: "play.circle.fill"),
        Event(kind: "engine.stop", name: "logbook.kind.engineStop", icon: "stop.circle.fill"),
        Event(
            kind: "engine.unclean-exit",
            name: "logbook.kind.engineUncleanExit",
            icon: "exclamationmark.octagon.fill",
        ),
        Event(kind: "config.reload", name: "logbook.kind.configReload", icon: "arrow.triangle.2.circlepath"),
        Event(kind: "config.change", name: "logbook.kind.configChange", icon: "slider.horizontal.3"),
        Event(kind: "subscription.update", name: "logbook.kind.subscriptionUpdate", icon: "icloud.and.arrow.down"),
        Event(
            kind: "proxy-provider.update",
            name: "logbook.kind.proxyProviderUpdate",
            icon: "point.3.connected.trianglepath.dotted",
        ),
        Event(kind: "rule-provider.update", name: "logbook.kind.ruleProviderUpdate", icon: "list.bullet"),
        Event(kind: "geodata.update", name: "logbook.kind.geodataUpdate", icon: "globe"),
        Event(kind: "dialer-proxy.switch", name: "logbook.kind.dialerProxySwitch", icon: "arrow.left.arrow.right"),
        Event(kind: "dialer-proxy.check", name: "logbook.kind.dialerProxyCheck", icon: "checkmark.shield"),
        Event(kind: "network.interface", name: "logbook.kind.networkInterface", icon: "network"),
        Event(
            kind: "listener.start",
            name: "logbook.kind.listenerStart",
            icon: "antenna.radiowaves.left.and.right",
        ),
        Event(kind: "logbook.cleared", name: "logbook.kind.logbookCleared", icon: "trash"),
        Event(kind: "logbook.reset", name: "logbook.kind.logbookReset", icon: "arrow.counterclockwise"),
    ]

    private static let byKind = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    /// The name shown for `kind`; nil for a kind this build does not know.
    static func label(of kind: String) -> String? {
        byKind[kind].map { String(localized: $0.name) }
    }

    /// The name shown for `kind`, or the kind itself when this build does
    /// not know it.
    static func name(of kind: String) -> String {
        label(of: kind) ?? kind
    }

    /// The icon of a picked event: a kind, or the area of several.
    static func icon(of kind: String) -> String {
        byKind[kind]?.icon ?? "pawprint"
    }

    static func icon(of entry: LogbookEntry) -> String {
        if let known = byKind[entry.kind] {
            return known.icon
        }
        return switch entry.level {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}
