#import "MWAppGroup.h"

NSString *const MWAppGroupIdentifier = @"group.com.tangzixiang.meow";

@implementation MWAppGroup

+ (NSString *)identifier {
    return MWAppGroupIdentifier;
}

+ (NSURL *)containerURL {
#if TARGET_OS_OSX
    // macOS: a system extension runs as root, so an App Group container here
    // would be root's, never the user's. Keep the same layout under root's
    // Application Support; the app gets the files it needs over provider
    // messages (TunnelHostIPC) instead. Must match AppGroup.containerURL's
    // macOS layout so both sides read the same relative paths.
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"meow" isDirectory:YES];
#else
    NSURL *url = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:MWAppGroupIdentifier];
    NSAssert(url, @"App Group container unavailable — entitlement missing '%@'", MWAppGroupIdentifier);
#if TARGET_OS_TV
    // tvOS: the container root is read-only; only Library/Caches is writable.
    // Must match AppGroup.containerURL (MeowShared) or the app and the
    // extension read and write different config.yaml files.
    url = [url URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
#endif
    return url;
#endif
}

+ (NSURL *)configURL {
    return [[self containerURL] URLByAppendingPathComponent:@"config.yaml"];
}

+ (NSURL *)effectiveConfigURL {
    return [[self containerURL] URLByAppendingPathComponent:@"effective-config.yaml"];
}

+ (NSURL *)stateURL {
    return [[self containerURL] URLByAppendingPathComponent:@"state.json"];
}

+ (NSURL *)trafficURL {
    return [[self containerURL] URLByAppendingPathComponent:@"traffic.json"];
}

+ (NSURL *)apiCredentialsURL {
    return [[self containerURL] URLByAppendingPathComponent:@"api-credentials.json"];
}

+ (NSURL *)metricKitDirectoryURL {
    return [[[self containerURL] URLByAppendingPathComponent:@"diagnostics" isDirectory:YES]
        URLByAppendingPathComponent:@"metrickit" isDirectory:YES];
}

+ (NSURL *)metricKitMetricsDirectoryURL {
    return [[[self containerURL] URLByAppendingPathComponent:@"diagnostics" isDirectory:YES]
        URLByAppendingPathComponent:@"metrickit-metrics" isDirectory:YES];
}

+ (NSUserDefaults *)defaults {
#if TARGET_OS_OSX
    // The app's preferences arrive with each start / intent and are saved
    // here, so on-demand starts without the app still see the last ones.
    return [NSUserDefaults standardUserDefaults];
#else
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:MWAppGroupIdentifier];
    NSAssert(d, @"Shared UserDefaults unavailable for suite '%@'", MWAppGroupIdentifier);
    return d;
#endif
}

@end
