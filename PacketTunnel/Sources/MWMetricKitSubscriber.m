#import "MWMetricKitSubscriber.h"

#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>

#import "MWAppGroup.h"
#import "MWEngineLog.h"

#if TARGET_OS_IOS
#import <MetricKit/MetricKit.h>

@interface MWMetricKitSubscriber () <MXMetricManagerSubscriber>
@end
#endif

static os_log_t gLog;

@implementation MWMetricKitSubscriber

+ (void)initialize {
    if (self == [MWMetricKitSubscriber class]) {
        gLog = os_log_create("com.tangzixiang.meow.PacketTunnel", "metrickit");
    }
}

+ (void)start {
#if TARGET_OS_IOS
    static MWMetricKitSubscriber *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[MWMetricKitSubscriber alloc] init];
        // MXMetricManager holds subscribers weakly; `shared` keeps it alive
        // for the life of the process.
        [[MXMetricManager sharedManager] addSubscriber:shared];
        [shared saveDiagnosticPayloads:[MXMetricManager sharedManager].pastDiagnosticPayloads];
        [shared saveMetricPayloads:[MXMetricManager sharedManager].pastPayloads];
    });
#endif
}

+ (NSString *)fileNameForJSON:(NSData *)json {
    return [self fileNameForJSON:json prefix:@"metrickit-"];
}

+ (NSString *)metricsFileNameForJSON:(NSData *)json {
    return [self fileNameForJSON:json prefix:@"metrics-"];
}

+ (NSString *)fileNameForJSON:(NSData *)json prefix:(NSString *)prefix {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(json.bytes, (CC_LONG)json.length, digest);
    NSMutableString *hex = [NSMutableString stringWithString:prefix];
    for (int i = 0; i < 16; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    [hex appendString:@".json"];
    return hex;
}

#if TARGET_OS_IOS

- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads {
    [self saveDiagnosticPayloads:payloads];
}

- (void)saveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads {
    if (payloads.count == 0) {
        return;
    }
    NSURL *dir = [MWAppGroup metricKitDirectoryURL];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error]) {
        os_log_error(gLog, "metrickit: mkdir failed: %{public}@", error);
        return;
    }
    for (MXDiagnosticPayload *payload in payloads) {
        NSData *json = [payload JSONRepresentation];
        NSURL *url = [dir URLByAppendingPathComponent:[MWMetricKitSubscriber fileNameForJSON:json]];
        if ([json writeToURL:url options:NSDataWritingAtomic error:&error]) {
            MWEngineLogf(MWLogWarn, @"NE: saved MetricKit diagnostics (%lu crash, %lu hang) to %@",
                         (unsigned long)payload.crashDiagnostics.count,
                         (unsigned long)payload.hangDiagnostics.count,
                         url.lastPathComponent);
        } else {
            os_log_error(gLog, "metrickit: write failed: %{public}@", error);
        }
    }
}

- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads {
    [self saveMetricPayloads:payloads];
}

static NSNumber *MWBytes(NSMeasurement *m) {
    if (!m) return nil;
    return @([m measurementByConvertingToUnit:NSUnitInformationStorage.bytes].doubleValue);
}

static NSNumber *MWSeconds(NSMeasurement *m) {
    if (!m) return nil;
    return @([m measurementByConvertingToUnit:NSUnitDuration.seconds].doubleValue);
}

/// Same keys as `MetricSummary` (MeowModels): base units, dates as seconds
/// since 1970, absent metrics left out.
+ (NSDictionary *)summaryForPayload:(MXMetricPayload *)p {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"begin"] = @(p.timeStampBegin.timeIntervalSince1970);
    s[@"end"] = @(p.timeStampEnd.timeIntervalSince1970);
    s[@"appVersion"] = p.latestApplicationVersion;
    if (@available(iOS 26.0, *)) {
        s[@"bundleIdentifier"] = p.metaData.bundleIdentifier;
    }
    s[@"appBuildVersion"] = p.metaData.applicationBuildVersion;
    s[@"osVersion"] = p.metaData.osVersion;
    s[@"peakMemoryBytes"] = MWBytes(p.memoryMetrics.peakMemoryUsage);
    s[@"averageSuspendedMemoryBytes"] = MWBytes(p.memoryMetrics.averageSuspendedMemory.averageMeasurement);
    s[@"cpuTimeSeconds"] = MWSeconds(p.cpuMetrics.cumulativeCPUTime);
    s[@"foregroundTimeSeconds"] = MWSeconds(p.applicationTimeMetrics.cumulativeForegroundTime);
    s[@"backgroundTimeSeconds"] = MWSeconds(p.applicationTimeMetrics.cumulativeBackgroundTime);
    s[@"wifiUploadBytes"] = MWBytes(p.networkTransferMetrics.cumulativeWifiUpload);
    s[@"wifiDownloadBytes"] = MWBytes(p.networkTransferMetrics.cumulativeWifiDownload);
    s[@"cellularUploadBytes"] = MWBytes(p.networkTransferMetrics.cumulativeCellularUpload);
    s[@"cellularDownloadBytes"] = MWBytes(p.networkTransferMetrics.cumulativeCellularDownload);
    s[@"logicalWritesBytes"] = MWBytes(p.diskIOMetrics.cumulativeLogicalWrites);
    MXAppExitMetric *exits = p.applicationExitMetrics;
    if (exits) {
        MXForegroundExitData *fg = exits.foregroundExitData;
        s[@"foregroundExits"] = @{
            @"normal": @(fg.cumulativeNormalAppExitCount),
            @"abnormal": @(fg.cumulativeAbnormalExitCount),
            @"memoryLimit": @(fg.cumulativeMemoryResourceLimitExitCount),
            @"watchdog": @(fg.cumulativeAppWatchdogExitCount),
            @"badAccess": @(fg.cumulativeBadAccessExitCount),
            @"illegalInstruction": @(fg.cumulativeIllegalInstructionExitCount),
        };
        MXBackgroundExitData *bg = exits.backgroundExitData;
        s[@"backgroundExits"] = @{
            @"normal": @(bg.cumulativeNormalAppExitCount),
            @"abnormal": @(bg.cumulativeAbnormalExitCount),
            @"memoryLimit": @(bg.cumulativeMemoryResourceLimitExitCount),
            @"memoryPressure": @(bg.cumulativeMemoryPressureExitCount),
            @"watchdog": @(bg.cumulativeAppWatchdogExitCount),
            @"cpuLimit": @(bg.cumulativeCPUResourceLimitExitCount),
            @"badAccess": @(bg.cumulativeBadAccessExitCount),
            @"illegalInstruction": @(bg.cumulativeIllegalInstructionExitCount),
            @"lockedFile": @(bg.cumulativeSuspendedWithLockedFileExitCount),
            @"taskAssertionTimeout": @(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount),
        };
    }
    return s;
}

- (void)saveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads {
    if (payloads.count == 0) {
        return;
    }
    NSURL *dir = [MWAppGroup metricKitMetricsDirectoryURL];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error]) {
        os_log_error(gLog, "metrickit: mkdir failed: %{public}@", error);
        return;
    }
    for (MXMetricPayload *payload in payloads) {
        NSData *raw = [payload JSONRepresentation];
        NSMutableDictionary *envelope = [NSMutableDictionary dictionary];
        envelope[@"source"] = @"tunnel";
        envelope[@"summary"] = [MWMetricKitSubscriber summaryForPayload:payload];
        id rawObject = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
        if (rawObject) {
            envelope[@"payload"] = rawObject;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:envelope
                                                       options:NSJSONWritingSortedKeys
                                                         error:&error];
        NSURL *url = [dir URLByAppendingPathComponent:[MWMetricKitSubscriber metricsFileNameForJSON:raw]];
        if (data && [data writeToURL:url options:NSDataWritingAtomic error:&error]) {
            MWEngineLogf(MWLogInfo, @"NE: saved MetricKit metrics to %@", url.lastPathComponent);
        } else {
            os_log_error(gLog, "metrickit: metrics write failed: %{public}@", error);
        }
    }
}

#endif

@end
