#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Copies the GeoIP / ASN / geosite databases bundled in the extension into
/// `<container>/meow`, where the engine looks for them.
///
/// Only the macOS system extension needs this: on iOS and tvOS the app stages
/// them into the shared App Group (`GeoAssetStager`), but the macOS app and
/// its root-owned extension don't share a container, so the extension ships
/// and stages its own copy. A file is (re)copied when it's missing or empty,
/// or when the extension's version differs from the one that last staged.
@interface MWGeoAssets : NSObject

/// Blocking file copies (13 MB on a fresh install); call before engine start.
+ (void)stageIfNeeded;

@end

NS_ASSUME_NONNULL_END
