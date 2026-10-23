import MeowModels
import SwiftUI

/// Loads the engine's proxy groups; shared by the Proxy Groups page and the
/// menu bar popover.
@MainActor
@Observable
final class ProxyGroupsModel {
    private(set) var groups: [ProxyGroupModel] = []
    private(set) var errorMessage: String?
    private(set) var testingGroups: Set<String> = []

    func load(api: MeowAPI) async {
        do {
            groups = try await ProxyGroupModel.build(from: api.getProxies().proxies)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        groups = []
        errorMessage = nil
    }

    func test(_ group: ProxyGroupModel, api: MeowAPI) async {
        testingGroups.insert(group.name)
        defer { testingGroups.remove(group.name) }
        _ = try? await api.testGroupDelay(group: group.name, url: group.testURL ?? MeowAPI.delayTestURL)
        await load(api: api)
    }

    func testAll(api: MeowAPI) async {
        let all = groups
        testingGroups.formUnion(all.map(\.name))
        await withTaskGroup(of: Void.self) { tasks in
            for group in all {
                tasks.addTask {
                    _ = try? await api.testGroupDelay(group: group.name, url: group.testURL ?? MeowAPI.delayTestURL)
                }
            }
        }
        testingGroups.subtract(all.map(\.name))
        await load(api: api)
    }

    func test(proxy: String, api: MeowAPI) async {
        _ = try? await api.testDelay(proxy: proxy, url: MeowAPI.delayTestURL)
        await load(api: api)
    }

    static func isSelectable(_ group: ProxyGroupModel) -> Bool {
        group.type == "Selector"
    }

    static func typeTitle(_ type: String) -> String {
        switch type {
        case "Selector": "Select"
        case "URLTest": "URLTest"
        case "Fallback": "Fallback"
        case "LoadBalance": "Load Balance"
        case "Relay": "Relay"
        default: type
        }
    }

    static func symbol(for type: String) -> String {
        switch type {
        case "URLTest": "gauge.with.dots.needle.67percent"
        case "Fallback": "arrow.uturn.backward"
        case "LoadBalance": "scale.3d"
        case "Relay": "point.3.connected.trianglepath.dotted"
        default: "square.stack.3d.up"
        }
    }
}

struct ProxyGroupsPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @State private var model = ProxyGroupsModel()
    @State private var selectedGroupName: String?
    @State private var search = ""

    var body: some View {
        Group {
            if !controller.isConnected {
                EngineOfflineView(message: "Connect to pick proxies and test their latency.")
            } else if model.groups.isEmpty {
                if let error = model.errorMessage {
                    ContentUnavailableView(
                        "Couldn't Load Proxy Groups",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error),
                    )
                } else {
                    ProgressView()
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    groupList
                        .frame(width: 280)
                    if let group = selectedGroup {
                        GroupDetail(group: group, search: search, model: model)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Proxy Groups")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search proxies")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.testAll(api: appModel.meowAPI) }
                } label: {
                    Label("Test All", systemImage: "bolt")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!controller.isConnected || !model.testingGroups.isEmpty)
            }
        }
        .task(id: reloadKey) {
            guard controller.isConnected else {
                model.clear()
                return
            }
            await model.load(api: appModel.meowAPI)
        }
    }

    private var reloadKey: String {
        "\(controller.isConnected)-\(appModel.replayGeneration)"
    }

    private var selectedGroup: ProxyGroupModel? {
        model.groups.first { $0.name == selectedGroupName } ?? model.groups.first
    }

    private var subtitle: String {
        guard controller.isConnected, !model.groups.isEmpty else { return "" }
        let proxies = Set(model.groups.flatMap { $0.children.map(\.name) })
            .subtracting(model.groups.map(\.name)).count
        return "\(model.groups.count) groups · \(proxies) proxies"
    }

    private var groupList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.groups) { group in
                    GroupRow(group: group, isSelected: group.id == selectedGroup?.id)
                        .onTapGesture { selectedGroupName = group.name }
                }
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
        .macCard(padding: 0)
    }
}

private struct GroupRow: View {
    let group: ProxyGroupModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ProxyGroupsModel.symbol(for: group.type))
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MacTheme.ink)
                Text("\(ProxyGroupsModel.typeTitle(group.type)) · \(group.children.count)")
                    .font(.caption)
                    .foregroundStyle(MacTheme.secondaryInk)
            }
            Spacer(minLength: 6)
            if let now = group.now {
                Text(now)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? MacTheme.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

private struct GroupDetail: View {
    let group: ProxyGroupModel
    let search: String
    let model: ProxyGroupsModel

    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(MacTheme.ink)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(MacTheme.secondaryInk)
                }
                Spacer()
                Button {
                    Task { await model.test(group, api: appModel.meowAPI) }
                } label: {
                    if model.testingGroups.contains(group.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Group", systemImage: "bolt")
                    }
                }
                .disabled(model.testingGroups.contains(group.name))
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(children) { child in
                        ProxyCard(child: child, isSelected: child.name == group.now, selectable: selectable)
                            .onTapGesture {
                                guard selectable, child.name != group.now else { return }
                                Task {
                                    await controller.selectProxy(child.name, in: group.name)
                                    await model.load(api: appModel.meowAPI)
                                }
                            }
                            .contextMenu {
                                Button("Test Latency") {
                                    Task { await model.test(proxy: child.name, api: appModel.meowAPI) }
                                }
                                Button("Copy Name") { MacPasteboard.copy(child.name) }
                            }
                    }
                }
                .padding(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectable: Bool {
        ProxyGroupsModel.isSelectable(group)
    }

    private var children: [ProxyGroupModel.Child] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return group.children }
        return group.children.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var summary: String {
        var parts = ["\(ProxyGroupsModel.typeTitle(group.type))", "\(group.children.count) proxies"]
        if let now = group.now {
            parts.append("using \(now)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ProxyCard: View {
    let child: ProxyGroupModel.Child
    let isSelected: Bool
    let selectable: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : MacTheme.secondaryInk)
                .opacity(selectable || isSelected ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(child.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MacTheme.ink)
                    .lineLimit(1)
                Text(child.type.isEmpty ? "Provider" : child.type)
                    .font(.caption)
                    .foregroundStyle(MacTheme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            DelayBadge(delay: child.delay, isDirect: DelayBadge.isDirectType(child.type))
        }
        .macCard(isSelected: isSelected, padding: 12)
        .contentShape(Rectangle())
    }
}
