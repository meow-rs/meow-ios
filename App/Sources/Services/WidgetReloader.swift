import MeowModels

// The tvOS app compiles Services/ too, and tvOS has no WidgetKit.
#if canImport(WidgetKit)
    import WidgetKit
#endif

/// Asks WidgetKit to re-run the Home Screen widgets' timelines when state
/// they display changes inside the app. Reloads requested while the app is
/// in the foreground don't count against the widgets' daily refresh budget,
/// so the widgets stay in sync without leaning on their periodic timeline.
@MainActor
enum WidgetReloader {
    /// Reload once the tunnel settles. Transitional stages (`connecting`,
    /// `stopping`) are skipped: each flip would spend a reload on a state
    /// the widget shows for well under a second.
    static func stageDidChange(_ stage: VpnStage) {
        switch stage {
        case .connected:
            reloadAll()
        case .stopped, .idle, .error:
            // The engine is gone and the next one starts in the profile's
            // mode, so the last-known mode no longer describes anything.
            RouteMode.clearLastKnown(in: AppGroup.defaults)
            reloadAll()
        case .preparing, .connecting, .stopping:
            break
        }
    }

    /// Record the engine's route mode for the widgets (their fallback when
    /// the engine doesn't answer them) and reload them if it changed.
    static func routeModeDidChange(_ mode: RouteMode) {
        guard RouteMode.lastKnown(in: AppGroup.defaults) != mode else { return }
        RouteMode.setLastKnown(mode, in: AppGroup.defaults)
        reloadAll()
    }

    private static func reloadAll() {
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
