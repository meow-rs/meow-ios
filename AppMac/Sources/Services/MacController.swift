import AppKit
import MeowModels
import Observation
import SwiftData

/// Where the app shows itself: the menu bar extra, the Dock, or both.
enum MacPresence: String, CaseIterable, Identifiable {
    case menuBarAndDock
    case menuBar
    case dock

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .menuBarAndDock: "Menu bar and Dock"
        case .menuBar: "Menu bar only"
        case .dock: "Dock only"
        }
    }

    var showsMenuBarExtra: Bool {
        self != .dock
    }
}

enum MacAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// The Mac shell's view of the tunnel: connects through the system extension,
/// switches profiles and route modes, and owns the Mac-only preferences.
/// Mirrors what the iOS views do with the same shared services.
@MainActor
@Observable
final class MacController {
    let appModel: AppModel
    let installer = SystemExtensionInstaller()
    let engine: EngineMonitor

    /// The engine's routing mode; nil until a connected engine answered.
    private(set) var routeMode: RouteMode?
    /// One-shot failure to show in an alert (profile switch, import, …).
    var alertMessage: String?

    var presence: MacPresence {
        didSet {
            defaults.set(presence.rawValue, forKey: Keys.presence)
            applyPresence()
        }
    }

    var showsSpeedInMenuBar: Bool {
        didSet { defaults.set(showsSpeedInMenuBar, forKey: Keys.menuBarSpeed) }
    }

    var appearance: MacAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    private enum Keys {
        static let presence = "mac.presence"
        static let menuBarSpeed = "mac.menuBarSpeed"
        static let appearance = "mac.appearance"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var didStart = false

    init(appModel: AppModel) {
        self.appModel = appModel
        engine = EngineMonitor(appModel: appModel)
        presence = MacPresence(rawValue: defaults.string(forKey: Keys.presence) ?? "") ?? .menuBarAndDock
        showsSpeedInMenuBar = defaults.bool(forKey: Keys.menuBarSpeed)
        appearance = MacAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
    }

    /// Called once the app model has bootstrapped.
    func start() {
        guard !didStart else { return }
        didStart = true
        applyPresence()
        applyAppearance()
        installer.activateIfPreviouslyActivated()
        engine.start()
    }

    // MARK: - Tunnel

    var stage: VpnStage {
        appModel.vpnManager.stage
    }

    var isConnected: Bool {
        stage == .connected
    }

    var isInFlight: Bool {
        stage == .preparing || stage == .connecting || stage == .stopping
    }

    var connectedSince: Date? {
        isConnected ? appModel.ipcBridge.currentState.startedAt : nil
    }

    func toggle() {
        if isConnected || stage == .connecting {
            disconnect()
        } else {
            connect()
        }
    }

    func connect() {
        guard !isInFlight else { return }
        guard let profile = selectedProfile() else {
            alertMessage = "Add a config and select it before connecting."
            return
        }
        // The start options carry the active config file, so make sure the
        // selected profile's YAML is actually there.
        if !FileManager.default.fileExists(atPath: AppGroup.configURL.path) {
            try? appModel.subscriptionService.writeActiveConfig(profile)
        }
        Task {
            guard await installer.ensureActivated() else { return }
            appModel.ipcBridge.send(.start, profileID: profile.id)
            await appModel.vpnManager.connect()
        }
    }

    func disconnect() {
        appModel.ipcBridge.send(.stop)
        Task { await appModel.vpnManager.disconnect() }
    }

    // MARK: - Profiles

    func selectedProfile() -> Profile? {
        let context = AppModelContainer.shared.container.mainContext
        let descriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.isSelected })
        return try? context.fetch(descriptor).first
    }

    /// Make `profile` the active one; a running engine hot-reloads into it.
    func select(_ profile: Profile) {
        guard !profile.isSelected else { return }
        do {
            try appModel.subscriptionService.select(profile)
            if isConnected {
                appModel.ipcBridge.send(.reload, profileID: profile.id)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Re-fetch a subscription; the engine reloads if it was running it.
    func refresh(_ profile: Profile) async {
        guard !profile.url.isEmpty else { return }
        do {
            try await appModel.subscriptionService.refresh(profile)
            if profile.isSelected, isConnected {
                appModel.ipcBridge.send(.reload, profileID: profile.id)
            }
        } catch {
            alertMessage = "\(profile.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Route mode

    func refreshRouteMode() async {
        guard isConnected else {
            routeMode = nil
            return
        }
        if let resp = try? await appModel.meowAPI.getConfigs(), let mode = RouteMode(wire: resp.mode) {
            routeMode = mode
            WidgetReloader.routeModeDidChange(mode)
        }
    }

    func setRouteMode(_ mode: RouteMode) {
        guard isConnected, mode != routeMode else { return }
        let previous = routeMode
        routeMode = mode
        Task {
            do {
                try await appModel.meowAPI.setMode(mode.wire)
                WidgetReloader.routeModeDidChange(mode)
            } catch {
                routeMode = previous
                await refreshRouteMode()
            }
        }
    }

    // MARK: - Proxy selection

    /// Select `proxy` in `group` and remember it on the active profile so the
    /// next engine start replays it.
    func selectProxy(_ proxy: String, in group: String) async {
        do {
            try await appModel.meowAPI.selectProxy(group: group, name: proxy)
            if let profile = selectedProfile() {
                var selections = profile.selectedProxies
                selections[group] = proxy
                profile.selectedProxies = selections
                try? AppModelContainer.shared.container.mainContext.save()
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Shell

    private func applyPresence() {
        let policy: NSApplication.ActivationPolicy = presence == .menuBar ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate()
        }
    }

    private func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func showMainWindow(_ open: () -> Void) {
        open()
        NSApp.activate()
    }
}

/// Polls the engine for what the sidebar badges and the Connections page show.
/// Only the Connections page asks for one-second updates; otherwise the
/// badges refresh every few seconds.
@MainActor
@Observable
final class EngineMonitor {
    private(set) var connections: [Connection] = []
    private(set) var rulesCount: Int?
    private(set) var providersCount: Int?
    /// Freeze the Connections table (the page's pause button).
    var isPaused = false
    /// Set while the Connections page is on screen.
    var wantsLiveConnections = false {
        didSet {
            if wantsLiveConnections, !oldValue {
                Task { await refreshConnections() }
            }
        }
    }

    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var countsGeneration: Int?

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await tick()
                try? await Task.sleep(for: wantsLiveConnections ? .seconds(1) : .seconds(5))
            }
        }
    }

    func refreshConnections() async {
        guard appModel.vpnManager.stage == .connected, !isPaused else { return }
        if let resp = try? await appModel.meowAPI.getConnections() {
            connections = resp.connections ?? []
        }
    }

    func close(_ id: String) async {
        try? await appModel.meowAPI.closeConnection(id: id)
        connections.removeAll { $0.id == id }
        await refreshConnections()
    }

    func closeAll() async {
        try? await appModel.meowAPI.closeAllConnections()
        connections = []
        await refreshConnections()
    }

    private func tick() async {
        guard appModel.vpnManager.stage == .connected else {
            connections = []
            rulesCount = nil
            providersCount = nil
            countsGeneration = nil
            return
        }
        await refreshConnections()
        // Rules and providers only change with a (re)started engine.
        if countsGeneration != appModel.replayGeneration {
            let api = appModel.meowAPI
            let rules = try? await api.getRules()
            let providers = try? await api.getProviders()
            rulesCount = rules?.rules.count
            providersCount = providers.map { Self.userProviders($0).count }
            if rules != nil {
                countsGeneration = appModel.replayGeneration
            }
        }
    }

    /// The engine lists its built-in `default` provider too; the user's are
    /// the ones fetched from somewhere.
    static func userProviders(_ response: ProvidersResponse) -> [Provider] {
        response.providers.values
            .filter { $0.vehicleType != "Compatible" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
