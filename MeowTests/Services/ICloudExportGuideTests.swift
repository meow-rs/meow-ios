import Foundation
@testable import meow_ios
import Testing

/// When the iCloud Drive export guide presents itself: once per install, and
/// never uninvited during a UI-test launch.
@Suite("ICloudExportGuide", .tags(.icloudRelay))
struct ICloudExportGuideTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ICloudExportGuideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test
    func `auto-presents until marked seen`() {
        let defaults = freshDefaults()
        #expect(ICloudExportGuide.shouldAutoPresent(defaults: defaults, arguments: []))
        ICloudExportGuide.markSeen(defaults: defaults)
        #expect(!ICloudExportGuide.shouldAutoPresent(defaults: defaults, arguments: []))
    }

    @Test
    func `UI-test launches skip it unless asked`() {
        let defaults = freshDefaults()
        #expect(!ICloudExportGuide.shouldAutoPresent(defaults: defaults, arguments: ["-UITests"]))
        #expect(ICloudExportGuide.shouldAutoPresent(
            defaults: defaults,
            arguments: ["-UITests", "-ShowICloudExportGuide"],
        ))
    }
}
