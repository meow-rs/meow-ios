import AppIntents
import SwiftUI
import WidgetKit

/// Control Center (and Lock Screen / Action button) switch for the VPN —
/// the same `ToggleTunnelIntent` the Home Screen widgets' switch runs.
struct VpnControl: ControlWidget {
    static let kind = "com.tangzixiang.meow.control.vpn"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { value in
            ControlWidgetToggle("widget.toggle.label", isOn: value.isOn, action: ToggleTunnelIntent()) { isOn in
                Label(value.label(isOn: isOn), systemImage: isOn ? "checkmark.shield.fill" : "shield.slash")
            }
            .tint(Color("Connected"))
        }
        .displayName("widget.control.name")
        .description("widget.tunnel.description")
    }

    struct Value {
        /// On while the tunnel is up or on its way up, matching the widgets'
        /// switch, so it doesn't flick back off between the tap and
        /// connecting.
        let isOn: Bool
        /// False until a profile is chosen. The toggle stays tappable (a
        /// control can't hide itself), so say "Set Up" instead of "Off";
        /// a tap then fails with `WidgetTunnel.Failure.notConfigured`.
        let isConfigured: Bool

        func label(isOn: Bool) -> LocalizedStringKey {
            if !isConfigured, !isOn {
                return "widget.control.setup"
            }
            return isOn ? "widget.control.on" : "widget.control.off"
        }
    }

    struct Provider: ControlValueProvider {
        let previewValue = Value(isOn: false, isConfigured: true)

        func currentValue() async throws -> Value {
            let status = await WidgetTunnel.status()
            return Value(isOn: status.stage.isActive, isConfigured: status.isConfigured)
        }
    }
}
