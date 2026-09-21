import SwiftUI
import UIKit

/// Size-class-driven layout helpers shared by every screen.
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

    /// How a size-class flip reflows: long enough to read as a fold, short
    /// enough not to lag the display switch.
    static let reflowAnimation: Animation = .smooth(duration: 0.4)

    /// One column at compact width, two at regular width. Even counts divide
    /// cleanly on either side of the iPhone Duo fold.
    static func columnCount(for sizeClass: UserInterfaceSizeClass?) -> Int {
        sizeClass == .regular ? 2 : 1
    }

    /// Where a two-column gutter sits, as a fraction of the container width.
    /// Follows the fold divider when it crosses the container's middle band;
    /// otherwise the columns are equal.
    static func splitFraction(containerFrame: CGRect, dividerX: CGFloat?) -> CGFloat {
        guard let dividerX, containerFrame.width > 0 else { return 0.5 }
        let fraction = (dividerX - containerFrame.minX) / containerFrame.width
        return (0.35 ... 0.65).contains(fraction) ? fraction : 0.5
    }

    /// Column widths for `columns` columns in `total` points with `spacing`
    /// between them. Two columns honour `splitFraction`; any other count is
    /// equal-width.
    static func columnWidths(total: CGFloat, columns: Int, spacing: CGFloat, splitFraction: CGFloat) -> [CGFloat] {
        let count = max(columns, 1)
        let inner = max(total - spacing * CGFloat(count - 1), 0)
        if count == 2 {
            return [inner * splitFraction, inner * (1 - splitFraction)]
        }
        return Array(repeating: inner / CGFloat(count), count: count)
    }
}

extension EnvironmentValues {
    /// Global x of the iPhone Duo fold divider when the inner display is in
    /// use, otherwise nil. Set once at the root by `FoldDividerProvider`.
    @Entry var foldDividerX: CGFloat?
}

/// Publishes `foldDividerX` for the subtree. The divider runs through the
/// horizontal centre of the window on the Duo inner display.
///
/// Detection is geometric for now: an iPhone-idiom window that is regular in
/// both dimensions only exists on the Duo inner display. Replace with
/// `UIView.reservedRegions(kind: .division)` once CI builds with the iOS 27.1
/// SDK — that API reports the real divider frame and whether it is active.
private struct FoldDividerProvider: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var dividerX: CGFloat?

    func body(content: Content) -> some View {
        let isInnerDisplay = horizontalSizeClass == .regular
            && verticalSizeClass == .regular
            && UIDevice.current.userInterfaceIdiom == .phone
        content
            .onGeometryChange(for: CGFloat?.self) { proxy in
                guard isInnerDisplay else { return nil }
                let frame = proxy.frame(in: .global)
                let insets = proxy.safeAreaInsets
                let windowMinX = frame.minX - insets.leading
                let windowWidth = frame.width + insets.leading + insets.trailing
                return windowMinX + windowWidth / 2
            } action: { dividerX = $0 }
            .environment(\.foldDividerX, dividerX)
    }
}

extension View {
    /// Makes the fold divider position available to `AdaptiveGrid`s below.
    func providesFoldDivider() -> some View {
        modifier(FoldDividerProvider())
    }
}

/// Row-major columns with top-aligned cells. Non-lazy on purpose: a lazy grid
/// inside a `List` row dropped its first cell when the column count changed
/// on a fold, and a `Layout` animates its placements when the count flips.
struct AdaptiveColumns: Layout {
    var columns: Int
    var spacing: CGFloat
    var splitFraction: CGFloat
    /// When the parent proposes a definite height, a single row stretches to
    /// fill it — for top-level containers holding a `List` or `ScrollView`.
    var fillsHeight: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let rows = rowHeights(width: width, proposal: proposal, subviews: subviews)
        if fillsHeight, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        let height = rows.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let widths = AppLayout.columnWidths(
            total: bounds.width, columns: columns, spacing: spacing, splitFraction: splitFraction,
        )
        var rows = rowHeights(width: bounds.width, proposal: proposal, subviews: subviews)
        if fillsHeight, rows.count == 1 {
            rows = [bounds.height]
        }
        var y = bounds.minY
        for (rowIndex, rowHeight) in rows.enumerated() {
            var x = bounds.minX
            for column in 0 ..< widths.count {
                let index = rowIndex * widths.count + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: widths[column], height: fillsHeight ? rowHeight : nil),
                )
                x += widths[column] + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func rowHeights(width: CGFloat, proposal: ProposedViewSize, subviews: Subviews) -> [CGFloat] {
        let widths = AppLayout.columnWidths(
            total: width, columns: columns, spacing: spacing, splitFraction: splitFraction,
        )
        var rows: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            var rowHeight: CGFloat = 0
            for column in 0 ..< widths.count where index < subviews.count {
                let size = subviews[index].sizeThatFits(
                    ProposedViewSize(width: widths[column], height: fillsHeight ? proposal.height : nil),
                )
                rowHeight = max(rowHeight, size.height)
                index += 1
            }
            rows.append(rowHeight)
        }
        return rows
    }
}

/// `AdaptiveColumns` driven by the size class: one column at compact width,
/// two at regular width with the gutter on the fold divider when there is
/// one. The container never changes, only its parameters, so cell state
/// survives a fold, and the reflow animates.
struct AdaptiveGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.foldDividerX) private var foldDividerX
    @State private var frame: CGRect = .zero

    var spacing: CGFloat = 12
    var fillsHeight = false
    @ViewBuilder var content: Content

    var body: some View {
        let columns = AppLayout.columnCount(for: sizeClass)
        AdaptiveColumns(
            columns: columns,
            spacing: spacing,
            splitFraction: AppLayout.splitFraction(containerFrame: frame, dividerX: foldDividerX),
            fillsHeight: fillsHeight,
        ) {
            content
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .animation(AppLayout.reflowAnimation, value: columns)
    }
}

/// Caps content at `AppLayout.readableWidth` and centres it at regular
/// width; a no-op at compact width. Only the frame values change with the
/// size class, so the wrapped view keeps its identity (and state) across
/// resizes, and the width change animates with the fold.
private struct ReadableColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: sizeClass == .regular ? AppLayout.readableWidth : .infinity)
            .frame(maxWidth: .infinity)
            .animation(AppLayout.reflowAnimation, value: sizeClass)
    }
}

extension View {
    /// Centres a form, list, or menu at a readable width on wide displays.
    func readableColumn() -> some View {
        modifier(ReadableColumn())
    }
}
