import MeowModels
import SwiftUI

// MARK: - Rules

struct RulesPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @State private var rules: [IndexedRule] = []
    @State private var search = ""
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !controller.isConnected {
                EngineOfflineView(message: "Connect to see the rules the engine is matching with.")
            } else if let errorMessage, rules.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load Rules",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage),
                )
            } else {
                Table(filtered) {
                    TableColumn("#") { rule in
                        Text("\(rule.index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(44)
                    TableColumn("Type") { rule in Text(rule.rule.type) }
                        .width(min: 100, ideal: 140)
                    TableColumn("Payload") { rule in
                        Text(rule.rule.payload.isEmpty ? "—" : rule.rule.payload)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 160, ideal: 320)
                    TableColumn("Policy") { rule in
                        Text(rule.rule.proxy).foregroundStyle(Color.accentColor)
                    }
                    .width(min: 100, ideal: 160)
                }
                .padding(16)
            }
        }
        .navigationTitle("Rules")
        .navigationSubtitle(controller.isConnected ? "\(rules.count) rules · first match wins" : "")
        .searchable(text: $search, placement: .toolbar, prompt: "Type, payload or policy")
        .task(id: "\(controller.isConnected)-\(appModel.replayGeneration)") {
            guard controller.isConnected else {
                rules = []
                return
            }
            do {
                let response = try await appModel.meowAPI.getRules()
                rules = response.rules.enumerated().map { IndexedRule(index: $0.offset, rule: $0.element) }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var filtered: [IndexedRule] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rules }
        return rules.filter {
            $0.rule.type.localizedCaseInsensitiveContains(query)
                || $0.rule.payload.localizedCaseInsensitiveContains(query)
                || $0.rule.proxy.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Rules can repeat verbatim; their position is the identity.
struct IndexedRule: Identifiable {
    var id: Int {
        index
    }

    let index: Int
    let rule: Rule
}

// MARK: - Providers

struct ProvidersPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @State private var providers: [Provider] = []
    @State private var checking: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !controller.isConnected {
                EngineOfflineView(message: "Connect to see the config's proxy providers.")
            } else if providers.isEmpty {
                ContentUnavailableView(
                    "No Providers",
                    systemImage: "tray.2",
                    description: Text(errorMessage ?? "This config has no proxy-providers."),
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(providers, id: \.name) { provider in
                            providerCard(provider)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Providers")
        .navigationSubtitle(controller.isConnected ? "\(providers.count) proxy providers" : "")
        .task(id: "\(controller.isConnected)-\(appModel.replayGeneration)") { await load() }
    }

    private func providerCard(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.headline)
                        .foregroundStyle(MacTheme.ink)
                    Text(summary(provider))
                        .font(.caption)
                        .foregroundStyle(MacTheme.secondaryInk)
                }
                Spacer()
                Button {
                    Task { await healthCheck(provider) }
                } label: {
                    if checking.contains(provider.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Health Check", systemImage: "bolt.heart")
                    }
                }
                .disabled(checking.contains(provider.name))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                ForEach(provider.proxies ?? []) { proxy in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(proxy.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(proxy.type)
                                .font(.caption2)
                                .foregroundStyle(MacTheme.secondaryInk)
                        }
                        Spacer(minLength: 4)
                        DelayBadge(delay: proxy.history?.last?.delay)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(MacTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .macCard()
    }

    /// "HTTP · 24 proxies".
    private func summary(_ provider: Provider) -> String {
        [provider.vehicleType, "\(provider.proxies?.count ?? 0) proxies"]
            .compactMap(\.self)
            .joined(separator: " · ")
    }

    private func load() async {
        guard controller.isConnected else {
            providers = []
            return
        }
        do {
            providers = try await EngineMonitor.userProviders(appModel.meowAPI.getProviders())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func healthCheck(_ provider: Provider) async {
        checking.insert(provider.name)
        defer { checking.remove(provider.name) }
        do {
            try await appModel.meowAPI.healthCheckProvider(name: provider.name)
            await load()
        } catch {
            controller.alertMessage = error.localizedDescription
        }
    }
}

// MARK: - Statistics

/// What each proxy carried during this engine run, polled every second.
struct StatisticsPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @State private var rows: [PolicyRow] = []
    @State private var isSupported = true
    @State private var sortOrder = [KeyPathComparator(\PolicyRow.total, order: .reverse)]

    var body: some View {
        Group {
            if !controller.isConnected {
                EngineOfflineView(message: "Connect to see how much each proxy carried.")
            } else if !isSupported {
                ContentUnavailableView(
                    "Not Available",
                    systemImage: "gauge.with.dots.needle.33percent",
                    description: Text("This engine doesn't report per-proxy traffic."),
                )
            } else {
                Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
                    TableColumn("Proxy", value: \.name)
                        .width(min: 160, ideal: 240)
                    TableColumn("Share", value: \.total) { row in
                        ShareBar(fraction: maxTotal > 0 ? Double(row.total) / Double(maxTotal) : 0)
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn("Download", value: \.download) { row in
                        Text(MacFormat.bytes(row.download)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Upload", value: \.upload) { row in
                        Text(MacFormat.bytes(row.upload)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Total", value: \.total) { row in
                        Text(MacFormat.bytes(row.total)).monospacedDigit().fontWeight(.semibold)
                    }
                    .width(90)
                }
                .padding(16)
            }
        }
        .navigationTitle("Statistics")
        .navigationSubtitle(controller.isConnected ? "Per proxy, since the engine started" : "")
        .task(id: controller.isConnected) {
            while controller.isConnected, !Task.isCancelled {
                do {
                    if let totals = try await appModel.meowAPI.getProxyTraffic() {
                        rows = totals.map { PolicyRow(name: $0.key, totals: $0.value) }
                        isSupported = true
                    } else {
                        isSupported = false
                    }
                } catch {
                    // Keep the last rows; the next poll retries.
                }
                try? await Task.sleep(for: .seconds(1))
            }
            rows = []
        }
    }

    private var maxTotal: Int64 {
        rows.map(\.total).max() ?? 0
    }
}

struct PolicyRow: Identifiable {
    var id: String {
        name
    }

    let name: String
    let download: Int64
    let upload: Int64
    let total: Int64

    init(name: String, totals: ByteTotals) {
        self.name = name
        download = totals.download
        upload = totals.upload
        total = totals.total
    }
}

private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.accentColor.opacity(0.75))
                .frame(width: max(2, geometry.size.width * fraction))
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 6)
    }
}

// MARK: - DNS

struct DNSPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @State private var results: [DnsResult] = []
    @State private var search = ""
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !controller.isConnected {
                EngineOfflineView(message: "Connect to browse the engine's DNS cache.")
            } else if results.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No Cached Answers" : "No Matches",
                    systemImage: "globe",
                    description: Text(errorMessage ?? "Answers the engine resolved show up here."),
                )
            } else {
                Table(results) {
                    TableColumn("Name") { result in
                        Text(result.name).fontWeight(.medium)
                    }
                    .width(min: 180, ideal: 280)
                    TableColumn("Addresses") { result in
                        Text(result.ips.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .help(result.ips.joined(separator: "\n"))
                    }
                    .width(min: 160, ideal: 280)
                    TableColumn("Server") { result in
                        Text(result.fromServer ?? "—").foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 160)
                    TableColumn("TTL") { result in
                        Text("\(result.ttl) s").monospacedDigit()
                    }
                    .width(70)
                }
                .contextMenu(forSelectionType: DnsResult.ID.self) { ids in
                    if let id = ids.first, let result = results.first(where: { $0.id == id }) {
                        Button("Copy Name") { MacPasteboard.copy(result.name) }
                        Button("Copy Addresses") { MacPasteboard.copy(result.ips.joined(separator: "\n")) }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("DNS")
        .navigationSubtitle(controller.isConnected ? "\(results.count) cached answers" : "")
        .searchable(text: $search, placement: .toolbar, prompt: "Domain")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!controller.isConnected)
            }
        }
        .task(id: "\(controller.isConnected)-\(search)") {
            // Debounce typing; the engine filters server-side.
            if !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        guard controller.isConnected else {
            results = []
            return
        }
        do {
            let query = search.trimmingCharacters(in: .whitespaces)
            results = try await appModel.meowAPI.getDnsResults(search: query.isEmpty ? nil : query, limit: 512)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
