import MeowModels
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ConfigsPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @Query(sort: \Profile.name) private var profiles: [Profile]

    @State private var isAddingSubscription = false
    @State private var pastedURL = ""
    @State private var isImportingFile = false
    @State private var isRefreshingAll = false
    @State private var editing: Profile?
    @State private var editingInfo: Profile?
    @State private var pendingDelete: Profile?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Profiles")
                    ForEach(profiles) { profile in
                        ProfileCard(
                            profile: profile,
                            onEdit: { editing = profile },
                            onEditInfo: { editingInfo = profile },
                            onDelete: { pendingDelete = profile },
                        )
                    }
                    ImportDropZone(onImport: importFiles)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Engine")
                    EngineCard()
                    RouteModeCard()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
        .navigationTitle("Configs")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Label("Update All", systemImage: "arrow.clockwise")
                }
                .help("Update all subscriptions")
                .disabled(isRefreshingAll || !profiles.contains { !$0.url.isEmpty })

                Button {
                    isImportingFile = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import a YAML file")

                Menu {
                    Button("Subscription URL…") { isAddingSubscription = true }
                    Button("YAML File…") { isImportingFile = true }
                    Button("Paste Subscription Link") { pasteSubscription() }
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                } label: {
                    Label("Add Config", systemImage: "plus")
                }
                .menuIndicator(.visible)
            }
        }
        .onPasteCommand(of: [.url, .plainText]) { _ in pasteSubscription() }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.yaml, .plainText, .data],
            allowsMultipleSelection: true,
        ) { result in
            if case let .success(urls) = result {
                importFiles(urls)
            }
        }
        .sheet(isPresented: $isAddingSubscription) {
            AddSubscriptionSheet(initialURL: pastedURL)
        }
        .sheet(item: $editing) { profile in
            YAMLEditorSheet(profile: profile)
        }
        .sheet(item: $editingInfo) { profile in
            ProfileInfoSheet(profile: profile)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            }),
            presenting: pendingDelete,
        ) { profile in
            Button("Delete", role: .destructive) { delete(profile) }
        } message: { _ in
            Text("The config and its saved proxy selections are removed from this Mac.")
        }
    }

    private var subtitle: String {
        let count = profiles.count == 1 ? "1 profile" : "\(profiles.count) profiles"
        let autoUpdate = profiles.contains { $0.updateInterval != .manual } ? "auto-update on" : "auto-update off"
        return "\(count) · \(autoUpdate)"
    }

    private func refreshAll() async {
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        for profile in profiles where !profile.url.isEmpty {
            await controller.refresh(profile)
        }
    }

    private func pasteSubscription() {
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = URL(string: text), let link = SubscriptionDeepLink.parse(url) {
            pastedURL = link.subscriptionURL.absoluteString
        } else if text.hasPrefix("https://") || text.hasPrefix("http://") {
            pastedURL = text
        } else {
            pastedURL = ""
        }
        isAddingSubscription = true
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let yaml = try String(contentsOf: url, encoding: .utf8)
                    let name = url.deletingPathExtension().lastPathComponent
                    let profile = try await appModel.subscriptionService.addLocal(name: name, yamlContent: yaml)
                    if controller.selectedProfile() == nil {
                        controller.select(profile)
                    }
                } catch {
                    controller.alertMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private func delete(_ profile: Profile) {
        let wasSelected = profile.isSelected
        do {
            try appModel.subscriptionService.delete(profile)
            if wasSelected, controller.isConnected {
                controller.disconnect()
            }
        } catch {
            controller.alertMessage = error.localizedDescription
        }
    }
}

// MARK: - Profile card

private struct ProfileCard: View {
    let profile: Profile
    let onEdit: () -> Void
    let onEditInfo: () -> Void
    let onDelete: () -> Void

    @Environment(MacController.self) private var controller
    @State private var isRefreshing = false
    @State private var showsQRCode = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(profile.isSelected ? Color.accentColor : MacTheme.secondaryInk)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MacTheme.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MacTheme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if !profile.url.isEmpty {
                    iconButton("arrow.clockwise", help: "Update now") {
                        Task {
                            isRefreshing = true
                            await controller.refresh(profile)
                            isRefreshing = false
                        }
                    }
                    .disabled(isRefreshing)
                    .opacity(isRefreshing ? 0.4 : 1)
                    iconButton("qrcode", help: "Show subscription QR code") { showsQRCode = true }
                        .popover(isPresented: $showsQRCode) { QRCodePopover(payload: profile.url) }
                }
                iconButton("pencil", help: "Edit YAML", action: onEdit)
                Menu {
                    Button("Use This Config") { controller.select(profile) }
                        .disabled(profile.isSelected)
                    Button("Edit Info…", action: onEditInfo)
                    Button("Edit YAML…", action: onEdit)
                    if !profile.url.isEmpty {
                        Button("Copy Subscription URL") { MacPasteboard.copy(profile.url) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .foregroundStyle(Color.accentColor)
        }
        .macCard(isSelected: profile.isSelected, padding: 14)
        .contentShape(Rectangle())
        .onTapGesture { controller.select(profile) }
    }

    private var detail: String {
        let updated = "Updated \(MacFormat.relative(profile.lastUpdated))"
        guard !profile.url.isEmpty else { return "\(updated) · Local file" }
        let cadence = switch profile.updateInterval {
        case .manual: "Manual updates"
        case .daily: "Updates daily"
        case .weekly: "Updates weekly"
        }
        return "\(updated) · \(cadence)"
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct ImportDropZone: View {
    let onImport: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop a Clash or Mihomo YAML file here")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MacTheme.ink)
                Text("Or copy a subscription link and press ⌘V in this window")
                    .font(.caption)
                    .foregroundStyle(MacTheme.secondaryInk)
            }
            Spacer()
        }
        .padding(16)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : MacTheme.cardBorder,
                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]),
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            onImport(files)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

// MARK: - Engine column

private struct EngineCard: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @Query(filter: #Predicate<Profile> { $0.isSelected }) private var selected: [Profile]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                StatusGlyph(stage: controller.stage, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MacTheme.stageTitle(controller.stage))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(MacTheme.ink)
                    Text(selected.first?.name ?? "No config selected")
                        .foregroundStyle(MacTheme.secondaryInk)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .top) {
                    MetricView(title: "Download", value: MacFormat.rate(traffic.downloadRate))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MetricView(title: "Upload", value: MacFormat.rate(traffic.uploadRate))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MetricView(title: "Uptime", value: uptime(at: context.date))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macCard()
    }

    private var traffic: TrafficSnapshot {
        controller.isConnected ? appModel.ipcBridge.currentTraffic : .init()
    }

    private func uptime(at date: Date) -> String {
        guard let since = controller.connectedSince else { return "—" }
        return MacFormat.uptime(from: since, to: date)
    }
}

private struct RouteModeCard: View {
    @Environment(MacController.self) private var controller

    var body: some View {
        HStack {
            Label("Route Mode", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MacTheme.ink)
            Spacer()
            Picker("Route Mode", selection: selection) {
                ForEach(RouteMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!controller.isConnected)
        }
        .macCard(padding: 12)
        .help(controller.isConnected ? "" : "Connect to change the route mode")
    }

    private var selection: Binding<RouteMode> {
        Binding(
            get: { controller.routeMode ?? .rule },
            set: { controller.setRouteMode($0) },
        )
    }
}

extension RouteMode {
    var title: String {
        switch self {
        case .rule: "Rule"
        case .all: "All"
        case .direct: "Direct"
        }
    }
}
