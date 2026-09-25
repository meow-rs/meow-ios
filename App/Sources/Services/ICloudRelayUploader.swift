#if os(iOS)
    import CloudKit
    import Foundation
    import os

    private let relayLog = Logger(subsystem: "com.tangzixiang.meow.app", category: "icloud-relay")

    /// iOS half of the iCloud Drive → Apple TV relay (see `ICloudRelay`).
    ///
    /// Watches the app's public iCloud Drive folder (`iCloud Drive › meow`,
    /// published by `NSUbiquitousContainers` in `App/Info.plist`) with an
    /// `NSMetadataQuery` and mirrors every top-level `.yaml` / `.yml` file into
    /// the CloudKit relay zone. The query keeps delivering updates while the
    /// app runs, and resumes with the backlog when it comes back to the
    /// foreground — so a file saved from a Mac reaches the TV the next time
    /// meow is open on the phone.
    @MainActor
    final class ICloudRelayUploader {
        private let defaults: UserDefaults
        private var query: NSMetadataQuery?
        private var observers: [NSObjectProtocol] = []
        private var isSyncing = false
        private var needsAnotherPass = false

        /// `fileName → content hash` of what the last pass put in the zone, so
        /// unchanged files aren't re-uploaded on every launch. Per-device
        /// (`UserDefaults.standard`) on purpose: two phones on one account
        /// each converge the zone to their own view of the same folder.
        private static let syncedKey = "icloudRelay.synced"

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        /// No-op when iCloud is off, signed out, or the build lacks the iCloud
        /// entitlement — `ubiquityIdentityToken` is nil in all three, and it is
        /// checked before anything touches CloudKit, because creating a
        /// `CKContainer` without the entitlement raises instead of failing.
        func start() {
            guard query == nil, FileManager.default.ubiquityIdentityToken != nil else { return }
            Task {
                // Apple: never resolve the ubiquity container on the main thread.
                let documents = await Task.detached { () -> URL? in
                    guard let root = FileManager.default.url(
                        forUbiquityContainerIdentifier: ICloudRelay.containerIdentifier,
                    ) else { return nil }
                    let documents = root.appendingPathComponent("Documents", isDirectory: true)
                    // The folder only shows up in iCloud Drive once it exists.
                    try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                    return documents
                }.value
                guard documents != nil else {
                    relayLog.notice("ubiquity container unavailable; relay idle")
                    return
                }
                startQuery()
            }
        }

        private func startQuery() {
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(
                format: "%K LIKE[c] '*.yaml' OR %K LIKE[c] '*.yml'",
                NSMetadataItemFSNameKey, NSMetadataItemFSNameKey,
            )
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: query, queue: .main,
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.queryDidChange() }
                })
            }
            self.query = query
            query.start()
        }

        private func queryDidChange() {
            guard let query else { return }
            query.disableUpdates()
            var downloaded: [String: URL] = [:]
            var pending: Set<String> = []
            for case let item as NSMetadataItem in query.results {
                guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
                // Top level of Documents only — the relay zone is flat.
                guard url.deletingLastPathComponent().lastPathComponent == "Documents" else { continue }
                let name = url.lastPathComponent
                guard ICloudRelay.isRelayable(fileName: name) else { continue }
                let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
                if status == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                    downloaded[name] = url
                } else {
                    pending.insert(name)
                    // Pulls the file down; the query reports again when it lands.
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
            }
            query.enableUpdates()
            Task { await sync(downloaded: downloaded, pending: pending) }
        }

        private func sync(downloaded: [String: URL], pending: Set<String>) async {
            // Query updates arrive in bursts; coalesce overlapping passes so two
            // never race on the synced map.
            guard !isSyncing else {
                needsAnotherPass = true
                return
            }
            isSyncing = true
            defer {
                isSyncing = false
                if needsAnotherPass {
                    needsAnotherPass = false
                    queryDidChange()
                }
            }

            let contents = await Task.detached { Self.readFiles(downloaded) }.value
            var synced = defaults.dictionary(forKey: Self.syncedKey) as? [String: String] ?? [:]
            // A file that exists but couldn't be read this pass is as good as
            // pending: keep its record rather than deleting it.
            let unreadable = Set(downloaded.keys).subtracting(contents.keys)
            let plan = ICloudRelayPlan.make(
                current: contents.mapValues(\.hash),
                pending: pending.union(unreadable),
                synced: synced,
            )
            guard !plan.isEmpty else { return }

            do {
                synced = try await push(plan, contents: contents, synced: synced)
                defaults.set(synced, forKey: Self.syncedKey)
                relayLog.notice("relayed \(plan.uploads.count) upload(s), \(plan.deletions.count) deletion(s)")
            } catch {
                relayLog.error("relay sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Applies `plan` to the relay zone and returns `synced` updated with
        /// whatever actually landed — per record, since the batch is
        /// non-atomic and a partial failure is retried next pass.
        private func push(
            _ plan: ICloudRelayPlan,
            contents: [String: FileContents],
            synced: [String: String],
        ) async throws -> [String: String] {
            let database = CKContainer(identifier: ICloudRelay.containerIdentifier).privateCloudDatabase
            let zone = CKRecordZone(zoneName: ICloudRelay.zoneName)
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])

            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("icloud-relay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            let records = try plan.uploads.compactMap { name in
                try contents[name].map { try Self.makeRecord(name: name, file: $0, zone: zone, staging: staging) }
            }
            let (saved, deleted) = try await database.modifyRecords(
                saving: records,
                deleting: plan.deletions.map { Self.recordID(for: $0, in: zone) },
                savePolicy: .allKeys,
                atomically: false,
            )

            var synced = synced
            for name in plan.uploads {
                if case .success = saved[Self.recordID(for: name, in: zone)] {
                    synced[name] = contents[name]?.hash
                }
            }
            for name in plan.deletions {
                switch deleted[Self.recordID(for: name, in: zone)] {
                case .success:
                    synced[name] = nil
                case let .failure(error as CKError) where error.code == .unknownItem:
                    synced[name] = nil
                default:
                    break
                }
            }
            return synced
        }

        private static func makeRecord(
            name: String,
            file: FileContents,
            zone: CKRecordZone,
            staging: URL,
        ) throws -> CKRecord {
            // CKAsset uploads from a file it can read after this returns, so
            // stage a copy instead of pointing it into iCloud Drive.
            let assetURL = staging.appendingPathComponent(ICloudRelay.recordName(for: name))
            try file.data.write(to: assetURL)
            let record = CKRecord(recordType: ICloudRelay.recordType, recordID: recordID(for: name, in: zone))
            record[ICloudRelay.Field.fileName] = name
            record[ICloudRelay.Field.contentHash] = file.hash
            record[ICloudRelay.Field.modifiedAt] = file.modifiedAt
            record[ICloudRelay.Field.yaml] = CKAsset(fileURL: assetURL)
            return record
        }

        private struct FileContents {
            let data: Data
            let hash: String
            let modifiedAt: Date
        }

        /// Coordinated reads, off the main actor. Unreadable or oversized
        /// files are left out; `sync` treats them as pending so their records
        /// survive, and the next pass retries.
        private nonisolated static func readFiles(_ files: [String: URL]) -> [String: FileContents] {
            var result: [String: FileContents] = [:]
            let coordinator = NSFileCoordinator()
            for (name, url) in files {
                var coordinationError: NSError?
                var contents: FileContents?
                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
                    guard let values = try? readURL.resourceValues(forKeys: keys),
                          (values.fileSize ?? 0) <= ICloudRelay.maxFileSize,
                          let data = try? Data(contentsOf: readURL)
                    else { return }
                    contents = FileContents(
                        data: data,
                        hash: ICloudRelay.sha256Hex(data),
                        modifiedAt: values.contentModificationDate ?? .now,
                    )
                }
                if let contents {
                    result[name] = contents
                }
            }
            return result
        }

        private static func recordID(for fileName: String, in zone: CKRecordZone) -> CKRecord.ID {
            CKRecord.ID(recordName: ICloudRelay.recordName(for: fileName), zoneID: zone.zoneID)
        }
    }
#endif
