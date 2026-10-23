import AppKit
import MeowModels
import SwiftUI

/// The status item: an outline paw while disconnected, a filled one while
/// connected, breathing while it connects, and a red badge after a tunnel
/// error. Optionally followed by the live up/down rate.
///
/// A `MenuBarExtra` label ignores most view modifiers, so every state is
/// drawn into one `NSImage` up front.
struct MenuBarLabel: View {
    let controller: MacController
    let ipcBridge: AppIPCBridge

    /// Opacity of the breathing paw while connecting.
    @State private var breath: CGFloat = 1

    var body: some View {
        Image(nsImage: MenuBarGlyph.image(
            style: style,
            alpha: style == .connecting ? breath : 1,
            rates: rates,
        ))
        .accessibilityLabel("meow, \(MacTheme.stageTitle(controller.stage))")
        .task(id: style) {
            guard style == .connecting else {
                breath = 1
                return
            }
            // 40 – 100 % over a 1.6 s cycle.
            let start = Date.now
            while !Task.isCancelled {
                let phase = Date.now.timeIntervalSince(start) / 1.6 * 2 * .pi
                breath = 0.7 + 0.3 * CGFloat(cos(phase))
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private var style: MenuBarGlyph.Style {
        switch controller.stage {
        case .connected: .connected
        case .preparing, .connecting, .stopping: .connecting
        case .error: .error
        case .idle, .stopped: controller.appModel.vpnManager.lastError == nil ? .disconnected : .error
        }
    }

    private var rates: (up: Int64, down: Int64)? {
        guard controller.showsSpeedInMenuBar, controller.isConnected else { return nil }
        let traffic = ipcBridge.currentTraffic
        return (traffic.uploadRate, traffic.downloadRate)
    }
}

@MainActor
enum MenuBarGlyph {
    enum Style: Hashable {
        case disconnected
        case connecting
        case connected
        case error
    }

    private static let height: CGFloat = 22
    private static let rateFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    /// Fixed so the status item doesn't jitter as the digits change.
    private static let rateWidth = ceil(("↓ 888.8 MB/s" as NSString).size(withAttributes: [.font: rateFont]).width)

    static func image(style: Style, alpha: CGFloat, rates: (up: Int64, down: Int64)?) -> NSImage {
        let paw = symbol(filled: style == .connected)
        let pawSize = paw.size
        let gap: CGFloat = rates == nil ? 0 : 4
        let width = ceil(pawSize.width) + (rates == nil ? 0 : gap + rateWidth) + (style == .error ? 3 : 0)
        let size = NSSize(width: width, height: height)
        let pawRect = NSRect(
            x: 0,
            y: ((height - pawSize.height) / 2).rounded(),
            width: pawSize.width,
            height: pawSize.height,
        )

        let image = NSImage(size: size, flipped: false) { _ in
            paw.draw(in: pawRect, from: .zero, operation: .sourceOver, fraction: alpha)
            if style == .error {
                // A colored badge rules out a template image, so tint the paw
                // by hand for whichever menu bar appearance draws it.
                NSColor.labelColor.set()
                pawRect.fill(using: .sourceAtop)
                let dot = NSRect(x: pawRect.maxX - 4, y: pawRect.maxY - 5, width: 7, height: 7)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            if let rates {
                let attributes: [NSAttributedString.Key: Any] = [.font: rateFont, .foregroundColor: NSColor.black]
                let x = pawRect.maxX + gap
                let up = "↑ " + MacFormat.rate(rates.up) as NSString
                let down = "↓ " + MacFormat.rate(rates.down) as NSString
                up.draw(at: NSPoint(x: x, y: 11), withAttributes: attributes)
                down.draw(at: NSPoint(x: x, y: 0.5), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = style != .error
        return image
    }

    private static func symbol(filled: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let name = filled ? "pawprint.fill" : "pawprint"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        return image ?? NSImage(size: NSSize(width: 16, height: 16))
    }
}
