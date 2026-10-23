import AppKit
import MeowModels
import SwiftData
import SwiftUI

/// The window-style menu bar extra: status and toggle, live rates, route
/// mode, profile switching and the Selector groups.
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Profile.name) private var profiles: [Profile]
    @State private var groups = ProxyGroupsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rateTiles
            if controller.isConnected {
                section("Route Mode") {
                    Picker("Route Mode", selection: routeMode) {
                        ForEach([RouteMode.rule, .all, .direct], id: \.self) { mode in
                            Text(mode.title).tag(Optional(mode))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            if !profiles.isEmpty {
                section("Profile") {
                    VStack(spacing: 2) {
                        ForEach(profiles) { profile in
                            ProfileRow(profile: profile) { controller.select(profile) }
                        }
                    }
                }
            }
            if controller.isConnected, !selectorGroups.isEmpty {
                section("Proxy Groups") {
                    VStack(spacing: 2) {
                        ForEach(selectorGroups) { group in
                            GroupMenuRow(group: group) { proxy in
                                Task {
                                    await controller.selectProxy(proxy, in: group.name)
                                    await groups.load(api: appModel.meowAPI)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            VStack(spacing: 0) {
                CommandRow(title: "Open meow", shortcut: "⌘O") {
                    controller.showMainWindow { openWindow(id: MacWindowID.main) }
                }
                .keyboardShortcut("o")
                CommandRow(title: "Settings…", shortcut: "⌘,") {
                    openSettings()
                    NSApp.activate()
                }
                .keyboardShortcut(",")
                CommandRow(title: "Quit meow", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(MacTheme.canvas)
        .task(id: "\(controller.isConnected)-\(appModel.replayGeneration)") {
            guard controller.isConnected else {
                groups.clear()
                return
            }
            await groups.load(api: appModel.meowAPI)
            await controller.refreshRouteMode()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            StatusGlyph(stage: controller.stage, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(MacTheme.stageTitle(controller.stage))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MacTheme.ink)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(at: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(MacTheme.secondaryInk)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("Connected", isOn: Binding(
                get: { controller.isConnected || controller.stage == .connecting },
                set: { _ in controller.toggle() },
            ))
            .toggleStyle(.switch)
            .tint(MacTheme.connected)
            .labelsHidden()
            .disabled(controller.stage == .preparing || controller.stage == .stopping)
        }
    }

    private func detail(at now: Date) -> String {
        let name = profiles.first(where: \.isSelected)?.name ?? "No config selected"
        if let error = appModel.vpnManager.lastError, !controller.isConnected {
            return error
        }
        guard let since = controller.connectedSince else { return name }
        return "\(name) · \(MacFormat.uptime(from: since, to: now))"
    }

    private var rateTiles: some View {
        let traffic = controller.isConnected ? appModel.ipcBridge.currentTraffic : TrafficSnapshot()
        return HStack(spacing: 8) {
            RateTile(title: "Download", symbol: "arrow.down", tint: MacTheme.download, value: traffic.downloadRate)
            RateTile(title: "Upload", symbol: "arrow.up", tint: MacTheme.upload, value: traffic.uploadRate)
        }
    }

    // MARK: - Sections

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MacTheme.secondaryInk)
                .padding(.leading, 2)
            content()
        }
    }

    private var routeMode: Binding<RouteMode?> {
        Binding(
            get: { controller.routeMode },
            set: {
                if let mode = $0 {
                    controller.setRouteMode(mode)
                }
            },
        )
    }

    private var selectorGroups: [ProxyGroupModel] {
        groups.groups.filter(ProxyGroupsModel.isSelectable)
    }
}

private struct RateTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(MacTheme.secondaryInk)
                .labelStyle(TintedIconLabelStyle(tint: tint))
            Text(MacFormat.rate(value))
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(MacTheme.ink)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .macCard(padding: 11)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(profile.isSelected ? 1 : 0)
                Text(profile.name)
                    .foregroundStyle(MacTheme.ink)
                    .lineLimit(1)
                Spacer()
                Text(MacFormat.relative(profile.lastUpdated))
                    .font(.caption)
                    .foregroundStyle(MacTheme.secondaryInk)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if profile.isSelected {
            return MacTheme.selectionFill
        }
        return isHovered ? MacTheme.selectionFill.opacity(0.5) : .clear
    }
}

private struct GroupMenuRow: View {
    let group: ProxyGroupModel
    let select: (String) -> Void

    var body: some View {
        Menu {
            ForEach(group.children) { child in
                Toggle(isOn: Binding(get: { child.name == group.now }, set: { _ in select(child.name) })) {
                    if let delay = child.delay, delay > 0 {
                        Text("\(child.name)    \(delay) ms")
                    } else {
                        Text(child.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(group.name)
                    .foregroundStyle(MacTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let now = group.now {
                    Text(now)
                        .foregroundStyle(MacTheme.secondaryInk)
                        .lineLimit(1)
                    DelayBadge(delay: group.children.first { $0.name == now }?.delay)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacTheme.secondaryInk)
            }
            .padding(.leading, 24)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

private struct CommandRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(isHovered ? .white : MacTheme.ink)
                Spacer()
                Text(shortcut).foregroundStyle(isHovered ? .white.opacity(0.85) : MacTheme.secondaryInk)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
