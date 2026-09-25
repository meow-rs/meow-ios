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

    // MARK: - exportFileName

    @Test
    func `export file name appends yaml and round-trips to the profile name`() {
        #expect(ICloudRelay.exportFileName(for: "Home Lab") == "Home Lab.yaml")
        #expect(ICloudRelay.profileName(for: ICloudRelay.exportFileName(for: "Home Lab")) == "Home Lab")
        #expect(ICloudRelay.exportFileName(for: "我的配置") == "我的配置.yaml")
    }

    @Test
    func `export file name keeps an existing yaml extension`() {
        #expect(ICloudRelay.exportFileName(for: "sub.yml") == "sub.yml")
        #expect(ICloudRelay.exportFileName(for: "Office.YAML") == "Office.YAML")
    }

    @Test
    func `export file name is always relayable`() {
        for name in ["a/b:c", ".hidden", "..", "   ", "", "x\\y", "v1.2"] {
            let fileName = ICloudRelay.exportFileName(for: name)
            #expect(ICloudRelay.isRelayable(fileName: fileName), "\(name) -> \(fileName)")
        }
        #expect(ICloudRelay.exportFileName(for: "a/b:c") == "a-b-c.yaml")
        #expect(ICloudRelay.exportFileName(for: ".hidden") == "hidden.yaml")
        #expect(ICloudRelay.exportFileName(for: "  ") == "config.yaml")
    }

    // MARK: - ICloudDriveExporter.write

    @Test
    func `export writes the yaml and overwrites on re-export`() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudDriveExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try ICloudDriveExporter.write(yaml: "proxies: []\n", name: "Home", into: folder)
        let second = try ICloudDriveExporter.write(yaml: "proxies: []\n# v2\n", name: "Home", into: folder)

        #expect(first == "Home.yaml")
        #expect(second == first)
        let written = try String(contentsOf: folder.appendingPathComponent(first), encoding: .utf8)
        #expect(written == "proxies: []\n# v2\n")
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(entries == ["Home.yaml"])
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
