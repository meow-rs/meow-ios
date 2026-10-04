#if os(iOS)
    import Foundation
    import MeowModels
    import MetricKit
    import os

    private let log = Logger(subsystem: "com.tangzixiang.meow.app", category: "metrickit")

    /// Subscribes the app process to MetricKit and saves every diagnostic
    /// payload (crashes, hangs, CPU / disk-write exceptions) into
    /// `CrashReportStore`, where Settings › Crash Reports lists them. The
    /// packet-tunnel extension runs its own subscriber
    /// (`MWMetricKitSubscriber`) into the same directory.
    ///
    /// iOS-only: MetricKit doesn't exist on tvOS, and `Services/` is compiled
    /// into meow-tvos.
    final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {
        private let store: CrashReportStore
        private var started = false

        init(store: CrashReportStore = CrashReportStore()) {
            self.store = store
        }

        /// Idempotent. Also saves `pastDiagnosticPayloads`, which iOS hands
        /// over at subscribe time when a payload arrived while no subscriber
        /// was registered; the digest-based file name makes re-saving one
        /// harmless.
        func start() {
            guard !started else { return }
            started = true
            let manager = MXMetricManager.shared
            manager.add(self)
            save(manager.pastDiagnosticPayloads)
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            save(payloads)
        }

        private func save(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads {
                do {
                    let url = try store.save(payload.jsonRepresentation())
                    log.notice("saved MetricKit diagnostics to \(url.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("saving MetricKit diagnostics failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
#endif
