#import "MWGeoAssets.h"
#import "MWAppGroup.h"
#import <os/log.h>

// keep in sync with GeoAssetStager.assets (the engine's discovery names)
static NSArray<NSString *> *MWGeoAssetNames(void) {
    return @[@"Country.mmdb", @"GeoLite2-ASN.mmdb", @"geosite.mrs"];
}

static NSString *const kStampFileName = @"geo-asset-version";

@implementation MWGeoAssets

+ (void)stageIfNeeded {
    os_log_t log = os_log_create("com.tangzixiang.meow.PacketTunnel", "geo-assets");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *dir = [[MWAppGroup containerURL] URLByAppendingPathComponent:@"meow" isDirectory:YES];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&err]) {
        os_log_error(log, "create %{public}@ failed: %{public}@", dir.path, err);
        return;
    }

    NSBundle *bundle = [NSBundle mainBundle];
    NSString *version = [NSString stringWithFormat:@"%@+%@",
        [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0",
        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"0"];
    NSURL *stampURL = [dir URLByAppendingPathComponent:kStampFileName];
    NSString *stamp = [NSString stringWithContentsOfURL:stampURL encoding:NSUTF8StringEncoding error:nil];
    BOOL stampCurrent = [stamp isEqualToString:version];

    BOOL allStaged = YES;
    for (NSString *name in MWGeoAssetNames()) {
        NSURL *dest = [dir URLByAppendingPathComponent:name];
        NSNumber *size = nil;
        [dest getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (stampCurrent && size.longLongValue > 0) continue;

        NSURL *src = [bundle URLForResource:name withExtension:nil subdirectory:@"GeoData"]
                     ?: [bundle URLForResource:name withExtension:nil];
        if (!src) {
            os_log_error(log, "bundle missing %{public}@", name);
            allStaged = NO;
            continue;
        }
        // Copy beside the destination, then swap it in, so the engine never
        // opens a half-written database.
        NSURL *tmp = [dir URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.staging-%@", name, [NSUUID UUID].UUIDString]];
        BOOL ok = [fm copyItemAtURL:src toURL:tmp error:&err];
        if (ok) {
            ok = [fm fileExistsAtPath:dest.path]
                ? [fm replaceItemAtURL:dest withItemAtURL:tmp backupItemName:nil options:0
                      resultingItemURL:nil error:&err]
                : [fm moveItemAtURL:tmp toURL:dest error:&err];
        }
        if (!ok) {
            [fm removeItemAtURL:tmp error:nil];
            os_log_error(log, "stage %{public}@ failed: %{public}@", name, err);
            allStaged = NO;
            continue;
        }
        os_log_info(log, "staged %{public}@", name);
    }

    if (allStaged && !stampCurrent) {
        [version writeToURL:stampURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

@end
