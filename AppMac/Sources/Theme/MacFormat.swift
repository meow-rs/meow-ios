import AppKit
import Foundation
import UniformTypeIdentifiers

enum MacFormat {
    /// "96 B", "840 KB", "18.4 MB", "3.8 GB" (binary units, as the engine
    /// counts them).
    static func bytes(_ value: Int64) -> String {
        let units = ["KB", "MB", "GB", "TB"]
        var amount = Double(max(value, 0))
        guard amount >= 1024 else { return "\(Int(amount)) B" }
        var index = -1
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        if index == 0 || amount >= 100 {
            return "\(Int(amount.rounded())) \(units[index])"
        }
        return String(format: "%.1f %@", amount, units[index])
    }

    static func rate(_ bytesPerSecond: Int64) -> String {
        "\(bytes(bytesPerSecond))/s"
    }

    /// "2:14:06".
    static func uptime(from start: Date, to now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// "just now", "25 min ago", "3 hr ago", "2 days ago".
    static func relative(_ date: Date, to now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) hr ago"
        default:
            let days = seconds / 86400
            return days == 1 ? "yesterday" : "\(days) days ago"
        }
    }

    static let clock: Date.FormatStyle = .dateTime
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
}

enum MacPasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Unsandboxed app, so a plain save panel is all an export needs.
@MainActor
enum MacSavePanel {
    static func save(_ data: Data, suggestedName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
