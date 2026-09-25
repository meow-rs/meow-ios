import CryptoKit
import Foundation

/// iCloud Drive → Apple TV relay: shared constants and pure planning logic.
///
/// Apple TV has no iCloud Drive (QA1935: `ubiquityIdentityToken` is always
/// nil on tvOS, and `fileImporter` is unavailable there), so the TV can't
/// read the `iCloud Drive › meow` folder itself. The iOS app watches that
/// folder (`ICloudRelayUploader`) and mirrors each YAML file into a CloudKit
/// private-database zone; the tvOS app reads the zone (`ICloudRelayStore`)
/// and imports from it. The zone holds copies only — the files in iCloud
/// Drive stay the source of truth, and a file removed there is removed from
/// the zone on the next sync.
///
/// Everything here is Foundation-only so it compiles into both app targets
/// and stays testable without CloudKit.
enum ICloudRelay {
    /// One container for both halves — the iOS app's ubiquity (Documents)
    /// container and the CloudKit database the TV reads.
    static let containerIdentifier = "iCloud.com.tangzixiang.meow"
    /// Custom zone, so the TV can list it with a zone-changes fetch instead
    /// of a `CKQuery` (which would need a queryable index in the schema).
    static let zoneName = "ICloudDriveRelay"
    static let recordType = "RelayedConfig"

    enum Field {
        static let fileName = "fileName"
        static let contentHash = "contentHash"
        static let modifiedAt = "modifiedAt"
        static let yaml = "yaml"
    }

    /// Larger than any real Clash config; a file past this is almost
    /// certainly not one, and the TV would hold it in memory to import it.
    static let maxFileSize = 5 * 1024 * 1024

    /// `.yaml` / `.yml`, top-level, not hidden. Hidden names include the
    /// `.name.yaml.icloud` placeholders iCloud leaves for files that aren't
    /// downloaded yet.
    static func isRelayable(fileName: String) -> Bool {
        guard !fileName.hasPrefix("."), !fileName.contains("/") else { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext == "yaml" || ext == "yml"
    }

    /// Stable CloudKit record name for a file. Keyed on the case-folded name
    /// so re-saving a file overwrites its record instead of adding a second
    /// one, and hashed because record names are limited to ASCII.
    static func recordName(for fileName: String) -> String {
        "file-" + sha256Hex(Data(fileName.lowercased().utf8)).prefix(32)
    }

    /// Profile name the TV gives an imported file: the name without its
    /// extension, matching what iOS's Files import does.
    static func profileName(for fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }

    /// The file name a profile is exported under (`ICloudDriveExporter`):
    /// the profile name made safe for a file system, plus `.yaml`. Round-trips
    /// with `profileName(for:)`, so a config exported on the phone imports
    /// on the TV under the same name.
    static func exportFileName(for profileName: String) -> String {
        var stem = profileName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would make it a hidden file, which the relay skips.
        while stem.hasPrefix(".") {
            stem.removeFirst()
        }
        if stem.isEmpty {
            stem = "config"
        }
        return isRelayable(fileName: stem) ? stem : stem + ".yaml"
    }

    /// `iCloud Drive › meow`, created if missing — or nil when iCloud Drive is
    /// off, signed out, or the build lacks the entitlement. Blocks on the
    /// ubiquity daemon, so never call it on the main thread.
    static func resolveDocumentsFolder() -> URL? {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            return nil
        }
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        // The folder only shows up in iCloud Drive once it exists.
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What one sync pass has to do to make the zone match the folder.
///
/// `current` is every downloaded relayable file with its content hash;
/// `pending` is files present in the folder but not yet downloaded — they
/// are neither uploaded (no content yet) nor deleted (they still exist).
/// `synced` is what the last successful pass uploaded, keyed the same way.
struct ICloudRelayPlan: Equatable {
    var uploads: [String]
    var deletions: [String]

    var isEmpty: Bool {
        uploads.isEmpty && deletions.isEmpty
    }

    static func make(
        current: [String: String],
        pending: Set<String> = [],
        synced: [String: String],
    ) -> ICloudRelayPlan {
        let uploads = current
            .filter { synced[$0.key] != $0.value }
            .map(\.key)
            .sorted()
        let deletions = synced.keys
            .filter { current[$0] == nil && !pending.contains($0) }
            .sorted()
        return ICloudRelayPlan(uploads: uploads, deletions: deletions)
    }
}

/// A config the iOS app relayed, as the TV sees it.
struct RelayedConfig: Identifiable, Equatable {
    /// The CloudKit record name.
    let id: String
    let fileName: String
    let modifiedAt: Date
    let yaml: String

    var profileName: String {
        ICloudRelay.profileName(for: fileName)
    }
}
