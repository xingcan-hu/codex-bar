#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RateLimitWindow : NSObject

@property (nonatomic, readonly) double usedPercent;
@property (nonatomic, strong, nullable, readonly) NSNumber *limitWindowSeconds;
@property (nonatomic, strong, nullable, readonly) NSDate *resetAt;

- (instancetype)initWithUsedPercent:(double)usedPercent
                  limitWindowSeconds:(nullable NSNumber *)limitWindowSeconds
                              resetAt:(nullable NSDate *)resetAt NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (double)remainingPercent;
- (nullable NSNumber *)windowMinutes;

@end

@interface CreditsSnapshot : NSObject

@property (nonatomic, readonly) BOOL hasCredits;
@property (nonatomic, readonly) BOOL unlimited;
@property (nonatomic, copy, nullable, readonly) NSString *balance;

- (instancetype)initWithHasCredits:(BOOL)hasCredits
                         unlimited:(BOOL)unlimited
                            balance:(nullable NSString *)balance NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface UsageSnapshot : NSObject

@property (nonatomic, copy, nullable, readonly) NSString *planType;
@property (nonatomic, strong, nullable, readonly) RateLimitWindow *primary;
@property (nonatomic, strong, nullable, readonly) RateLimitWindow *secondary;
@property (nonatomic, strong, nullable, readonly) CreditsSnapshot *credits;
@property (nonatomic, strong, readonly) NSDate *fetchedAt;

- (instancetype)initWithPlanType:(nullable NSString *)planType
                          primary:(nullable RateLimitWindow *)primary
                        secondary:(nullable RateLimitWindow *)secondary
                          credits:(nullable CreditsSnapshot *)credits
                        fetchedAt:(NSDate *)fetchedAt NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable NSNumber *)remainingPercent;
+ (nullable instancetype)parseData:(NSData *)data fetchedAt:(NSDate *)fetchedAt error:(NSError **)error;
+ (nullable instancetype)snapshotFromRegistryObject:(id)object lastUsageAt:(nullable NSDate *)lastUsageAt;
- (NSDictionary *)registryObjectWithPlanFallback:(nullable NSString *)planFallback;

@end

NS_ASSUME_NONNULL_END
