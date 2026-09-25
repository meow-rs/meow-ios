import Foundation

/// meow's outbound routing mode — the `mode` the running engine reports on
/// `GET /configs` and accepts on `PATCH /configs`. Shared by the in-app
/// picker and the Home Screen widgets so both speak the same wire values.
public enum RouteMode: String, CaseIterable, Identifiable, Sendable {
    case rule
    case all
    case direct

    public var id: String {
        rawValue
    }

    /// Wire value sent to meow's `PATCH /configs`. Meow calls the
    /// "send everything through proxies" mode `global`; the UI uses `All`
    /// to match how users describe it in this app.
    public var wire: String {
        switch self {
        case .rule: "rule"
        case .all: "global"
        case .direct: "direct"
        }
    }

    public init?(wire: String) {
        switch wire.lowercased() {
        case "rule": self = .rule
        case "global": self = .all
        case "direct": self = .direct
        default: return nil
        }
    }
}

public extension RouteMode {
    /// The top-level `mode:` of a Clash YAML config — the mode the engine
    /// starts in. `.rule` (the engine's default) when the key is missing or
    /// unrecognised.
    ///
    /// A line scan rather than a YAML parse: profiles can carry thousands of
    /// rules, and the widget extension that reads this needs one scalar on a
    /// tight memory budget.
    static func configured(inYAML yaml: String) -> RouteMode {
        var mode = RouteMode.rule
        yaml.enumerateLines { line, stop in
            // Profiles saved by some editors start with a byte-order mark.
            var line = Substring(line)
            if line.unicodeScalars.first == "\u{FEFF}" {
                line = Substring(line.unicodeScalars.dropFirst())
            }
            guard line.hasPrefix("mode:") else { return }
            var value = line.dropFirst("mode:".count)
            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment]
            }
            let wire = value.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            mode = RouteMode(wire: wire) ?? .rule
            stop = true
        }
        return mode
    }

    /// The mode last seen on (or set on) the running engine. Only describes
    /// the current tunnel session — every engine start resets to the
    /// config's `mode:` and nothing replays this — so it's cleared whenever
    /// the tunnel stops. A fallback for when the engine can't be asked, and
    /// lets the app skip redundant widget reloads.
    static func lastKnown(in defaults: UserDefaults) -> RouteMode? {
        defaults.string(forKey: PreferenceKey.lastRouteMode).flatMap(RouteMode.init(rawValue:))
    }

    static func setLastKnown(_ mode: RouteMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: PreferenceKey.lastRouteMode)
    }

    static func clearLastKnown(in defaults: UserDefaults) {
        defaults.removeObject(forKey: PreferenceKey.lastRouteMode)
    }
}
