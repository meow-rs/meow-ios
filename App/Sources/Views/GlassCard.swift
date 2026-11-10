import SwiftUI

/// Container for major card surfaces, using the app icon's white, cyan, and
/// scarf-navy visual language without competing with the content.
/// Wrapper API is intentionally unchanged so the ~11 existing call sites
/// (Home, Traffic, Subscriptions, Providers, Rules, Connections) need no edits.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                AppTheme.panel,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1),
            )
            .shadow(color: AppTheme.navy.opacity(0.10), radius: 16, x: 0, y: 8)
    }
}
