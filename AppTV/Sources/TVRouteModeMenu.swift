import MeowModels
import SwiftUI

/// The running engine's route mode — Rule, All or Direct — as one row under
/// the connect button: the mode on its trailing edge, and a menu to switch it.
///
/// A menu, not the segmented picker iOS has (`EngineOverviewSection`): on
/// tvOS a segment is selected by focus moving onto it, so reaching past the
/// control with the remote would reroute the traffic on the way. A menu
/// switches on a click.
///
/// As on iOS the mode belongs to the running engine. Every engine start — a
/// connect, the reload a profile switch sends — begins in the profile's
/// `mode:` again, and this row then shows that one.
struct TVRouteModeMenu: View {
    @Environment(AppModel.self) private var appModel
    @Environment(VpnManager.self) private var vpnManager
    @Environment(MeowAPI.self) private var meowAPI
    @Environment(\.scenePhase) private var scenePhase

    /// What the engine last said it runs in. `nil` with no engine to ask,
    /// and until a started one has answered.
    @State private var mode: RouteMode?

    var body: some View {
        Menu {
            Picker("home.routeMode.title", selection: selection) {
                ForEach(RouteMode.allCases) { mode in
                    Text(mode.title).tag(RouteMode?.some(mode))
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text("home.routeMode.title")
                Spacer(minLength: 0)
                if let mode {
                    Text(mode.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // Only a running engine has a mode to switch. Disabled, the row
        // can't take focus, which the connect button above it always can.
        .disabled(!isConnected)
        .accessibilityIdentifier("tv.routeMode")
        .task(id: vpnManager.stage) {
            await refresh()
        }
        // An engine restarted in place, or reloaded for another profile, is
        // back in that profile's mode while the stage stays `.connected`.
        .task(id: appModel.replayGeneration) {
            await refresh()
        }
        // The tunnel outlives the app: catch up on what the engine did while
        // this was in the background.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refresh() }
        }
    }

    private var isConnected: Bool {
        vpnManager.stage == .connected
    }

    /// Reads the row's mode and sends a pick to the engine, so that a
    /// `refresh()` writing `mode` doesn't send it back.
    private var selection: Binding<RouteMode?> {
        Binding(
            get: { mode },
            set: { picked in
                guard let picked, picked != mode else { return }
                let previous = mode
                mode = picked
                Task { await apply(picked, replacing: previous) }
            },
        )
    }

    private func refresh() async {
        guard isConnected else {
            mode = nil
            return
        }
        do {
            mode = try await RouteMode(wire: meowAPI.getConfigs().mode)
        } catch {
            // Keeps what the row shows; the next refresh reads it again.
        }
    }

    private func apply(_ picked: RouteMode, replacing previous: RouteMode?) async {
        do {
            try await meowAPI.setMode(picked.wire)
        } catch {
            // The engine didn't take it: back to the mode it ran in, unless
            // a later pick has replaced this one, then ask the engine.
            if mode == picked {
                mode = previous
            }
            await refresh()
        }
    }
}

private extension RouteMode {
    /// The names iOS gives the modes (`RouteMode.label` in
    /// `EngineOverviewSection`, which this target doesn't compile).
    var title: LocalizedStringKey {
        switch self {
        case .rule: "home.routeMode.rule"
        case .all: "home.routeMode.all"
        case .direct: "home.routeMode.direct"
        }
    }
}
