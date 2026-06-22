#import <Cocoa/Cocoa.h>
#import "CodexAuth.h"
#import "UsageSnapshot.h"

static NSString *const RefreshIntervalKey = @"refreshIntervalSeconds";
static NSString *const ReloadAuthOnRefreshKey = @"reloadAuthOnRefresh";

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@interface AppDelegate ()

@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) CodexAuth *auth;
@property (nonatomic, strong) UsageSnapshot *snapshot;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic) BOOL refreshing;
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
}

- (double)refreshIntervalSeconds {
    double value = [NSUserDefaults.standardUserDefaults doubleForKey:RefreshIntervalKey];
    return value >= 30.0 ? value : 300.0;
}

- (void)setRefreshIntervalSeconds:(double)value {
    [NSUserDefaults.standardUserDefaults setDouble:fmax(30.0, value) forKey:RefreshIntervalKey];
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
        NSError *authError = nil;
        CodexAuth *loadedAuth = [CodexAuth loadDefaultWithError:&authError];
        if (!loadedAuth) {
            self.lastError = authError;
            [self updateStatusItem];
            [self rebuildMenu];
            return;
        }
        self.auth = loadedAuth;
    }

    self.refreshing = YES;
    [self updateStatusItem];
    [self rebuildMenu];

    NSURL *endpoint = [NSURL URLWithString:@"https://chatgpt.com/backend-api/wham/usage"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"GET";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.auth.accessToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:self.auth.accountID forHTTPHeaderField:@"ChatGPT-Account-Id"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"codex-bar/0.1" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleUsageData:data response:response error:error];
        });
    }];
    [task resume];
}

- (void)handleUsageData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    self.refreshing = NO;

    if (error) {
        self.lastError = error;
        [self updateStatusItem];
        [self rebuildMenu];
        return;
    }

    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        self.lastError = CodexBarError(CodexBarErrorInvalidHTTPResponse, @"Usage request did not return an HTTP response");
        [self updateStatusItem];
        [self rebuildMenu];
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode < 200 || httpResponse.statusCode > 299) {
        NSString *message = [NSString stringWithFormat:@"Usage request failed with HTTP %ld", (long)httpResponse.statusCode];
        NSString *code = [self errorCodeFromData:data];
        if (code.length > 0) {
            message = [message stringByAppendingFormat:@" (%@)", code];
        }
        self.lastError = CodexBarError(CodexBarErrorHTTPStatus, message);
        [self updateStatusItem];
        [self rebuildMenu];
        return;
    }

    NSError *parseError = nil;
    UsageSnapshot *usage = [UsageSnapshot parseData:data ?: NSData.data fetchedAt:NSDate.date error:&parseError];
    if (!usage) {
        self.lastError = parseError;
        [self updateStatusItem];
        [self rebuildMenu];
        return;
    }

    self.snapshot = usage;
    self.lastError = nil;
    [self updateStatusItem];
    [self rebuildMenu];
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
    NSString *hourText = [self statusWindowText:self.snapshot.primary suffix:@"H"];
    NSString *weekText = [self statusWindowText:self.snapshot.secondary suffix:@"W"];
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
        NSBaselineOffsetAttributeName: @(-3.0)
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
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    [self addDisabledItemToMenu:menu title:[NSString stringWithFormat:@"Account: %@", [self accountMenuValue]]];
    [self addDisabledItemToMenu:menu title:[NSString stringWithFormat:@"Plan: %@", [self planMenuValue]]];
    [menu addItem:NSMenuItem.separatorItem];
    [self addDisabledItemToMenu:menu title:[self quotaMenuTitleWithName:@"5H" window:self.snapshot.primary showsDate:NO]];
    [self addDisabledItemToMenu:menu title:[self quotaMenuTitleWithName:@"Weekly" window:self.snapshot.secondary showsDate:YES]];

    if (self.lastError) {
        [menu addItem:NSMenuItem.separatorItem];
        [self addDisabledItemToMenu:menu title:[NSString stringWithFormat:@"Error: %@", self.lastError.localizedDescription]];
    }

    [menu addItem:NSMenuItem.separatorItem];
    NSString *refreshTitle = self.refreshing ? @"Refreshing..." : @"Refresh Now";
    NSMenuItem *refreshItem = [self addActionItemToMenu:menu title:refreshTitle action:@selector(refreshNow:)];
    refreshItem.enabled = !self.refreshing;

    [self addActionItemToMenu:menu
                        title:[NSString stringWithFormat:@"Refresh Interval: %@...", [self formatInterval:self.refreshIntervalSeconds]]
                       action:@selector(setRefreshInterval:)];

    NSMenuItem *reloadItem = [self addActionItemToMenu:menu
                                                 title:@"Reload auth.json on refresh"
                                                action:@selector(toggleReloadAuthOnRefresh:)];
    reloadItem.state = self.reloadAuthOnRefresh ? NSControlStateValueOn : NSControlStateValueOff;

    [menu addItem:NSMenuItem.separatorItem];
    [self addActionItemToMenu:menu title:@"Quit Codex Bar" action:@selector(quit:)];

    self.statusItem.menu = menu;
}

- (NSString *)accountMenuValue {
    if (self.auth) {
        return self.auth.accountDisplayName;
    }

    return @"--";
}

- (NSString *)planMenuValue {
    if (self.snapshot.planType.length == 0) {
        return @"--";
    }

    NSString *plan = [self.snapshot.planType lowercaseString];
    if ([plan isEqualToString:@"prolite"] || [plan isEqualToString:@"pro_lite"] || [plan isEqualToString:@"pro-lite"]) {
        return @"Pro Lite";
    }
    if ([plan isEqualToString:@"plus"]) {
        return @"Plus";
    }
    if ([plan isEqualToString:@"pro"]) {
        return @"Pro";
    }

    return self.snapshot.planType;
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
