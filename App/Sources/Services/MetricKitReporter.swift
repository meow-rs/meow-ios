#if os(iOS)
    import Foundation
    import MeowModels
    import MetricKit
    import os

    private let log = Logger(subsystem: "com.tangzixiang.meow.app", category: "metrickit")

    /// Subscribes the app process to MetricKit. Diagnostic payloads (crashes,
    /// hangs, CPU / disk-write exceptions) go to `CrashReportStore` for
    /// Settings › Crash Reports; daily metric payloads go to
    /// `MetricReportStore` for Settings › Performance Metrics. The
    /// packet-tunnel extension runs its own subscriber
    /// (`MWMetricKitSubscriber`) into the same directories.
    ///
    /// iOS-only: MetricKit doesn't exist on tvOS, and `Services/` is compiled
    /// into meow-tvos.
    final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {
        private let store: CrashReportStore
        private let metricStore: MetricReportStore
        private var started = false

        init(store: CrashReportStore = CrashReportStore(), metricStore: MetricReportStore = MetricReportStore()) {
            self.store = store
            self.metricStore = metricStore
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
            save(manager.pastPayloads)
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            save(payloads)
        }

        func didReceive(_ payloads: [MXMetricPayload]) {
            save(payloads)
        }

        private func save(_ payloads: [MXMetricPayload]) {
            for payload in payloads {
                do {
                    let url = try metricStore.save(
                        source: .app,
                        summary: MetricSummary(payload),
                        payload: payload.jsonRepresentation(),
                    )
                    log.notice("saved MetricKit metrics to \(url.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("saving MetricKit metrics failed: \(error.localizedDescription, privacy: .public)")
                }
            }
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

    extension MetricSummary {
        /// Base-unit summary of `payload`; `MWMetricKitSubscriber.m` builds
        /// the same keys for the tunnel.
        init(_ payload: MXMetricPayload) {
            self.init(begin: payload.timeStampBegin, end: payload.timeStampEnd)
            appVersion = payload.latestApplicationVersion
            if #available(iOS 26.0, *) {
                bundleIdentifier = payload.metaData?.bundleIdentifier
            }
            appBuildVersion = payload.metaData?.applicationBuildVersion
            osVersion = payload.metaData?.osVersion
            peakMemoryBytes = payload.memoryMetrics?.peakMemoryUsage.bytes
            averageSuspendedMemoryBytes = payload.memoryMetrics?.averageSuspendedMemory.averageMeasurement.bytes
            cpuTimeSeconds = payload.cpuMetrics?.cumulativeCPUTime.seconds
            foregroundTimeSeconds = payload.applicationTimeMetrics?.cumulativeForegroundTime.seconds
            backgroundTimeSeconds = payload.applicationTimeMetrics?.cumulativeBackgroundTime.seconds
            if let network = payload.networkTransferMetrics {
                wifiUploadBytes = network.cumulativeWifiUpload.bytes
                wifiDownloadBytes = network.cumulativeWifiDownload.bytes
                cellularUploadBytes = network.cumulativeCellularUpload.bytes
                cellularDownloadBytes = network.cumulativeCellularDownload.bytes
            }
            logicalWritesBytes = payload.diskIOMetrics?.cumulativeLogicalWrites.bytes
            if let launch = payload.applicationLaunchMetrics {
                launchMedianSeconds = Self.median(of: launch.histogrammedTimeToFirstDraw)
            }
            if let responsiveness = payload.applicationResponsivenessMetrics {
                hangCount = Self.buckets(of: responsiveness.histogrammedApplicationHangTime)
                    .reduce(0) { $0 + $1.bucketCount }
            }
            if let exits = payload.applicationExitMetrics {
                (foregroundExits, backgroundExits) = Self.exitCounts(exits)
            }
        }

        /// Exit counters keyed by `MetricExitReason.rawValue`, foreground then
        /// background.
        private static func exitCounts(_ exits: MXAppExitMetric) -> ([String: Int], [String: Int]) {
            let fg = exits.foregroundExitData
            let foreground = [
                MetricExitReason.normal.rawValue: fg.cumulativeNormalAppExitCount,
                MetricExitReason.abnormal.rawValue: fg.cumulativeAbnormalExitCount,
                MetricExitReason.memoryLimit.rawValue: fg.cumulativeMemoryResourceLimitExitCount,
                MetricExitReason.watchdog.rawValue: fg.cumulativeAppWatchdogExitCount,
                MetricExitReason.badAccess.rawValue: fg.cumulativeBadAccessExitCount,
                MetricExitReason.illegalInstruction.rawValue: fg.cumulativeIllegalInstructionExitCount,
            ]
            let bg = exits.backgroundExitData
            let taskAssertionTimeouts = bg.cumulativeBackgroundTaskAssertionTimeoutExitCount
            let background = [
                MetricExitReason.normal.rawValue: bg.cumulativeNormalAppExitCount,
                MetricExitReason.abnormal.rawValue: bg.cumulativeAbnormalExitCount,
                MetricExitReason.memoryLimit.rawValue: bg.cumulativeMemoryResourceLimitExitCount,
                MetricExitReason.memoryPressure.rawValue: bg.cumulativeMemoryPressureExitCount,
                MetricExitReason.watchdog.rawValue: bg.cumulativeAppWatchdogExitCount,
                MetricExitReason.cpuLimit.rawValue: bg.cumulativeCPUResourceLimitExitCount,
                MetricExitReason.badAccess.rawValue: bg.cumulativeBadAccessExitCount,
                MetricExitReason.illegalInstruction.rawValue: bg.cumulativeIllegalInstructionExitCount,
                MetricExitReason.lockedFile.rawValue: bg.cumulativeSuspendedWithLockedFileExitCount,
                MetricExitReason.taskAssertionTimeout.rawValue: taskAssertionTimeouts,
            ]
            return (foreground, background)
        }

        private static func buckets(of histogram: MXHistogram<UnitDuration>) -> [MXHistogramBucket<UnitDuration>] {
            histogram.bucketEnumerator.allObjects.compactMap { $0 as? MXHistogramBucket<UnitDuration> }
        }

        /// Midpoint of the bucket holding the median sample, or nil when the
        /// histogram is empty.
        private static func median(of histogram: MXHistogram<UnitDuration>) -> Double? {
            let buckets = buckets(of: histogram).sorted { $0.bucketStart.seconds < $1.bucketStart.seconds }
            let total = buckets.reduce(0) { $0 + $1.bucketCount }
            guard total > 0 else { return nil }
            var seen = 0
            for bucket in buckets {
                seen += bucket.bucketCount
                if seen * 2 >= total {
                    return (bucket.bucketStart.seconds + bucket.bucketEnd.seconds) / 2
                }
            }
            return nil
        }
    }

    private extension Measurement where UnitType == UnitInformationStorage {
        var bytes: Double {
            converted(to: .bytes).value
        }
    }

    private extension Measurement where UnitType == UnitDuration {
        var seconds: Double {
            converted(to: .seconds).value
        }
    }
#endif
