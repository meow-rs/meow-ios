#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Saves MetricKit diagnostic payloads (crashes, hangs, CPU / disk-write
/// exceptions) delivered to the extension into the App Group, where the app's
/// Settings › Crash Reports lists them. Mirrors `CrashReportStore` in
/// MeowModels: same directory, same digest-based file name, so a payload saved
/// twice lands in one file. No-op on tvOS, which has no MetricKit.
@interface MWMetricKitSubscriber : NSObject

/// Subscribes once per process; later calls do nothing.
+ (void)start;

/// `metrickit-<first 16 bytes of SHA-256, hex>.json` — must match
/// `CrashReportStore.fileName(for:)`.
+ (NSString *)fileNameForJSON:(NSData *)json;

@end

NS_ASSUME_NONNULL_END
