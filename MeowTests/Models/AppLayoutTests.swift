import CoreGraphics
@testable import meow_ios
import Testing

@Suite("AppLayout")
struct AppLayoutTests {
    @Test
    func `compact and unknown widths get a single column`() {
        #expect(AppLayout.columnCount(for: .compact) == 1)
        #expect(AppLayout.columnCount(for: nil) == 1)
    }

    @Test
    func `regular width gets an even two-column grid`() {
        // Even counts divide cleanly on either side of the iPhone Duo fold.
        #expect(AppLayout.columnCount(for: .regular) == 2)
    }

    @Test
    func `gutter follows the fold divider inside the middle band`() {
        let frame = CGRect(x: 100, y: 0, width: 800, height: 600)
        // Divider at 60% of the container: honoured.
        #expect(AppLayout.splitFraction(containerFrame: frame, dividerX: 580) == 0.6)
        // Divider outside the 35–65% band (e.g. an iPad sidebar offset): equal columns.
        #expect(AppLayout.splitFraction(containerFrame: frame, dividerX: 200) == 0.5)
        // No divider (iPad, iPhone): equal columns.
        #expect(AppLayout.splitFraction(containerFrame: frame, dividerX: nil) == 0.5)
        #expect(AppLayout.splitFraction(containerFrame: .zero, dividerX: 10) == 0.5)
    }

    @Test
    func `column widths honour spacing and the split fraction`() {
        #expect(AppLayout.columnWidths(total: 300, columns: 1, spacing: 10, splitFraction: 0.5) == [300])
        #expect(AppLayout.columnWidths(total: 310, columns: 2, spacing: 10, splitFraction: 0.5) == [150, 150])
        #expect(AppLayout.columnWidths(total: 310, columns: 2, spacing: 10, splitFraction: 0.6) == [180, 120])
        #expect(AppLayout.columnWidths(total: 320, columns: 3, spacing: 10, splitFraction: 0.6) == [100, 100, 100])
    }
}
