import SwiftUI

/// Size-class-driven layout constants shared by every screen.
///
/// iPad and the iPhone Duo inner display report a regular horizontal size
/// class; iPhone, the Duo outer display, and iPad Split View report compact.
/// Apple's iPhone Duo guidance: drive layout by size class, never by
/// orientation or idiom, and let the existing layout expand rather than
/// swapping to a different one — a fold/unfold is a live resize of the same
/// scene, so pushed screens, sheets, and scroll positions must survive it.
enum AppLayout {
    /// Widest a form or menu column grows at regular width before it is
    /// centred; wider rows put labels and controls too far apart to scan.
    static let readableWidth: CGFloat = 720

    /// Card-grid columns for a size class: one at compact width, two at
    /// regular width. Even counts divide cleanly on either side of the
    /// iPhone Duo fold.
    static func gridColumns(for sizeClass: UserInterfaceSizeClass?, spacing: CGFloat = 12) -> [GridItem] {
        let count = sizeClass == .regular ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
    }
}

/// Caps content at `AppLayout.readableWidth` and centres it at regular
/// width; a no-op at compact width. Only the frame values change with the
/// size class, so the wrapped view keeps its identity (and state) across
/// resizes.
private struct ReadableColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: sizeClass == .regular ? AppLayout.readableWidth : .infinity)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Centres a form, list, or menu at a readable width on wide displays.
    func readableColumn() -> some View {
        modifier(ReadableColumn())
    }
}
