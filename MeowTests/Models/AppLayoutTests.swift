@testable import meow_ios
import SwiftUI
import Testing

@Suite("AppLayout")
struct AppLayoutTests {
    @Test
    func `compact and unknown widths get a single column`() {
        #expect(AppLayout.gridColumns(for: .compact).count == 1)
        #expect(AppLayout.gridColumns(for: nil).count == 1)
    }

    @Test
    func `regular width gets an even two-column grid`() {
        // Even counts divide cleanly on either side of the iPhone Duo fold.
        #expect(AppLayout.gridColumns(for: .regular).count == 2)
    }
}
