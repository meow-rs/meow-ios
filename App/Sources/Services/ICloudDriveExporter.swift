#if os(iOS)
    import Foundation

    /// Saves a profile's YAML into `iCloud Drive › meow` — the folder the
    /// relay (`ICloudRelayUploader`) watches, so an exported config also
    /// reaches the Apple TV without another step.
    ///
    /// Exporting a profile again overwrites its file rather than adding a
    /// numbered copy: the file is the profile's iCloud Drive twin, and the TV
    /// matches it by name (`SubscriptionService.upsertLocal`).
    enum ICloudDriveExporter {
        enum ExportError: LocalizedError, Equatable {
            case iCloudUnavailable

            var errorDescription: String? {
                String(
                    localized: "subscriptions.exportICloud.error.unavailable",
                    comment: "Shown when saving a config to iCloud Drive while iCloud Drive is off or signed out",
                )
            }
        }

        /// Writes `yaml` as `ICloudRelay.exportFileName(for: name)` in the
        /// relay folder and returns that file name.
        static func export(name: String, yaml: String) async throws -> String {
            guard FileManager.default.ubiquityIdentityToken != nil else {
                throw ExportError.iCloudUnavailable
            }
            return try await Task.detached {
                guard let folder = ICloudRelay.resolveDocumentsFolder() else {
                    throw ExportError.iCloudUnavailable
                }
                return try write(yaml: yaml, name: name, into: folder)
            }.value
        }

        /// Internal-for-tests: the coordinated write, against any directory.
        /// Coordinated because the folder is iCloud-managed — an uncoordinated
        /// write can race the ubiquity daemon mid-upload.
        nonisolated static func write(yaml: String, name: String, into folder: URL) throws -> String {
            let fileName = ICloudRelay.exportFileName(for: name)
            let url = folder.appendingPathComponent(fileName)
            let data = Data(yaml.utf8)
            var coordinationError: NSError?
            var writeError: Error?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do {
                    try data.write(to: target, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let coordinationError {
                throw coordinationError
            }
            if let writeError {
                throw writeError
            }
            return fileName
        }
    }
#endif
