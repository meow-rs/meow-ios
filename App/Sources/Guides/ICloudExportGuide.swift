import SwiftUI

/// The one-time walkthrough for sending a config to the Apple TV: swipe a
/// profile right, tap iCloud Drive, pick it on the TV. Shared by both apps —
/// the iPhone shows it the first time Configs has a profile to swipe, the TV
/// the first time its iCloud Drive screen opens. Either can replay it (iOS
/// from Settings, tvOS from the iCloud Drive screen, which has no Settings).
enum ICloudExportGuide {
    /// Set once the guide has been dismissed; replays don't touch it.
    static let seenKey = "guide.icloudExport.seen"

    /// Whether to present the guide unprompted. UI-test launches skip it so
    /// an unexpected sheet can't swallow the taps a test makes, unless the
    /// test asks for it with `-ShowICloudExportGuide`.
    static func shouldAutoPresent(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
    ) -> Bool {
        if arguments.contains("-UITests") {
            return arguments.contains("-ShowICloudExportGuide")
        }
        return !defaults.bool(forKey: seenKey)
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}

/// The guide itself: a looping demo of the swipe above a numbered list of
/// the three steps, the current one highlighted in step with the demo.
struct ICloudExportGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: GuidePhase = .rest

    #if os(tvOS)
        private let unit: CGFloat = 2
    #else
        private let unit: CGFloat = 1
    #endif

    var body: some View {
        VStack(spacing: 28 * unit) {
            VStack(spacing: 8 * unit) {
                Text("guide.icloudExport.title")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("guide.icloudExport.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            SwipeDemo(phase: phase, unit: unit)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14 * unit) {
                stepRow(1, "guide.icloudExport.step1", isCurrent: phase.step == 1)
                stepRow(2, "guide.icloudExport.step2", isCurrent: phase.step == 2)
                stepRow(3, "guide.icloudExport.step3", isCurrent: phase.step == 3)
            }
            .frame(maxWidth: 360 * unit, alignment: .leading)

            Button {
                dismiss()
            } label: {
                Text("guide.icloudExport.done")
                    .frame(maxWidth: 280 * unit)
            }
            .buttonStyle(.borderedProminent)
            #if !os(tvOS)
                .controlSize(.large)
            #endif
                .accessibilityIdentifier("guide.icloudExport.done")
        }
        .padding(24 * unit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loop() }
    }

    private func stepRow(_ number: Int, _ text: LocalizedStringKey, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * unit) {
            Text(verbatim: "\(number)")
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                .frame(width: 26 * unit, height: 26 * unit)
                .background(Circle().fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18)))
                .accessibilityHidden(true)
            Text(text)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Steps the demo through its phases until the view goes away. With
    /// Reduce Motion on it holds the revealed-actions frame instead, which
    /// shows everything the steps describe without movement.
    private func loop() async {
        guard !reduceMotion else {
            phase = .tap
            return
        }
        while !Task.isCancelled {
            for next in GuidePhase.allCases {
                withAnimation(next.animation) { phase = next }
                try? await Task.sleep(for: next.hold)
                if Task.isCancelled { return }
            }
        }
    }
}

enum GuidePhase: CaseIterable {
    /// Row at rest, finger on it.
    case rest
    /// Finger drags the row right, revealing the swipe actions.
    case swipe
    /// Finger taps iCloud Drive.
    case tap
    /// The config travels iPhone → iCloud → Apple TV.
    case relay

    var step: Int {
        switch self {
        case .rest, .swipe: 1
        case .tap: 2
        case .relay: 3
        }
    }

    var hold: Duration {
        switch self {
        case .rest: .seconds(0.9)
        case .swipe: .seconds(1.3)
        case .tap: .seconds(1.3)
        case .relay: .seconds(2.4)
        }
    }

    var animation: Animation {
        switch self {
        case .rest: .easeInOut(duration: 0.35)
        case .swipe: .spring(duration: 0.7, bounce: 0.15)
        case .tap: .easeInOut(duration: 0.45)
        case .relay: .easeInOut(duration: 0.6)
        }
    }
}

/// A stylised profile row with the three leading swipe actions beneath it,
/// and the iPhone → iCloud → Apple TV path underneath.
private struct SwipeDemo: View {
    let phase: GuidePhase
    let unit: CGFloat

    private var action: CGFloat {
        64 * unit
    }

    private var rowWidth: CGFloat {
        300 * unit
    }

    private var rowHeight: CGFloat {
        64 * unit
    }

    var body: some View {
        VStack(spacing: 22 * unit) {
            row
            relayPath
        }
    }

    private var isRevealed: Bool {
        phase != .rest
    }

    private var row: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                actionTile("arrow.clockwise", tint: .blue, highlighted: false)
                actionTile("square.and.pencil", tint: .accentColor, highlighted: false)
                actionTile("icloud.and.arrow.up", tint: .indigo, highlighted: phase == .tap || phase == .relay)
            }
            profileCard
                .offset(x: isRevealed ? action * 3 : 0)
        }
        .frame(width: rowWidth, height: rowHeight, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 14 * unit, style: .continuous))
        .overlay(alignment: .topLeading) { finger }
    }

    private var profileCard: some View {
        HStack(spacing: 12 * unit) {
            Image(systemName: "largecircle.fill.circle")
                .font(.system(size: 20 * unit))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6 * unit) {
                Capsule().fill(Color.primary.opacity(0.55))
                    .frame(width: 110 * unit, height: 9 * unit)
                Capsule().fill(Color.secondary.opacity(0.35))
                    .frame(width: 70 * unit, height: 7 * unit)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16 * unit)
        .frame(width: rowWidth, height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 14 * unit, style: .continuous)
                .fill(.background.secondary)
                .shadow(color: .black.opacity(0.15), radius: 4 * unit, x: -2 * unit),
        )
    }

    private func actionTile(_ systemImage: String, tint: Color, highlighted: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20 * unit, weight: .semibold))
            .foregroundStyle(.white)
            .scaleEffect(highlighted ? 1.2 : 1)
            .frame(width: action, height: rowHeight)
            .background(tint.brightness(highlighted ? 0.12 : 0))
    }

    /// The finger rides the card while it drags, then moves over the iCloud
    /// Drive tile and presses it; it lifts away while the config travels.
    private var finger: some View {
        let x: CGFloat = switch phase {
        case .rest: 40 * unit
        case .swipe: 40 * unit + action * 3
        case .tap, .relay: action * 2.5 - 12 * unit
        }
        return Image(systemName: "hand.point.up.left.fill")
            .font(.system(size: 34 * unit))
            .foregroundStyle(.white, .black.opacity(0.75))
            .shadow(color: .black.opacity(0.3), radius: 3 * unit)
            .scaleEffect(phase == .tap ? 0.85 : 1)
            .offset(x: x, y: rowHeight * 0.45)
            .opacity(phase == .relay ? 0 : 1)
    }

    private var relayPath: some View {
        HStack(spacing: 14 * unit) {
            device("iphone", lit: phase == .relay)
            arrow(lit: phase == .relay)
            device("icloud.fill", lit: phase == .relay)
            arrow(lit: phase == .relay)
            device("appletv.fill", lit: phase == .relay)
        }
        .font(.system(size: 26 * unit))
    }

    private func device(_ systemImage: String, lit: Bool) -> some View {
        Image(systemName: systemImage)
            .foregroundStyle(lit ? Color.accentColor : Color.secondary.opacity(0.5))
            .scaleEffect(lit ? 1.1 : 1)
            .frame(width: 44 * unit, height: 36 * unit)
    }

    private func arrow(lit: Bool) -> some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 16 * unit, weight: .semibold))
            .foregroundStyle(lit ? Color.accentColor : Color.secondary.opacity(0.35))
            .offset(x: lit ? 4 * unit : 0)
    }
}
