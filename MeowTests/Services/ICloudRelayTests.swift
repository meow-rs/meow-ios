import Foundation
@testable import meow_ios
import Testing

/// The pure half of the iCloud Drive → Apple TV relay: which files count,
/// how they map to CloudKit records, and what a sync pass must upload or
/// delete. The CloudKit calls themselves need a signed build and an iCloud
/// account, so they aren't unit-tested.
@Suite("ICloudRelay", .tags(.icloudRelay))
struct ICloudRelayTests {
    // MARK: - isRelayable

    @Test(arguments: ["home.yaml", "Office.YML", "a b.yaml", "config.yml"])
    func `yaml and yml files are relayable`(name: String) {
        #expect(ICloudRelay.isRelayable(fileName: name))
    }

    @Test(arguments: [".home.yaml.icloud", ".hidden.yaml", "notes.txt", "config.yaml.bak", "sub/dir.yaml", "yaml"])
    func `placeholders, hidden, nested and other files are not`(name: String) {
        #expect(!ICloudRelay.isRelayable(fileName: name))
    }

    // MARK: - recordName / profileName

    @Test
    func `record name is stable, ASCII and case-folded`() {
        let name = ICloudRelay.recordName(for: "我的配置.yaml")
        #expect(name == ICloudRelay.recordName(for: "我的配置.yaml"))
        // Hoisted: a key path inside `#expect` doesn't type-check (the macro
        // treats the rethrowing call as throwing), and swiftformat rewrites a
        // closure back into the key path.
        let isASCII = name.allSatisfy(\.isASCII)
        #expect(isASCII)
        #expect(name.hasPrefix("file-"))
        #expect(ICloudRelay.recordName(for: "Home.yaml") == ICloudRelay.recordName(for: "home.YAML"))
        #expect(ICloudRelay.recordName(for: "home.yaml") != ICloudRelay.recordName(for: "work.yaml"))
    }

    @Test
    func `profile name drops the extension`() {
        #expect(ICloudRelay.profileName(for: "Home Lab.yaml") == "Home Lab")
        #expect(ICloudRelay.profileName(for: "a.b.yml") == "a.b")
    }

    // MARK: - ICloudRelayPlan

    @Test
    func `new and changed files upload, unchanged ones don't`() {
        let plan = ICloudRelayPlan.make(
            current: ["new.yaml": "h1", "changed.yaml": "h2b", "same.yaml": "h3"],
            synced: ["changed.yaml": "h2a", "same.yaml": "h3"],
        )
        #expect(plan.uploads == ["changed.yaml", "new.yaml"])
        #expect(plan.deletions.isEmpty)
    }

    @Test
    func `a file gone from the folder is deleted from the zone`() {
        let plan = ICloudRelayPlan.make(current: [:], synced: ["gone.yaml": "h"])
        #expect(plan.uploads.isEmpty)
        #expect(plan.deletions == ["gone.yaml"])
    }

    @Test
    func `a file still downloading is neither uploaded nor deleted`() {
        let plan = ICloudRelayPlan.make(current: [:], pending: ["later.yaml"], synced: ["later.yaml": "h"])
        #expect(plan.isEmpty)
    }

    @Test
    func `nothing to do when the zone already matches`() {
        #expect(ICloudRelayPlan.make(current: ["a.yaml": "h"], synced: ["a.yaml": "h"]).isEmpty)
    }
}

extension Tag {
    @Tag static var icloudRelay: Self
}
