import CloudKit
import Foundation
import Observation

/// Reading half of the iCloud Drive → Apple TV relay (see `ICloudRelay`):
/// lists the configs the iOS app mirrored into the CloudKit relay zone.
///
/// Compiled into both apps but only the tvOS UI uses it. The `CKContainer`
/// is created on the first `reload()`, never at init, because creating one
/// in a build without the iCloud entitlement raises.
@MainActor
@Observable
final class ICloudRelayStore {
    enum Status: Equatable {
        case idle
        case loading
        case loaded
        /// No iCloud account on this device, or iCloud is restricted.
        case noAccount
        case failed(String)
    }

    private(set) var configs: [RelayedConfig] = []
    private(set) var status: Status = .idle

    func reload() async {
        guard status != .loading else { return }
        status = .loading
        let container = CKContainer(identifier: ICloudRelay.containerIdentifier)
        do {
            guard try await container.accountStatus() == .available else {
                configs = []
                status = .noAccount
                return
            }
            configs = try await Self.fetchAll(from: container.privateCloudDatabase)
            status = .loaded
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The phone hasn't relayed anything yet.
            configs = []
            status = .loaded
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Zone-changes fetch from the start (no stored token): the zone is a
    /// handful of small records, and a full read each time means a deletion
    /// on the phone can never leave a stale entry on the TV.
    private static func fetchAll(from database: CKDatabase) async throws -> [RelayedConfig] {
        let zoneID = CKRecordZone.ID(zoneName: ICloudRelay.zoneName)
        var token: CKServerChangeToken?
        var records: [CKRecord.ID: CKRecord] = [:]
        while true {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, result) in changes.modificationResultsByID {
                if case let .success(modification) = result {
                    records[id] = modification.record
                }
            }
            for deletion in changes.deletions {
                records[deletion.recordID] = nil
            }
            token = changes.changeToken
            if !changes.moreComing {
                break
            }
        }
        return records.values
            .compactMap(RelayedConfig.init(record:))
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

private extension RelayedConfig {
    init?(record: CKRecord) {
        guard record.recordType == ICloudRelay.recordType,
              let fileName = record[ICloudRelay.Field.fileName] as? String,
              let asset = record[ICloudRelay.Field.yaml] as? CKAsset,
              let fileURL = asset.fileURL,
              let data = try? Data(contentsOf: fileURL),
              let yaml = String(data: data, encoding: .utf8)
        else { return nil }
        self.init(
            id: record.recordID.recordName,
            fileName: fileName,
            modifiedAt: record[ICloudRelay.Field.modifiedAt] as? Date ?? record.modificationDate ?? .distantPast,
            yaml: yaml,
        )
    }
}
