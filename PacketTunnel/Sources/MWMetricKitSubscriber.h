#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Saves MetricKit payloads delivered to the extension into the App Group:
/// diagnostics (crashes, hangs, CPU / disk-write exceptions) for Settings ›
/// Crash Reports, and daily metrics (memory peak, CPU, exits, network) for
/// Settings › Performance Metrics. Mirrors `CrashReportStore` and
/// `MetricReportStore` in MeowModels: same directories, same digest-based file
/// names (a payload saved twice lands in one file), and for metrics the same
/// envelope keys. No-op on tvOS, which has no MetricKit.
@interface MWMetricKitSubscriber : NSObject

/// Subscribes once per process; later calls do nothing.
+ (void)start;

/// `metrickit-<first 16 bytes of SHA-256, hex>.json` — must match
/// `CrashReportStore.fileName(for:)`.
+ (NSString *)fileNameForJSON:(NSData *)json;

/// `metrics-<first 16 bytes of SHA-256, hex>.json` — must match
/// `MetricReportStore.fileName(for:)`.
+ (NSString *)metricsFileNameForJSON:(NSData *)json;

@end

NS_ASSUME_NONNULL_END
