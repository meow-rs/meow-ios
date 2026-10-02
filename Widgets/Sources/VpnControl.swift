import AppIntents
import SwiftUI
import WidgetKit

/// Control Center (and Lock Screen / Action button) switch for the VPN —
/// the same `ToggleTunnelIntent` the Home Screen widgets' switch runs.
struct VpnControl: ControlWidget {
    static let kind = "com.tangzixiang.meow.control.vpn"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle("widget.toggle.label", isOn: isOn, action: ToggleTunnelIntent()) { isOn in
                Label(
                    isOn ? "widget.control.on" : "widget.control.off",
                    systemImage: isOn ? "checkmark.shield.fill" : "shield.slash",
                )
            }
            .tint(Color("Connected"))
        }
        .displayName("widget.control.name")
        .description("widget.tunnel.description")
    }

    /// On while the tunnel is up or on its way up, matching the widgets'
    /// switch, so it doesn't flick back off between the tap and connecting.
    struct Provider: ControlValueProvider {
        let previewValue = false

        func currentValue() async throws -> Bool {
            await WidgetTunnel.status().stage.isActive
        }
    }
}
