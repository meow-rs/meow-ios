#pragma once
#import <Foundation/Foundation.h>

@interface MWSharedStore : NSObject
+ (BOOL)writeState:(NSDictionary *)state error:(NSError **)error;
+ (nullable NSDictionary *)readState;
+ (BOOL)writeTraffic:(NSDictionary *)traffic error:(NSError **)error;
+ (nullable NSDictionary *)readTraffic;
+ (nullable NSDictionary *)readAPICredentials;
+ (BOOL)queueIntent:(NSDictionary *)intent error:(NSError **)error;
+ (nullable NSDictionary *)takeIntent;
@end
