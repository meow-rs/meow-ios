import SwiftUI

/// One `/connections` entry flattened into the table's columns.
struct ConnectionRow: Identifiable {
    let id: String
    let host: String
    let network: String
    let rule: String
    let chain: String
    let download: Int64
    let upload: Int64
    let started: Date?
    let destination: String
    let source: String
    let raw: Connection

    init(_ connection: Connection) {
        let meta = connection.metadata
        let port = meta?.destinationPort ?? ""
        let name = [meta?.host, meta?.sniffHost, meta?.destinationIP]
            .compactMap(\.self)
            .first { !$0.isEmpty } ?? "—"
        id = connection.id
        host = port.isEmpty ? name : "\(name):\(port)"
        network = (meta?.network ?? "").uppercased()
        rule = connection.rulePayload.isEmpty ? connection.rule : "\(connection.rule) · \(connection.rulePayload)"
        // The engine lists the chain from the outbound back to the group the
        // rule picked; read it the other way round.
        chain = connection.chains.reversed().joined(separator: " › ")
        download = connection.download
        upload = connection.upload
        started = Self.parseDate(connection.start)
        let destinationIP = meta?.destinationIP ?? ""
        destination = destinationIP.isEmpty ? "—" : (port.isEmpty ? destinationIP : "\(destinationIP):\(port)")
        source = meta?.sourceIP ?? "—"
        raw = connection
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

struct ConnectionsPage: View {
    @Environment(MacController.self) private var controller
    @State private var search = ""
    @State private var selection: ConnectionRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ConnectionRow.download, order: .reverse)]
    @State private var showsInspector = true

    var body: some View {
        let monitor = controller.engine
        Group {
            if controller.isConnected {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Host", value: \.host) { row in
                        Text(row.host).fontWeight(.medium)
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("Net", value: \.network)
                        .width(44)
                    TableColumn("Rule", value: \.rule)
                        .width(min: 120, ideal: 180)
                    TableColumn("Chain", value: \.chain)
                        .width(min: 120, ideal: 180)
                    TableColumn("Down", value: \.download) { row in
                        Text(MacFormat.bytes(row.download)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(76)
                    TableColumn("Up", value: \.upload) { row in
                        Text(MacFormat.bytes(row.upload)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(70)
                }
                .contextMenu(forSelectionType: ConnectionRow.ID.self) { ids in
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                        Button("Copy Host") { MacPasteboard.copy(row.host) }
                        Button("Close Connection") { Task { await monitor.close(row.id) } }
                    }
                }
                .padding(16)
            } else {
                EngineOfflineView(message: "Connect to watch live connections.")
            }
        }
        .navigationTitle("Connections")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Host, rule or proxy")
        .inspector(isPresented: $showsInspector) {
            ConnectionInspector(row: selectedRow)
                .inspectorColumnWidth(min: 240, ideal: 270, max: 360)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { monitor.isPaused }, set: { monitor.isPaused = $0 })) {
                    Label(
                        monitor.isPaused ? "Resume" : "Pause",
                        systemImage: monitor.isPaused ? "play.fill" : "pause.fill",
                    )
                }
                .help(monitor.isPaused ? "Resume live updates" : "Pause live updates")
                Toggle(isOn: $showsInspector) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show the inspector")
                let canCloseAll = controller.isConnected && !monitor.connections.isEmpty
                Button(role: .destructive) {
                    Task { await monitor.closeAll() }
                } label: {
                    // An explicit color would hide the disabled dimming.
                    Text("Close All")
                        .foregroundStyle(canCloseAll ? MacTheme.danger : MacTheme.secondaryInk)
                }
                .disabled(!canCloseAll)
            }
        }
        .onAppear { monitor.wantsLiveConnections = true }
        .onDisappear {
            monitor.wantsLiveConnections = false
            monitor.isPaused = false
        }
    }

    private var rows: [ConnectionRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var rows = controller.engine.connections.map(ConnectionRow.init)
        if !query.isEmpty {
            rows = rows.filter {
                $0.host.localizedCaseInsensitiveContains(query)
                    || $0.rule.localizedCaseInsensitiveContains(query)
                    || $0.chain.localizedCaseInsensitiveContains(query)
            }
        }
        return rows.sorted(using: sortOrder)
    }

    private var selectedRow: ConnectionRow? {
        guard let selection else { return nil }
        return controller.engine.connections.first { $0.id == selection }.map(ConnectionRow.init)
    }

    private var subtitle: String {
        guard controller.isConnected else { return "" }
        let count = controller.engine.connections.count
        let paused = controller.engine.isPaused ? " · paused" : ""
        return "\(count) active\(paused)"
    }
}

private struct ConnectionInspector: View {
    let row: ConnectionRow?
    @Environment(MacController.self) private var controller

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Inspector")
                        Text(row.host)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MacTheme.ink)
                            .textSelection(.enabled)
                    }
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 9) {
                        field("Destination", row.destination, mono: true)
                        field("Source", row.source, mono: true)
                        field("Network", network(row))
                        field("Rule", row.rule)
                        field("Chain", row.chain.isEmpty ? "—" : row.chain)
                        field("Download", MacFormat.bytes(row.download))
                        field("Upload", MacFormat.bytes(row.upload))
                        if let started = row.started {
                            field("Started", MacFormat.relative(started))
                        }
                    }
                    VStack(spacing: 8) {
                        Button {
                            MacPasteboard.copy(row.host)
                        } label: {
                            Text("Copy Host").frame(maxWidth: .infinity)
                        }
                        Button(role: .destructive) {
                            Task { await controller.engine.close(row.id) }
                        } label: {
                            Text("Close Connection").frame(maxWidth: .infinity)
                        }
                        .tint(MacTheme.danger)
                    }
                    .controlSize(.large)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "arrow.left.arrow.right",
                description: Text("Select a connection to inspect it."),
            )
        }
    }

    /// "TCP · FAKE-IP".
    private func network(_ row: ConnectionRow) -> String {
        [row.network, row.raw.metadata?.dnsMode.uppercased()]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func field(_ title: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(title)
                .font(.callout)
                .foregroundStyle(MacTheme.secondaryInk)
            Text(value)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(MacTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
