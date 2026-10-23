import MeowModels
import SwiftData
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case configs
    case proxyGroups
    case connections
    case rules
    case providers
    case traffic
    case statistics
    case logs
    case dns

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .configs: "Configs"
        case .proxyGroups: "Proxy Groups"
        case .connections: "Connections"
        case .rules: "Rules"
        case .providers: "Providers"
        case .traffic: "Traffic"
        case .statistics: "Statistics"
        case .logs: "Logs"
        case .dns: "DNS"
        }
    }

    var symbol: String {
        switch self {
        case .configs: "doc.text"
        case .proxyGroups: "square.stack.3d.up"
        case .connections: "arrow.left.arrow.right"
        case .rules: "arrow.triangle.branch"
        case .providers: "tray.2"
        case .traffic: "chart.xyaxis.line"
        case .statistics: "gauge.with.dots.needle.33percent"
        case .logs: "list.bullet"
        case .dns: "globe"
        }
    }
}

/// Main window: sidebar with the tunnel status card, one page per section,
/// and the Connect / Disconnect button at the end of every page's toolbar.
struct MacRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @SceneStorage("sidebar.selection") private var selection: SidebarItem = .configs
    @Query private var profiles: [Profile]
    @State private var pendingDeepLink: DeepLinkImportConfirmation?

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 300)
        } detail: {
            page
                .macPage()
                .safeAreaInset(edge: .top, spacing: 0) { MacBanners() }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        ConnectButton()
                    }
                }
        }
        .frame(minWidth: 980, minHeight: 620)
        .task(id: routeModeKey) { await controller.refreshRouteMode() }
        .onOpenURL(perform: handleDeepLink)
        .alert(
            "meow",
            isPresented: Binding(
                get: { controller.alertMessage != nil },
                set: {
                    if !$0 {
                        controller.alertMessage = nil
                    }
                },
            ),
            presenting: controller.alertMessage,
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .sheet(item: $pendingDeepLink) { confirmation in
            DeepLinkImportSheet(confirmation: confirmation)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch selection {
        case .configs: ConfigsPage()
        case .proxyGroups: ProxyGroupsPage()
        case .connections: ConnectionsPage()
        case .rules: RulesPage()
        case .providers: ProvidersPage()
        case .traffic: TrafficPage()
        case .statistics: StatisticsPage()
        case .logs: LogsPage()
        case .dns: DNSPage()
        }
    }

    private var routeModeKey: String {
        "\(controller.isConnected)-\(appModel.replayGeneration)"
    }

    private func handleDeepLink(_ url: URL) {
        guard let link = SubscriptionDeepLink.parse(url) else { return }
        selection = .configs
        pendingDeepLink = .make(for: link, existingProfiles: profiles.map { ($0.id, $0.url) })
    }
}

// MARK: - Sidebar

private struct MacSidebar: View {
    @Binding var selection: SidebarItem
    @Environment(MacController.self) private var controller

    var body: some View {
        List(selection: Binding(get: { selection }, set: {
            if let item = $0 {
                selection = item
            }
        })) {
            Section {
                row(.configs)
                row(.proxyGroups)
            }
            Section("Engine") {
                row(.connections, count: controller.isConnected ? controller.engine.connections.count : nil)
                row(.rules, count: controller.engine.rulesCount)
                row(.providers, count: controller.engine.providersCount)
            }
            Section("Utility") {
                row(.traffic)
                row(.statistics)
                row(.logs)
                row(.dns)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarStatusCard()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsLink {
                HStack {
                    Label("Settings", systemImage: "gearshape")
                    Spacer()
                    Text("⌘,")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func row(_ item: SidebarItem, count: Int? = nil) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(count ?? 0)
            .tag(item)
    }
}

private struct SidebarStatusCard: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusGlyph(stage: controller.stage, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(MacTheme.stageTitle(controller.stage))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MacTheme.ink)
                    Text(selected.first?.name ?? "No config selected")
                        .font(.caption)
                        .foregroundStyle(MacTheme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                Text("↓ \(MacFormat.rate(traffic.downloadRate))")
                Text("↑ \(MacFormat.rate(traffic.uploadRate))")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(MacTheme.secondaryInk)
        }
        .macCard(padding: 12)
    }

    private var traffic: TrafficSnapshot {
        controller.isConnected ? appModel.ipcBridge.currentTraffic : .init()
    }
}

// MARK: - Toolbar

struct ConnectButton: View {
    @Environment(MacController.self) private var controller

    var body: some View {
        if controller.installer.state == .needsApproval {
            Button {
                controller.installer.openSystemSettings()
            } label: {
                Label("Allow in System Settings", systemImage: "lock.shield")
            }
            .buttonStyle(.borderedProminent)
            .tint(MacTheme.warning)
        } else {
            Button(action: controller.toggle) {
                Label(title, systemImage: "power")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isConnected || controller.stage == .stopping ? MacTheme.danger : .accentColor)
            .disabled(controller.isInFlight && controller.stage != .connecting)
            .help(controller.isConnected ? "Disconnect (⇧⌘K)" : "Connect (⇧⌘K)")
        }
    }

    private var title: String {
        switch controller.stage {
        case .connected: "Disconnect"
        case .preparing: "Preparing…"
        case .connecting: "Connecting…"
        case .stopping: "Disconnecting…"
        case .idle, .stopped, .error: "Connect"
        }
    }
}

/// System-extension and tunnel problems, pinned above every page.
private struct MacBanners: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller

    var body: some View {
        VStack(spacing: 8) {
            switch controller.installer.state {
            case .needsApproval:
                banner(
                    "meow needs its network extension allowed in System Settings › General › Login Items & Extensions.",
                    tint: MacTheme.warning,
                    action: ("Open System Settings", controller.installer.openSystemSettings),
                )
            case .needsRelocation:
                banner(
                    "Move meow to the Applications folder and open it from there to install its network extension.",
                    tint: MacTheme.warning,
                    action: nil,
                )
            case let .failed(message):
                banner(
                    "The network extension couldn't be installed: \(message)",
                    tint: MacTheme.danger,
                    action: ("Try Again", controller.installer.activate),
                )
            case .unknown, .activating, .activated:
                EmptyView()
            }
            if let message = appModel.vpnManager.lastError {
                banner(message, tint: MacTheme.danger, action: ("Dismiss", appModel.vpnManager.clearError))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    private func banner(_ message: String, tint: Color, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(MacTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.0, action: action.1)
            }
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }
}
