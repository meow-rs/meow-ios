#import "MWAppGroup.h"

NSString *const MWAppGroupIdentifier = @"group.com.tangzixiang.meow";

@implementation MWAppGroup

+ (NSString *)identifier {
    return MWAppGroupIdentifier;
}

+ (NSURL *)containerURL {
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

+ (NSUserDefaults *)defaults {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:MWAppGroupIdentifier];
    NSAssert(d, @"Shared UserDefaults unavailable for suite '%@'", MWAppGroupIdentifier);
    return d;
}

@end
