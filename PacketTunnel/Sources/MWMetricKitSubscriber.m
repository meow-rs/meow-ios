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
    });
#endif
}

+ (NSString *)fileNameForJSON:(NSData *)json {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(json.bytes, (CC_LONG)json.length, digest);
    NSMutableString *hex = [NSMutableString stringWithString:@"metrickit-"];
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

#endif

@end
