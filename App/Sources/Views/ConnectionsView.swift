import MeowModels
import SwiftUI

struct ConnectionsView: View {
    @Environment(MeowAPI.self) private var api
    @State private var connections: [Connection] = []
    @State private var query: String = ""
    @State private var errorMessage: String?
    @State private var detailTarget: ConnectionDetailTarget?

    var body: some View {
        List {
            ForEach(filtered) { conn in
                row(for: conn)
            }
        }
        .listStyle(.plain)
        .overlay {
            if connections.isEmpty {
                ContentUnavailableView(
                    "connections.empty.title",
                    systemImage: "link",
                    description: Text("connections.empty.description"),
                )
                .accessibilityIdentifier("connections.emptyState")
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .accessibilityIdentifier("connections.emptySearch")
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .searchable(text: $query)
        .navigationTitle(Text(
            "connections.nav.titleFormat \(connections.count)",
            comment: "Connections screen navigation title; %lld = current count",
        ))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("connections.toolbar.closeAll") {
                    Task { try? await api.closeAllConnections() }
                }
                .accessibilityIdentifier("connections.toolbar.closeAll")
            }
        }
        .navigationDestination(item: $detailTarget) { target in
            ConnectionDetailView(model: ConnectionDetailModel(connection: target.connection, api: api))
        }
        .task { await poll() }
    }

    /// Tapping a row opens its detail page, where it can also be closed.
    private func row(for conn: Connection) -> some View {
        let slug = conn.id.identifierSlug
        let host = Self.title(for: conn)
        let port = conn.metadata?.destinationPort ?? ""
        let network = conn.metadata?.network.uppercased() ?? "TCP"
        let address = port.isEmpty ? host : "\(host):\(port)"
        let up = ByteCountFormatter.string(fromByteCount: conn.upload, countStyle: .binary)
        let down = ByteCountFormatter.string(fromByteCount: conn.download, countStyle: .binary)
        let chain = conn.chains.reversed().joined(separator: " › ")
        return Button {
            detailTarget = ConnectionDetailTarget(connection: conn)
        } label: {
            GlassCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(address)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityIdentifier("connections.row.\(slug).host")
                        Spacer()
                        Text(network)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: .capsule)
                    }
                    HStack(spacing: 10) {
                        Label(up, systemImage: "arrow.up")
                            .accessibilityLabel(Text("a11y.connections.row.upload \(up)"))
                        Label(down, systemImage: "arrow.down")
                            .accessibilityLabel(Text("a11y.connections.row.download \(down)"))
                        Spacer()
                        Text(chain)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("connections.row.\(slug).chain")
                    }
                    Text("\(conn.rule) · \(conn.rulePayload)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("connections.row.\(slug).rule")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("a11y.connections.row.label \(address) \(network) \(up) \(down) \(chain)"))
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("connections.row.\(slug)")
    }

    /// Row title: sniffed host, else destination IP (direct-IP connections
    /// have an empty `host`), else the rule label.
    private static func title(for conn: Connection) -> String {
        conn.metadata.flatMap { $0.host.isEmpty ? $0.destinationIP : $0.host } ?? conn.rule
    }

    private func errorBanner(_ message: String) -> some View {
        ErrorBanner(
            message: message,
            accessibilityLabel: Text("a11y.connections.errorBanner \(message)"),
            identifier: "connections.errorBanner",
        )
    }

    private var filtered: [Connection] {
        guard !query.isEmpty else { return connections }
        return connections.filter { conn in
            Self.title(for: conn).localizedCaseInsensitiveContains(query)
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                let resp = try await api.getConnections()
                connections = resp.connections ?? []
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// Keyed by the connection's id, so a poll that refreshes the list's copy
/// does not count as a different page.
private struct ConnectionDetailTarget: Hashable {
    let connection: Connection

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.connection.id == rhs.connection.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(connection.id)
    }
}
