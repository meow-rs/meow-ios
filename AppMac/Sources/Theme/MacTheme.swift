import AppKit
import MeowModels
import SwiftUI

/// Palette of the macOS design: a pale-blue canvas, white cards with a hairline
/// blue border, and the iOS accent. Every color resolves per appearance.
enum MacTheme {
    static let ink = Color(light: 0x13293D, dark: 0xE6EEF5)
    static let secondaryInk = Color(light: 0x5B6B7A, dark: 0x9AA9B7)
    static let canvas = Color(light: 0xF1F7FC, dark: 0x10171E)
    static let card = Color(light: 0xFFFFFF, dark: 0x19232D)
    static let cardBorder = Color(light: 0xD3E5F3, dark: 0x2A3846)
    static let selectionFill = Color(light: 0xDCEBF8, dark: 0x1D3A55)
    static let connected = Color(light: 0x1E9E4A, dark: 0x34C062)
    static let danger = Color(light: 0xD33A36, dark: 0xFF5F57)
    static let warning = Color(light: 0xB86E00, dark: 0xF2A93B)
    static let download = Color(light: 0x0A72C9, dark: 0x3EA6FF)
    static let upload = Color(light: 0xC46A00, dark: 0xF29A38)

    static func stageColor(_ stage: VpnStage) -> Color {
        switch stage {
        case .connected: connected
        case .preparing, .connecting, .stopping: warning
        case .error: danger
        case .idle, .stopped: Color(light: 0x9AA6B2, dark: 0x6B7783)
        }
    }

    static func stageTitle(_ stage: VpnStage) -> String {
        switch stage {
        case .connected: "Connected"
        case .preparing: "Preparing…"
        case .connecting: "Connecting…"
        case .stopping: "Disconnecting…"
        case .error: "Error"
        case .idle, .stopped: "Disconnected"
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1,
        )
    }
}

// MARK: - Cards

struct MacCard: ViewModifier {
    var isSelected = false
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(MacTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : MacTheme.cardBorder, lineWidth: isSelected ? 2 : 1)
            }
    }
}

extension View {
    func macCard(isSelected: Bool = false, padding: CGFloat = 16) -> some View {
        modifier(MacCard(isSelected: isSelected, padding: padding))
    }

    /// The canvas every detail page sits on.
    func macPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(MacTheme.canvas)
    }
}

/// Small-caps section label ("PROFILES", "ENGINE", "INSPECTOR").
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(MacTheme.secondaryInk)
    }
}

/// Label/value pair in the big-number style of the engine and traffic cards.
struct MetricView: View {
    let title: String
    let value: String
    var valueSize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(MacTheme.secondaryInk)
            Text(value)
                .font(.system(size: valueSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(MacTheme.ink)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Delay badge

/// Latency pill: green under 200 ms, amber under 500 ms, red beyond or on a
/// failed probe (the engine records a failure as 0). Same thresholds as iOS.
struct DelayBadge: View {
    let delay: Int?
    var isDirect = false

    var body: some View {
        if let label {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tint.opacity(0.14), in: Capsule())
        }
    }

    private var label: String? {
        if isDirect {
            return "direct"
        }
        guard let delay else { return nil }
        return delay > 0 ? "\(delay) ms" : "timeout"
    }

    private var tint: Color {
        if isDirect {
            return MacTheme.secondaryInk
        }
        guard let delay, delay > 0 else { return MacTheme.danger }
        if delay < 200 {
            return MacTheme.connected
        }
        if delay < 500 {
            return MacTheme.warning
        }
        return MacTheme.danger
    }

    static func isDirectType(_ type: String) -> Bool {
        ["direct", "reject", "rejectdrop", "pass"].contains(type.lowercased())
    }
}

// MARK: - Status glyph

/// The app mark with a stage dot in its corner, as in the sidebar card, the
/// engine card and the popover header.
struct StatusGlyph: View {
    let stage: VpnStage
    var size: CGFloat = 36

    var body: some View {
        Image(stage == .connected ? "AppMarkConnected" : "AppMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(MacTheme.stageColor(stage))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().strokeBorder(MacTheme.card, lineWidth: max(1.5, size * 0.05)))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
            .accessibilityLabel(MacTheme.stageTitle(stage))
    }
}

/// Empty state for engine pages while the tunnel is down.
struct EngineOfflineView: View {
    var message = "Connect to see live data from the engine."

    var body: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "pawprint")
        } description: {
            Text(message)
        }
    }
}
