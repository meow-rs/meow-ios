import Foundation
import MeowModels
import Observation

/// Log ring buffer and live WebSocket subscription for the Logs utility screen.
/// Hoisted so entries survive Utility hub back-navigation.
@MainActor
@Observable
final class UtilityLogsStore {
    private(set) var allEntries: [LogEntry] = []
    var errorMessage: String?
    var level = "info"
    var autoScroll = true

    private var streamTask: Task<Void, Never>?

    func startStreaming(api: MeowAPI) {
        guard streamTask == nil else { return }
        streamTask = Task { @MainActor [weak self] in
            // Reconnect loop: the first attempt usually races VPN start (the
            // NE REST API is only up while the tunnel runs), and the stream
            // ends whenever the tunnel restarts. Keep retrying so Logs heals
            // without an app relaunch.
            while !Task.isCancelled {
                let stream = api.streamLogs(level: "debug")
                do {
                    for try await entry in stream {
                        guard let self else { return }
                        errorMessage = nil
                        allEntries.append(entry)
                        if allEntries.count > 2000 {
                            allEntries.removeFirst(allEntries.count - 2000)
                        }
                    }
                } catch {
                    guard let self else { return }
                    errorMessage = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
