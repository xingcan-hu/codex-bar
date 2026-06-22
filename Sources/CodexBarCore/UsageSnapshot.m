#import "UsageSnapshot.h"
#import "CodexAuth.h"
#import <math.h>

static NSNumber *NumberFromValue(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        return value;
    }
    if ([value isKindOfClass:NSString.class]) {
        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        return [formatter numberFromString:value];
    }
    return nil;
}

static NSString *StringFromValue(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length == 0 ? nil : trimmed;
}

static RateLimitWindow *ParseWindow(id value) {
    if (![value isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    NSNumber *used = NumberFromValue(object[@"used_percent"]);
    if (!used) {
        return nil;
    }

    NSNumber *limitSeconds = NumberFromValue(object[@"limit_window_seconds"]);
    NSNumber *resetTimestamp = NumberFromValue(object[@"reset_at"]);
    NSDate *resetAt = resetTimestamp ? [NSDate dateWithTimeIntervalSince1970:resetTimestamp.doubleValue] : nil;

    return [[RateLimitWindow alloc] initWithUsedPercent:used.doubleValue
                                    limitWindowSeconds:limitSeconds
                                               resetAt:resetAt];
}

static RateLimitWindow *ParseRegistryWindow(id value) {
    if (![value isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    NSNumber *used = NumberFromValue(object[@"used_percent"]);
    if (!used) {
        return nil;
    }

    NSNumber *windowMinutes = NumberFromValue(object[@"window_minutes"]);
    NSNumber *limitSeconds = windowMinutes ? @(windowMinutes.doubleValue * 60.0) : nil;
    NSNumber *resetTimestamp = NumberFromValue(object[@"resets_at"]);
    NSDate *resetAt = resetTimestamp ? [NSDate dateWithTimeIntervalSince1970:resetTimestamp.doubleValue] : nil;
    return [[RateLimitWindow alloc] initWithUsedPercent:used.doubleValue
                                    limitWindowSeconds:limitSeconds
                                               resetAt:resetAt];
}

static id JSONObjectOrNull(id value) {
    return value ?: NSNull.null;
}

static NSDictionary *RegistryWindowObject(RateLimitWindow *window) {
    if (!window) {
        return nil;
    }

    NSMutableDictionary *object = [NSMutableDictionary dictionary];
    object[@"used_percent"] = @(window.usedPercent);
    object[@"window_minutes"] = JSONObjectOrNull(window.windowMinutes);
    object[@"resets_at"] = window.resetAt ? @((long long)floor(window.resetAt.timeIntervalSince1970)) : NSNull.null;
    return object;
}

@implementation RateLimitWindow

- (instancetype)initWithUsedPercent:(double)usedPercent
                  limitWindowSeconds:(NSNumber *)limitWindowSeconds
                              resetAt:(NSDate *)resetAt {
    self = [super init];
    if (self) {
        _usedPercent = usedPercent;
        _limitWindowSeconds = limitWindowSeconds;
        _resetAt = resetAt;
    }
    return self;
}

- (double)remainingPercent {
    return fmin(100.0, fmax(0.0, 100.0 - self.usedPercent));
}

- (NSNumber *)windowMinutes {
    if (!self.limitWindowSeconds || self.limitWindowSeconds.doubleValue <= 0) {
        return nil;
    }
    return @(ceil(self.limitWindowSeconds.doubleValue / 60.0));
}

@end

@implementation CreditsSnapshot

- (instancetype)initWithHasCredits:(BOOL)hasCredits unlimited:(BOOL)unlimited balance:(NSString *)balance {
    self = [super init];
    if (self) {
        _hasCredits = hasCredits;
        _unlimited = unlimited;
        _balance = [balance copy];
    }
    return self;
}

@end

@implementation UsageSnapshot

- (instancetype)initWithPlanType:(NSString *)planType
                          primary:(RateLimitWindow *)primary
                        secondary:(RateLimitWindow *)secondary
                          credits:(CreditsSnapshot *)credits
                        fetchedAt:(NSDate *)fetchedAt {
    self = [super init];
    if (self) {
        _planType = [planType copy];
        _primary = primary;
        _secondary = secondary;
        _credits = credits;
        _fetchedAt = fetchedAt;
    }
    return self;
}

- (NSNumber *)remainingPercent {
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:2];
    if (self.primary) {
        [values addObject:@(self.primary.remainingPercent)];
    }
    if (self.secondary) {
        [values addObject:@(self.secondary.remainingPercent)];
    }
    if (values.count == 0) {
        return nil;
    }

    double minimum = values.firstObject.doubleValue;
    for (NSNumber *value in values) {
        minimum = fmin(minimum, value.doubleValue);
    }
    return @(minimum);
}

+ (instancetype)parseData:(NSData *)data fetchedAt:(NSDate *)fetchedAt error:(NSError **)error {
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![object isKindOfClass:NSDictionary.class]) {
        if (error) {
            NSString *detail = jsonError.localizedDescription ?: @"root value is not an object";
            *error = CodexBarError(CodexBarErrorInvalidUsageResponse, [NSString stringWithFormat:@"Invalid usage response: %@", detail]);
        }
        return nil;
    }

    NSDictionary *root = (NSDictionary *)object;
    NSDictionary *rateLimit = [root[@"rate_limit"] isKindOfClass:NSDictionary.class] ? root[@"rate_limit"] : nil;
    RateLimitWindow *primary = ParseWindow(rateLimit[@"primary_window"]);
    RateLimitWindow *secondary = ParseWindow(rateLimit[@"secondary_window"]);

    if (!primary && !secondary) {
        if (error) {
            *error = CodexBarError(CodexBarErrorMissingRateLimit, @"Usage response did not contain primary or secondary rate limit windows");
        }
        return nil;
    }

    CreditsSnapshot *credits = nil;
    NSDictionary *creditsObject = [root[@"credits"] isKindOfClass:NSDictionary.class] ? root[@"credits"] : nil;
    if (creditsObject) {
        BOOL hasCredits = [creditsObject[@"has_credits"] respondsToSelector:@selector(boolValue)] ? [creditsObject[@"has_credits"] boolValue] : NO;
        BOOL unlimited = [creditsObject[@"unlimited"] respondsToSelector:@selector(boolValue)] ? [creditsObject[@"unlimited"] boolValue] : NO;
        credits = [[CreditsSnapshot alloc] initWithHasCredits:hasCredits
                                                    unlimited:unlimited
                                                      balance:StringFromValue(creditsObject[@"balance"])];
    }

    return [[self alloc] initWithPlanType:StringFromValue(root[@"plan_type"])
                                  primary:primary
                                secondary:secondary
                                  credits:credits
                                fetchedAt:fetchedAt];
}

+ (instancetype)snapshotFromRegistryObject:(id)object lastUsageAt:(NSDate *)lastUsageAt {
    if (![object isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    NSDictionary *root = (NSDictionary *)object;
    RateLimitWindow *primary = ParseRegistryWindow(root[@"primary"]);
    RateLimitWindow *secondary = ParseRegistryWindow(root[@"secondary"]);
    CreditsSnapshot *credits = nil;
    NSDictionary *creditsObject = [root[@"credits"] isKindOfClass:NSDictionary.class] ? root[@"credits"] : nil;
    if (creditsObject) {
        BOOL hasCredits = [creditsObject[@"has_credits"] respondsToSelector:@selector(boolValue)] ? [creditsObject[@"has_credits"] boolValue] : NO;
        BOOL unlimited = [creditsObject[@"unlimited"] respondsToSelector:@selector(boolValue)] ? [creditsObject[@"unlimited"] boolValue] : NO;
        credits = [[CreditsSnapshot alloc] initWithHasCredits:hasCredits
                                                    unlimited:unlimited
                                                      balance:StringFromValue(creditsObject[@"balance"])];
    }

    if (!primary && !secondary && !credits && !StringFromValue(root[@"plan_type"])) {
        return nil;
    }

    return [[self alloc] initWithPlanType:StringFromValue(root[@"plan_type"])
                                  primary:primary
                                secondary:secondary
                                  credits:credits
                                fetchedAt:lastUsageAt ?: NSDate.date];
}

- (NSDictionary *)registryObjectWithPlanFallback:(NSString *)planFallback {
    NSMutableDictionary *object = [NSMutableDictionary dictionary];
    object[@"primary"] = JSONObjectOrNull(RegistryWindowObject(self.primary));
    object[@"secondary"] = JSONObjectOrNull(RegistryWindowObject(self.secondary));
    if (self.credits) {
        object[@"credits"] = @{
            @"has_credits": @(self.credits.hasCredits),
            @"unlimited": @(self.credits.unlimited),
            @"balance": JSONObjectOrNull(self.credits.balance)
        };
    } else {
        object[@"credits"] = NSNull.null;
    }
    object[@"plan_type"] = JSONObjectOrNull(self.planType ?: planFallback);
    return object;
}

@end
