#import <Cocoa/Cocoa.h>
#import "CodexAuth.h"
#import "CodexRegistry.h"
#import "UsageSnapshot.h"

static NSString *const RefreshIntervalKey = @"refreshIntervalSeconds";
static NSString *const ReloadAuthOnRefreshKey = @"reloadAuthOnRefresh";
static NSString *const RequestTimeoutKey = @"requestTimeoutSeconds";
static NSString *const UsageHTTPStatusUserInfoKey = @"CodexBarUsageHTTPStatus";
static NSString *const UsageErrorCodeUserInfoKey = @"CodexBarUsageErrorCode";
static const NSTimeInterval DefaultUsageRequestTimeoutSeconds = 3.0;
static const NSInteger UsageRequestsPerHostLimit = 64;
// The 10pt top glyph exceeds the fixed 8.5pt line box, so it needs a visual offset.
static const CGFloat StatusTitleBaselineOffset = -6.0;
static const CGFloat AccountMenuColumnSpacing = 18.0;

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@interface AppDelegate ()

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSURLSession *usageSession;
@property (nonatomic, strong) CodexRegistry *registry;
@property (nonatomic, strong) CodexAuth *auth;
@property (nonatomic, strong) UsageSnapshot *snapshot;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic) BOOL refreshing;
@property (nonatomic, strong) NSMutableSet<NSString *> *refreshingAccountKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSError *> *accountRefreshErrors;
@property (nonatomic, strong) NSNumberFormatter *percentFormatter;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;
@property (nonatomic, strong) NSDateFormatter *weekResetFormatter;
@property (nonatomic, strong) NSDateFormatter *dateTimeFormatter;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.percentFormatter = [[NSNumberFormatter alloc] init];
    self.percentFormatter.minimumFractionDigits = 0;
    self.percentFormatter.maximumFractionDigits = 0;

    self.timeFormatter = [[NSDateFormatter alloc] init];
    self.timeFormatter.dateStyle = NSDateFormatterNoStyle;
    self.timeFormatter.timeStyle = NSDateFormatterShortStyle;

    self.weekResetFormatter = [[NSDateFormatter alloc] init];
    self.weekResetFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    self.weekResetFormatter.dateFormat = @"HH:mm 'on' d MMM";

    self.dateTimeFormatter = [[NSDateFormatter alloc] init];
    self.dateTimeFormatter.dateStyle = NSDateFormatterShortStyle;
    self.dateTimeFormatter.timeStyle = NSDateFormatterShortStyle;

    self.refreshingAccountKeys = [NSMutableSet set];
    self.accountRefreshErrors = [NSMutableDictionary dictionary];

    NSURLSessionConfiguration *usageConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    usageConfiguration.HTTPMaximumConnectionsPerHost = UsageRequestsPerHostLimit;
    self.usageSession = [NSURLSession sessionWithConfiguration:usageConfiguration];

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"";
    self.statusItem.button.image = nil;
    self.statusItem.button.imagePosition = NSNoImage;

    [self rebuildMenu];
    [self scheduleTimer];
    [self refreshWithReloadAuth:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.refreshTimer invalidate];
    [self.usageSession invalidateAndCancel];
}

- (double)refreshIntervalSeconds {
    double value = [NSUserDefaults.standardUserDefaults doubleForKey:RefreshIntervalKey];
    return value >= 30.0 ? value : 300.0;
}

- (void)setRefreshIntervalSeconds:(double)value {
    [NSUserDefaults.standardUserDefaults setDouble:fmax(30.0, value) forKey:RefreshIntervalKey];
}

- (double)usageRequestTimeoutSeconds {
    double value = [NSUserDefaults.standardUserDefaults doubleForKey:RequestTimeoutKey];
    return value >= 1.0 ? value : DefaultUsageRequestTimeoutSeconds;
}

- (void)setUsageRequestTimeoutSeconds:(double)value {
    [NSUserDefaults.standardUserDefaults setDouble:fmax(1.0, value) forKey:RequestTimeoutKey];
}

- (BOOL)reloadAuthOnRefresh {
    return [NSUserDefaults.standardUserDefaults boolForKey:ReloadAuthOnRefreshKey];
}

- (void)setReloadAuthOnRefresh:(BOOL)value {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:ReloadAuthOnRefreshKey];
}

- (void)scheduleTimer {
    [self.refreshTimer invalidate];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:self.refreshIntervalSeconds
                                                      target:self
                                                    selector:@selector(timerFired:)
                                                    userInfo:nil
                                                     repeats:YES];
    timer.tolerance = fmin(self.refreshIntervalSeconds * 0.1, 30.0);
    self.refreshTimer = timer;
}

- (void)timerFired:(NSTimer *)timer {
    (void)timer;
    [self refreshWithReloadAuth:NO];
}

- (void)refreshWithReloadAuth:(BOOL)reloadAuth {
    if (self.refreshing) {
        return;
    }

    if (reloadAuth || self.reloadAuthOnRefresh || !self.auth) {
        NSError *loadError = nil;
        if (![self loadAccountStateWithError:&loadError]) {
            self.lastError = loadError;
            [self updateStatusItem];
            [self rebuildMenu];
            return;
        }
    }

    NSString *accountKey = [self currentAccountKey];
    if (!self.auth) {
        self.lastError = CodexBarError(CodexBarErrorMissingAccessToken, @"No active account token is loaded");
        [self updateStatusItem];
        [self rebuildMenu];
        return;
    }
    self.refreshing = YES;
    [self updateStatusItem];
    [self rebuildMenu];

    [self fetchUsageForAuth:self.auth accountKey:accountKey updatesStatus:YES rebuildMainMenu:YES];
}

- (BOOL)loadAccountStateWithError:(NSError **)error {
    NSError *registryError = nil;
    CodexRegistry *loadedRegistry = [CodexRegistry loadDefaultWithError:&registryError];
    if (loadedRegistry) {
        NSError *authError = nil;
        CodexAuth *loadedAuth = [CodexAuth loadFromPath:loadedRegistry.activeAuthPath error:&authError];
        if (loadedAuth.accountKey.length > 0) {
            NSError *syncError = nil;
            if (![loadedRegistry synchronizeWithActiveAuth:loadedAuth error:&syncError]) {
                if (error) {
                    *error = syncError;
                }
                return NO;
            }
        }

        self.registry = loadedRegistry;
        CodexAccountRecord *active = loadedRegistry.activeAccount;
        self.snapshot = active.lastUsage;

        if (!loadedAuth && active) {
            authError = nil;
            loadedAuth = [loadedRegistry authForAccountKey:active.accountKey error:&authError];
        }
        if (!loadedAuth) {
            if (error) {
                *error = authError;
            }
            return NO;
        }
        self.auth = loadedAuth;
        return YES;
    }

    NSError *authError = nil;
    CodexAuth *loadedAuth = [CodexAuth loadDefaultWithError:&authError];
    if (!loadedAuth) {
        if (error) {
            *error = registryError ?: authError;
        }
        return NO;
    }
    self.registry = nil;
    self.auth = loadedAuth;
    self.snapshot = nil;
    return YES;
}

- (NSString *)currentAccountKey {
    if (self.registry.activeAccountKey.length > 0) {
        return self.registry.activeAccountKey;
    }
    return self.auth.accountKey;
}

- (void)fetchUsageForAuth:(CodexAuth *)auth accountKey:(NSString *)accountKey updatesStatus:(BOOL)updatesStatus rebuildMainMenu:(BOOL)rebuildMainMenu {
    NSURL *endpoint = [NSURL URLWithString:@"https://chatgpt.com/backend-api/wham/usage"];
    NSTimeInterval timeout = self.usageRequestTimeoutSeconds;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:timeout];
    request.HTTPMethod = @"GET";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", auth.accessToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:auth.accountID forHTTPHeaderField:@"ChatGPT-Account-Id"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"codex-bar/0.1" forHTTPHeaderField:@"User-Agent"];

    __block BOOL finished = NO;
    void (^finish)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (finished) {
            return;
        }
        finished = YES;
        [self handleUsageData:data response:response error:error accountKey:accountKey updatesStatus:updatesStatus rebuildMainMenu:rebuildMainMenu];
    };

    NSURLSessionDataTask *task = [self.usageSession dataTaskWithRequest:request
                                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            finish(data, response, error);
        });
    }];
    [task resume];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (finished) {
            return;
        }
        [task cancel];
        NSError *timeoutError = [NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorTimedOut
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Usage request timed out after %@", [self formatInterval:timeout]]}];
        finish(nil, nil, timeoutError);
    });
}

- (void)handleUsageData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error accountKey:(NSString *)accountKey updatesStatus:(BOOL)updatesStatus rebuildMainMenu:(BOOL)rebuildMainMenu {
    if (error) {
        [self handleUsageRefreshError:error accountKey:accountKey updatesStatus:updatesStatus rebuildMainMenu:rebuildMainMenu];
        return;
    }

    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        [self handleUsageRefreshError:CodexBarError(CodexBarErrorInvalidHTTPResponse, @"Usage request did not return an HTTP response")
                           accountKey:accountKey
                        updatesStatus:updatesStatus
                     rebuildMainMenu:rebuildMainMenu];
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode < 200 || httpResponse.statusCode > 299) {
        NSString *message = [NSString stringWithFormat:@"Usage request failed with HTTP %ld", (long)httpResponse.statusCode];
        NSString *code = [self errorCodeFromData:data];
        if (code.length > 0) {
            message = [message stringByAppendingFormat:@" (%@)", code];
        }
        NSMutableDictionary *userInfo = [@{
            NSLocalizedDescriptionKey: message,
            UsageHTTPStatusUserInfoKey: @(httpResponse.statusCode)
        } mutableCopy];
        if (code.length > 0) {
            userInfo[UsageErrorCodeUserInfoKey] = code;
        }
        NSError *httpError = [NSError errorWithDomain:CodexBarErrorDomain
                                                 code:CodexBarErrorHTTPStatus
                                             userInfo:userInfo];
        [self handleUsageRefreshError:httpError
                           accountKey:accountKey
                        updatesStatus:updatesStatus
                     rebuildMainMenu:rebuildMainMenu];
        return;
    }

    NSError *parseError = nil;
    UsageSnapshot *usage = [UsageSnapshot parseData:data ?: NSData.data fetchedAt:NSDate.date error:&parseError];
    if (!usage) {
        [self handleUsageRefreshError:parseError accountKey:accountKey updatesStatus:updatesStatus rebuildMainMenu:rebuildMainMenu];
        return;
    }

    if (accountKey.length > 0) {
        [self.refreshingAccountKeys removeObject:accountKey];
        [self.accountRefreshErrors removeObjectForKey:accountKey];
        [self.registry updateUsage:usage forAccountKey:accountKey];
        NSError *saveError = nil;
        if (self.registry && ![self.registry saveWithError:&saveError]) {
            [self.accountRefreshErrors setObject:saveError forKey:accountKey];
            if (updatesStatus) {
                self.lastError = saveError;
            }
        }
    }
    if (updatesStatus && [self shouldApplyStatusUpdateForAccountKey:accountKey]) {
        self.snapshot = usage;
        self.lastError = nil;
        self.refreshing = NO;
    }
    [self updateStatusItem];
    if (rebuildMainMenu) {
        [self rebuildMenu];
    } else {
        [self rebuildMenu];
    }
}

- (void)handleUsageRefreshError:(NSError *)error accountKey:(NSString *)accountKey updatesStatus:(BOOL)updatesStatus rebuildMainMenu:(BOOL)rebuildMainMenu {
    if (accountKey.length > 0) {
        [self.refreshingAccountKeys removeObject:accountKey];
        [self.accountRefreshErrors setObject:error forKey:accountKey];
    }
    if (updatesStatus && [self shouldApplyStatusUpdateForAccountKey:accountKey]) {
        self.lastError = error;
        self.refreshing = NO;
    }
    [self updateStatusItem];
    if (rebuildMainMenu) {
        [self rebuildMenu];
    } else {
        [self rebuildMenu];
    }
}

- (BOOL)shouldApplyStatusUpdateForAccountKey:(NSString *)accountKey {
    NSString *current = [self currentAccountKey];
    if (current.length == 0 || accountKey.length == 0) {
        return YES;
    }
    return [current isEqualToString:accountKey];
}

- (NSString *)errorCodeFromData:(NSData *)data {
    if (data.length == 0) {
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    NSDictionary *root = (NSDictionary *)object;
    NSDictionary *error = [root[@"error"] isKindOfClass:NSDictionary.class] ? root[@"error"] : nil;
    NSString *code = [error[@"code"] isKindOfClass:NSString.class] ? error[@"code"] : nil;
    if (code.length > 0) {
        return code;
    }

    NSDictionary *detail = [root[@"detail"] isKindOfClass:NSDictionary.class] ? root[@"detail"] : nil;
    code = [detail[@"code"] isKindOfClass:NSString.class] ? detail[@"code"] : nil;
    return code.length > 0 ? code : nil;
}

- (void)updateStatusItem {
    NSString *hourText = [self statusWindowText:self.snapshot.fiveHourWindow suffix:@"H"];
    NSString *weekText = [self statusWindowText:self.snapshot.weeklyWindow suffix:@"W"];
    self.statusItem.button.image = nil;
    self.statusItem.button.title = @"";
    self.statusItem.button.attributedTitle = [self statusTitleWithTopText:hourText bottomText:weekText];
    self.statusItem.length = [self statusTitleWidthForTopText:hourText bottomText:weekText];

    if (self.lastError) {
        self.statusItem.button.toolTip = self.lastError.localizedDescription;
    } else if (self.snapshot) {
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"Last refreshed %@", [self.dateTimeFormatter stringFromDate:self.snapshot.fetchedAt]];
    } else {
        self.statusItem.button.toolTip = @"Codex usage";
    }
}

- (NSString *)statusWindowText:(RateLimitWindow *)window suffix:(NSString *)suffix {
    NSString *value = nil;
    if (window) {
        value = [self formatPercent:window.remainingPercent];
    } else {
        value = (self.refreshing && !self.snapshot) ? @"..." : @"--";
    }
    return [NSString stringWithFormat:@"%@ %@", value, suffix];
}

- (NSAttributedString *)statusTitleWithTopText:(NSString *)topText bottomText:(NSString *)bottomText {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.minimumLineHeight = 8.5;
    paragraph.maximumLineHeight = 8.5;
    paragraph.lineSpacing = 0.0;

    NSDictionary<NSAttributedStringKey, id> *baseAttributes = @{
        NSForegroundColorAttributeName: NSColor.labelColor,
        NSParagraphStyleAttributeName: paragraph,
        NSBaselineOffsetAttributeName: @(StatusTitleBaselineOffset)
    };

    NSString *title = [NSString stringWithFormat:@"%@\n%@", topText, bottomText];
    NSMutableAttributedString *attributedTitle = [[NSMutableAttributedString alloc] initWithString:title attributes:baseAttributes];
    [attributedTitle addAttribute:NSFontAttributeName
                            value:[NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightSemibold]
                            range:NSMakeRange(0, topText.length)];
    [attributedTitle addAttribute:NSFontAttributeName
                            value:[NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightSemibold]
                            range:NSMakeRange(topText.length + 1, bottomText.length)];
    return attributedTitle;
}

- (CGFloat)statusTitleWidthForTopText:(NSString *)topText bottomText:(NSString *)bottomText {
    NSDictionary<NSAttributedStringKey, id> *topAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightSemibold]
    };
    NSDictionary<NSAttributedStringKey, id> *bottomAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightSemibold]
    };
    CGFloat topWidth = ceil([topText sizeWithAttributes:topAttributes].width);
    CGFloat bottomWidth = ceil([bottomText sizeWithAttributes:bottomAttributes].width);
    return MAX(30.0, MAX(topWidth, bottomWidth) + 14.0);
}

- (void)rebuildMenu {
    NSMenu *menu = self.statusItem.menu ?: [[NSMenu alloc] init];
    [menu removeAllItems];
    menu.autoenablesItems = NO;
    menu.delegate = self;

    [self addDisabledItemToMenu:menu title:[NSString stringWithFormat:@"Account: %@", [self accountMenuValue]]];
    [self addDisabledItemToMenu:menu title:[NSString stringWithFormat:@"Plan: %@", [self planMenuValue]]];
    [menu addItem:NSMenuItem.separatorItem];
    [self addDisabledItemToMenu:menu title:[self quotaMenuTitleWithName:@"5H" window:self.snapshot.fiveHourWindow showsDate:NO]];
    [self addDisabledItemToMenu:menu title:[self quotaMenuTitleWithName:@"Weekly" window:self.snapshot.weeklyWindow showsDate:YES]];

    if (self.lastError) {
        [menu addItem:NSMenuItem.separatorItem];
        [self addDisabledItemToMenu:menu title:[NSString stringWithFormat:@"Error: %@", self.lastError.localizedDescription]];
    }

    [menu addItem:NSMenuItem.separatorItem];
    NSString *refreshTitle = self.refreshing ? @"Refreshing..." : @"Refresh Now";
    NSMenuItem *refreshItem = [self addActionItemToMenu:menu title:refreshTitle action:@selector(refreshNow:)];
    refreshItem.enabled = !self.refreshing;

    [self addAccountsToMenu:menu];

    [self addActionItemToMenu:menu
                        title:[NSString stringWithFormat:@"Refresh Interval: %@...", [self formatInterval:self.refreshIntervalSeconds]]
                       action:@selector(setRefreshInterval:)];

    [self addActionItemToMenu:menu
                        title:[NSString stringWithFormat:@"Request Timeout: %@...", [self formatInterval:self.usageRequestTimeoutSeconds]]
                       action:@selector(setRequestTimeout:)];

    NSMenuItem *reloadItem = [self addActionItemToMenu:menu
                                                 title:@"Reload accounts on refresh"
                                                action:@selector(toggleReloadAuthOnRefresh:)];
    reloadItem.state = self.reloadAuthOnRefresh ? NSControlStateValueOn : NSControlStateValueOff;

    [menu addItem:NSMenuItem.separatorItem];
    [self addActionItemToMenu:menu title:@"Quit Codex Bar" action:@selector(quit:)];

    self.statusItem.menu = menu;
}

- (void)addAccountsToMenu:(NSMenu *)menu {
    if (!self.registry || self.registry.accounts.count == 0) {
        [self addDisabledItemToMenu:menu title:@"No codex-auth accounts"];
        return;
    }

    NSArray<CodexAccountRecord *> *records = [self.registry.accounts sortedArrayUsingComparator:^NSComparisonResult(CodexAccountRecord *left, CodexAccountRecord *right) {
        NSInteger leftRank = [self accountSortRank:left];
        NSInteger rightRank = [self accountSortRank:right];
        if (leftRank != rightRank) {
            return leftRank < rightRank ? NSOrderedAscending : NSOrderedDescending;
        }

        if (leftRank == 0) {
            double leftWeekly = left.lastUsage.weeklyWindow ? left.lastUsage.weeklyWindow.remainingPercent : -1.0;
            double rightWeekly = right.lastUsage.weeklyWindow ? right.lastUsage.weeklyWindow.remainingPercent : -1.0;
            if (leftWeekly != rightWeekly) {
                return leftWeekly > rightWeekly ? NSOrderedAscending : NSOrderedDescending;
            }

            double leftHourly = left.lastUsage.fiveHourWindow ? left.lastUsage.fiveHourWindow.remainingPercent : -1.0;
            double rightHourly = right.lastUsage.fiveHourWindow ? right.lastUsage.fiveHourWindow.remainingPercent : -1.0;
            if (leftHourly != rightHourly) {
                return leftHourly > rightHourly ? NSOrderedAscending : NSOrderedDescending;
            }
        }

        NSUInteger leftIndex = [self.registry.accounts indexOfObjectIdenticalTo:left];
        NSUInteger rightIndex = [self.registry.accounts indexOfObjectIdenticalTo:right];
        if (leftIndex == rightIndex) {
            return NSOrderedSame;
        }
        return leftIndex < rightIndex ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSArray<NSNumber *> *tabStops = [self accountRowTabStopsForRecords:records];
    NSArray<NSString *> *headings = @[@"PLAN", @"5H", @"WEEKLY", @"UPDATED", @"ACCOUNT"];
    [self addDisabledAttributedItemToMenu:menu title:[self accountRowAttributedTitleForColumns:headings tabStops:tabStops]];
    for (CodexAccountRecord *record in records) {
        NSError *error = self.accountRefreshErrors[record.accountKey];
        NSArray<NSString *> *columns = [self accountRowColumns:record error:error];
        NSString *title = [columns componentsJoinedByString:@"\t"];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(switchAccount:)
                                               keyEquivalent:@""];
        item.attributedTitle = [self accountRowAttributedTitleForColumns:columns tabStops:tabStops];
        item.target = self;
        item.representedObject = record.accountKey;
        item.state = [record.accountKey isEqualToString:self.registry.activeAccountKey] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
}

- (NSInteger)accountSortRank:(CodexAccountRecord *)record {
    return self.accountRefreshErrors[record.accountKey] ? 1 : 0;
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == self.statusItem.menu) {
        [self refreshAllAccountsFromMenu];
    }
}

- (void)refreshAllAccountsFromMenu {
    if (self.reloadAuthOnRefresh || !self.registry) {
        NSError *loadError = nil;
        if (![self loadAccountStateWithError:&loadError]) {
            self.lastError = loadError;
            [self updateStatusItem];
            [self rebuildMenu];
            return;
        }
    }

    if (!self.registry || self.registry.accounts.count == 0) {
        [self rebuildMenu];
        return;
    }

    [self.accountRefreshErrors removeAllObjects];
    for (CodexAccountRecord *record in self.registry.accounts) {
        [self.refreshingAccountKeys addObject:record.accountKey];
    }
    [self rebuildMenu];

    for (CodexAccountRecord *record in self.registry.accounts) {
        NSError *authError = nil;
        CodexAuth *accountAuth = [self.registry authForAccountKey:record.accountKey error:&authError];
        if (!accountAuth) {
            [self.refreshingAccountKeys removeObject:record.accountKey];
            [self.accountRefreshErrors setObject:authError ?: CodexBarError(CodexBarErrorMissingAccountSnapshot, @"Missing account snapshot")
                                          forKey:record.accountKey];
            [self rebuildMenu];
            continue;
        }

        BOOL updatesStatus = [record.accountKey isEqualToString:self.registry.activeAccountKey];
        if (updatesStatus) {
            self.refreshing = YES;
            self.auth = accountAuth;
        }
        [self fetchUsageForAuth:accountAuth accountKey:record.accountKey updatesStatus:updatesStatus rebuildMainMenu:NO];
    }
    [self updateStatusItem];
}

- (NSArray<NSString *> *)accountRowColumns:(CodexAccountRecord *)record error:(NSError *)error {
    NSString *primary = error ? [self accountRefreshErrorText:error] : [self accountWindowText:record.lastUsage.fiveHourWindow showsDate:NO];
    NSString *secondary = error ? [self accountRefreshErrorText:error] : [self accountWindowText:record.lastUsage.weeklyWindow showsDate:YES];
    NSString *last = CodexRelativeTimeString(record.lastUsageAt, NSDate.date);
    if ([self.refreshingAccountKeys containsObject:record.accountKey]) {
        last = @"Refreshing...";
    }

    return @[
        record.displayPlan,
        primary,
        secondary,
        last,
        record.identityDisplayName
    ];
}

- (NSArray<NSNumber *> *)accountRowTabStopsForRecords:(NSArray<CodexAccountRecord *> *)records {
    NSFont *font = [NSFont menuFontOfSize:0.0];
    NSArray<NSString *> *headings = @[@"PLAN", @"5H", @"WEEKLY", @"UPDATED"];
    CGFloat widths[] = {0.0, 0.0, 0.0, 0.0};
    NSDictionary<NSAttributedStringKey, id> *attributes = @{NSFontAttributeName: font};

    for (NSUInteger index = 0; index < 4; index++) {
        widths[index] = ceil([headings[index] sizeWithAttributes:attributes].width);
    }

    for (CodexAccountRecord *record in records) {
        NSArray<NSString *> *columns = [self accountRowColumns:record error:self.accountRefreshErrors[record.accountKey]];
        for (NSUInteger index = 0; index < 4; index++) {
            widths[index] = MAX(widths[index], ceil([columns[index] sizeWithAttributes:attributes].width));
        }
    }

    NSMutableArray<NSNumber *> *tabStops = [NSMutableArray arrayWithCapacity:4];
    CGFloat location = 0.0;
    for (NSUInteger index = 0; index < 4; index++) {
        location += widths[index] + AccountMenuColumnSpacing;
        [tabStops addObject:@(location)];
    }
    return tabStops;
}

- (NSAttributedString *)accountRowAttributedTitleForColumns:(NSArray<NSString *> *)columns tabStops:(NSArray<NSNumber *> *)tabStops {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    NSMutableArray<NSTextTab *> *textTabs = [NSMutableArray arrayWithCapacity:tabStops.count];
    for (NSNumber *location in tabStops) {
        [textTabs addObject:[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft
                                                           location:location.doubleValue
                                                            options:@{}]];
    }
    paragraph.tabStops = textTabs;

    return [[NSAttributedString alloc] initWithString:[columns componentsJoinedByString:@"\t"]
                                           attributes:@{
                                               NSFontAttributeName: [NSFont menuFontOfSize:0.0],
                                               NSForegroundColorAttributeName: NSColor.labelColor,
                                               NSParagraphStyleAttributeName: paragraph
                                           }];
}

- (NSString *)accountRefreshErrorText:(NSError *)error {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorTimedOut) {
        return @"Timeout";
    }

    NSNumber *status = error.userInfo[UsageHTTPStatusUserInfoKey];
    if (status) {
        NSString *code = error.userInfo[UsageErrorCodeUserInfoKey];
        if (code.length > 0) {
            return [NSString stringWithFormat:@"%@ %@", status, code];
        }
        return [NSString stringWithFormat:@"HTTP %@", status];
    }

    return @"Error";
}

- (NSString *)accountWindowText:(RateLimitWindow *)window showsDate:(BOOL)showsDate {
    if (!window) {
        return @"--";
    }

    NSString *text = [self formatPercent:window.remainingPercent];
    if (window.resetAt) {
        NSDateFormatter *formatter = showsDate ? self.weekResetFormatter : self.timeFormatter;
        text = [text stringByAppendingFormat:@" (%@)", [formatter stringFromDate:window.resetAt]];
    }
    return text;
}

- (NSString *)accountMenuValue {
    CodexAccountRecord *active = self.registry.activeAccount;
    if (active) {
        return active.identityDisplayName;
    }
    if (self.auth) {
        return self.auth.accountDisplayName;
    }

    return @"--";
}

- (NSString *)planMenuValue {
    if (self.snapshot.planType.length > 0) {
        return [CodexRegistry planLabel:self.snapshot.planType];
    }

    CodexAccountRecord *active = self.registry.activeAccount;
    if (active) {
        return active.displayPlan;
    }
    return [CodexRegistry planLabel:self.auth.planType];
}

- (NSString *)quotaMenuTitleWithName:(NSString *)name window:(RateLimitWindow *)window showsDate:(BOOL)showsDate {
    if (!window) {
        return [NSString stringWithFormat:@"%@: --", name];
    }

    NSString *title = [NSString stringWithFormat:@"%@: %@", name, [self formatPercent:window.remainingPercent]];
    if (window.resetAt) {
        NSDateFormatter *formatter = showsDate ? self.weekResetFormatter : self.timeFormatter;
        title = [title stringByAppendingFormat:@" (resets %@)", [formatter stringFromDate:window.resetAt]];
    }
    return title;
}

- (void)addDisabledItemToMenu:(NSMenu *)menu title:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:item];
}

- (void)addDisabledAttributedItemToMenu:(NSMenu *)menu title:(NSAttributedString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title.string action:nil keyEquivalent:@""];
    item.attributedTitle = title;
    item.enabled = NO;
    [menu addItem:item];
}

- (NSMenuItem *)addActionItemToMenu:(NSMenu *)menu title:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return item;
}

- (NSString *)formatPercent:(double)value {
    NSNumber *number = @(fmin(100.0, fmax(0.0, value)));
    NSString *formatted = [self.percentFormatter stringFromNumber:number] ?: @"--";
    return [formatted stringByAppendingString:@"%"];
}

- (NSString *)formatInterval:(double)seconds {
    if (seconds < 60.0) {
        return [NSString stringWithFormat:@"%lds", (long)seconds];
    }
    double minutes = seconds / 60.0;
    if (minutes < 60.0) {
        return [NSString stringWithFormat:@"%ldm", (long)minutes];
    }
    return [NSString stringWithFormat:@"%.1fh", minutes / 60.0];
}

- (void)refreshNow:(id)sender {
    (void)sender;
    [self refreshWithReloadAuth:self.reloadAuthOnRefresh];
}

- (void)switchAccount:(id)sender {
    NSString *accountKey = [sender isKindOfClass:NSMenuItem.class] ? ((NSMenuItem *)sender).representedObject : nil;
    if (accountKey.length == 0 || !self.registry) {
        return;
    }

    NSError *switchError = nil;
    if (![self.registry switchToAccountKey:accountKey error:&switchError]) {
        self.lastError = switchError;
        [self updateStatusItem];
        [self rebuildMenu];
        return;
    }

    CodexAccountRecord *active = self.registry.activeAccount;
    self.snapshot = active.lastUsage;
    NSError *authError = nil;
    CodexAuth *loadedAuth = [CodexAuth loadFromPath:self.registry.activeAuthPath error:&authError];
    if (!loadedAuth) {
        authError = nil;
        loadedAuth = [self.registry authForAccountKey:accountKey error:&authError];
    }
    self.auth = loadedAuth;
    self.lastError = loadedAuth ? nil : authError;
    self.refreshing = NO;
    [self updateStatusItem];
    [self rebuildMenu];
    if (self.auth) {
        [self refreshWithReloadAuth:NO];
    }
}

- (void)setRefreshInterval:(id)sender {
    (void)sender;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Refresh Interval";
    alert.informativeText = @"Enter the refresh interval in seconds. Minimum: 30 seconds.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    field.stringValue = [NSString stringWithFormat:@"%ld", (long)self.refreshIntervalSeconds];
    alert.accessoryView = field;

    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    double seconds = field.stringValue.doubleValue;
    if (seconds < 30.0) {
        [self showErrorWithMessage:@"Invalid refresh interval" detail:@"Use a number greater than or equal to 30."];
        return;
    }

    [self setRefreshIntervalSeconds:seconds];
    [self scheduleTimer];
    [self rebuildMenu];
}

- (void)setRequestTimeout:(id)sender {
    (void)sender;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Request Timeout";
    alert.informativeText = @"Enter the maximum request time in seconds. Minimum: 1 second.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    field.stringValue = [NSString stringWithFormat:@"%.1f", self.usageRequestTimeoutSeconds];
    alert.accessoryView = field;

    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    double seconds = field.stringValue.doubleValue;
    if (seconds < 1.0) {
        [self showErrorWithMessage:@"Invalid request timeout" detail:@"Use a number greater than or equal to 1."];
        return;
    }

    [self setUsageRequestTimeoutSeconds:seconds];
    [self rebuildMenu];
}

- (void)toggleReloadAuthOnRefresh:(id)sender {
    (void)sender;
    [self setReloadAuthOnRefresh:!self.reloadAuthOnRefresh];
    [self rebuildMenu];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)showErrorWithMessage:(NSString *)message detail:(NSString *)detail {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = message;
    alert.informativeText = detail;
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
