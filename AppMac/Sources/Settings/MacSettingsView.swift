import AppKit
import MeowModels
import ServiceManagement
import SwiftUI

struct MacSettingsView: View {
    /// One copy for every tab: each save writes the whole struct.
    @State private var preferences = MacPreferences()

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(preferences: preferences) }
            Tab("Network", systemImage: "globe") { NetworkSettings(preferences: preferences) }
            Tab("Appearance", systemImage: "circle.lefthalf.filled") { AppearanceSettings() }
            Tab("Diagnostics", systemImage: "waveform.path.ecg") { DiagnosticsSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 560)
        .scenePadding(.bottom)
    }
}

// MARK: - Preferences store

/// The shared `Preferences`, saved on every change. Tunnel-side preferences
/// travel with the next start (or config reload) of the extension.
@MainActor
@Observable
final class MacPreferences {
    var value: Preferences {
        didSet { value.save(to: AppGroup.defaults) }
    }

    init() {
        value = Preferences.load(from: AppGroup.defaults)
    }

    func binding<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.value[keyPath: keyPath] },
            set: { self.value[keyPath: keyPath] = $0 },
        )
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    let preferences: MacPreferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                Toggle("Launch meow at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Picker("Show meow in", selection: $controller.presence) {
                    ForEach(MacPresence.allCases) { presence in
                        Text(presence.title).tag(presence)
                    }
                }
                Toggle("Show speed in menu bar", isOn: $controller.showsSpeedInMenuBar)
                    .disabled(!controller.presence.showsMenuBarExtra)
            } footer: {
                if let loginItemError {
                    Text(loginItemError).foregroundStyle(MacTheme.danger)
                }
            }
            Section {
                Toggle("Connect On Demand", isOn: preferences.binding(\.onDemand))
                    .onChange(of: preferences.value.onDemand) {
                        // Push the flag into the saved tunnel configuration
                        // now rather than at the next connect.
                        Task { await appModel.vpnManager.refresh() }
                    }
                Picker("Log Level", selection: preferences.binding(\.logLevel)) {
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warning").tag("warning")
                    Text("Error").tag("error")
                    Text("Silent").tag("silent")
                }
            } footer: {
                Text("On demand, macOS brings the tunnel back up after sleep or a network change.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = service.status == .enabled
        }
    }
}

// MARK: - Network

private struct NetworkSettings: View {
    let preferences: MacPreferences

    var body: some View {
        Form {
            Section {
                TextField("Mixed port", value: preferences.binding(\.mixedPort), format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                Toggle("Allow connections from the LAN", isOn: preferences.binding(\.allowLan))
            } footer: {
                Text(
                    "The engine's HTTP and SOCKS proxy listens on this port; allowing the LAN "
                        + "exposes it to other devices on your network.",
                )
            }
            Section {
                Toggle("IPv6", isOn: preferences.binding(\.ipv6Enabled))
                Toggle("Block HTTP/3 (QUIC)", isOn: preferences.binding(\.blockHTTP3))
            } footer: {
                Text("Changes apply the next time meow connects.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Environment(MacController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                Picker("Appearance", selection: $controller.appearance) {
                    ForEach(MacAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettings: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        let installer = controller.installer
        Form {
            Section("System Extension") {
                LabeledContent("Status") {
                    Text(extensionStatus(installer.state))
                        .foregroundStyle(extensionTint(installer.state))
                }
                HStack {
                    Spacer()
                    if installer.state == .needsApproval {
                        Button("Open System Settings") { installer.openSystemSettings() }
                    }
                    Button("Reinstall Extension") { installer.activate() }
                        .disabled(installer.state == .activating)
                }
            }
            Section("Tunnel") {
                LabeledContent("Status", value: MacTheme.stageTitle(controller.stage))
                if controller.isConnected {
                    LabeledContent("Extension memory", value: "\(appModel.ipcBridge.currentTraffic.footprintMB) MB")
                }
                HStack {
                    if let exportError {
                        Text(exportError)
                            .font(.caption)
                            .foregroundStyle(MacTheme.danger)
                    }
                    Spacer()
                    Button("Show Data Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppGroup.containerURL])
                    }
                    Button("Export Tunnel Log…", action: exportLog)
                        .disabled(isExporting)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func exportLog() {
        isExporting = true
        Task {
            defer { isExporting = false }
            guard let data = await appModel.ipcBridge.fetchTunnelLog() else {
                exportError = "Connect first; the log lives in the running extension."
                return
            }
            exportError = nil
            let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            MacSavePanel.save(data, suggestedName: "meow-tunnel-\(stamp).log", contentType: .log)
        }
    }

    private func extensionStatus(_ state: SystemExtensionInstaller.State) -> String {
        switch state {
        case .unknown: "Not installed yet"
        case .activating: "Installing…"
        case .needsApproval: "Waiting for approval in System Settings"
        case .activated: "Installed"
        case .needsRelocation: "Move meow to the Applications folder"
        case let .failed(message): message
        }
    }

    private func extensionTint(_ state: SystemExtensionInstaller.State) -> Color {
        switch state {
        case .activated: MacTheme.connected
        case .needsApproval, .activating: MacTheme.warning
        case .needsRelocation, .failed: MacTheme.danger
        case .unknown: MacTheme.secondaryInk
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("AppMark")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("meow")
                .font(.title2.weight(.semibold))
            Text("Version \(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(info("NSHumanReadableCopyright"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    private func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}
