#import "CodexRegistry.h"
#import "CodexAuth.h"
#import "UsageSnapshot.h"
#import <sys/stat.h>

static NSString *StringValue(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length == 0 ? nil : trimmed;
}

static NSNumber *NumberValue(id value) {
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

static id ObjectOrNull(id value) {
    return value ?: NSNull.null;
}

static NSDate *DateFromSeconds(id value) {
    NSNumber *number = NumberValue(value);
    return number ? [NSDate dateWithTimeIntervalSince1970:number.doubleValue] : nil;
}

static NSDate *DateFromMilliseconds(id value) {
    NSNumber *number = NumberValue(value);
    return number ? [NSDate dateWithTimeIntervalSince1970:number.doubleValue / 1000.0] : nil;
}

static NSNumber *SecondsFromDate(NSDate *date) {
    return date ? @((long long)floor(date.timeIntervalSince1970)) : nil;
}

static NSNumber *MillisecondsFromDate(NSDate *date) {
    return date ? @((long long)floor(date.timeIntervalSince1970 * 1000.0)) : nil;
}

static void HardenPrivateFile(NSString *path) {
    chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
}

static void EnsurePrivateDirectory(NSString *path) {
    [NSFileManager.defaultManager createDirectoryAtPath:path
                            withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700}
                                                  error:nil];
    chmod(path.fileSystemRepresentation, S_IRWXU);
}

static NSString *TimestampString(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    return [formatter stringFromDate:NSDate.date];
}

static NSString *UniqueBackupPath(NSString *path) {
    NSString *base = [NSString stringWithFormat:@"%@.bak.%@", path, TimestampString()];
    if (![NSFileManager.defaultManager fileExistsAtPath:base]) {
        return base;
    }
    for (NSInteger index = 1; index < 1000; index += 1) {
        NSString *candidate = [base stringByAppendingFormat:@".%ld", (long)index];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return [base stringByAppendingFormat:@".%lld", (long long)(NSDate.date.timeIntervalSince1970 * 1000.0)];
}

static BOOL WritePrivateData(NSData *data, NSString *path, NSError **error) {
    NSString *dir = path.stringByDeletingLastPathComponent;
    EnsurePrivateDirectory(dir);
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    HardenPrivateFile(path);
    return YES;
}

static BOOL BackupIfChanged(NSString *path, NSData *replacement, NSError **error) {
    NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!existing || [existing isEqualToData:replacement]) {
        return YES;
    }
    NSString *backup = UniqueBackupPath(path);
    if (![NSFileManager.defaultManager copyItemAtPath:path toPath:backup error:error]) {
        return NO;
    }
    HardenPrivateFile(backup);
    return YES;
}

static BOOL BackupAuthIfChanged(NSString *activeAuthPath, NSString *accountsDirectoryPath, NSData *replacement, NSError **error) {
    NSData *existing = [NSData dataWithContentsOfFile:activeAuthPath options:0 error:nil];
    if (!existing || [existing isEqualToData:replacement]) {
        return YES;
    }
    EnsurePrivateDirectory(accountsDirectoryPath);
    NSString *backup = UniqueBackupPath([accountsDirectoryPath stringByAppendingPathComponent:@"auth.json"]);
    if (![NSFileManager.defaultManager copyItemAtPath:activeAuthPath toPath:backup error:error]) {
        return NO;
    }
    HardenPrivateFile(backup);
    return YES;
}

static NSString *Base64URLNoPad(NSData *data) {
    NSString *base64 = [data base64EncodedStringWithOptions:0];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    while ([base64 hasSuffix:@"="]) {
        base64 = [base64 substringToIndex:base64.length - 1];
    }
    return base64;
}

static BOOL KeyNeedsFilenameEncoding(NSString *key) {
    if (key.length == 0 || [key isEqualToString:@"."] || [key isEqualToString:@".."]) {
        return YES;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."];
    return [key rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound;
}

NSString *CodexRelativeTimeString(NSDate *date, NSDate *now) {
    if (!date) {
        return @"Never";
    }
    NSTimeInterval delta = MAX(0.0, [now timeIntervalSinceDate:date]);
    if (delta < 60.0) {
        return @"Now";
    }
    if (delta < 3600.0) {
        return [NSString stringWithFormat:@"%ldm ago", (long)floor(delta / 60.0)];
    }
    if (delta < 86400.0) {
        return [NSString stringWithFormat:@"%ldh ago", (long)floor(delta / 3600.0)];
    }
    return [NSString stringWithFormat:@"%ldd ago", (long)floor(delta / 86400.0)];
}

@implementation CodexAccountRecord

- (instancetype)initWithAccountKey:(NSString *)accountKey
                   chatGPTAccountID:(NSString *)chatGPTAccountID
                      chatGPTUserID:(NSString *)chatGPTUserID
                              email:(NSString *)email
                              alias:(NSString *)alias
                        accountName:(NSString *)accountName
                               plan:(NSString *)plan
                           authMode:(NSString *)authMode
                          createdAt:(NSDate *)createdAt
                         lastUsedAt:(NSDate *)lastUsedAt
                          lastUsage:(UsageSnapshot *)lastUsage
                        lastUsageAt:(NSDate *)lastUsageAt
                   lastLocalRollout:(id)lastLocalRollout {
    self = [super init];
    if (self) {
        _accountKey = [accountKey copy];
        _chatGPTAccountID = [chatGPTAccountID copy];
        _chatGPTUserID = [chatGPTUserID copy];
        _email = [email copy];
        _alias = [alias copy] ?: @"";
        _accountName = [accountName copy];
        _plan = [plan copy];
        _authMode = [authMode copy];
        _createdAt = createdAt ?: NSDate.date;
        _lastUsedAt = lastUsedAt;
        _lastUsage = lastUsage;
        _lastUsageAt = lastUsageAt;
        _lastLocalRollout = lastLocalRollout;
    }
    return self;
}

- (NSString *)identityDisplayName {
    if (self.alias.length > 0) {
        return [NSString stringWithFormat:@"%@(%@)", self.alias, self.email];
    }
    if (self.accountName.length > 0) {
        return [NSString stringWithFormat:@"%@(%@)", self.accountName, self.email];
    }
    return self.email.length > 0 ? self.email : self.accountKey;
}

- (NSString *)displayPlan {
    return [CodexRegistry planLabel:self.lastUsage.planType ?: self.plan];
}

- (NSDictionary *)registryObject {
    return @{
        @"account_key": self.accountKey,
        @"chatgpt_account_id": self.chatGPTAccountID,
        @"chatgpt_user_id": self.chatGPTUserID,
        @"email": self.email,
        @"alias": self.alias ?: @"",
        @"account_name": ObjectOrNull(self.accountName),
        @"plan": ObjectOrNull(self.plan),
        @"auth_mode": ObjectOrNull(self.authMode),
        @"created_at": SecondsFromDate(self.createdAt) ?: @0,
        @"last_used_at": ObjectOrNull(SecondsFromDate(self.lastUsedAt)),
        @"last_usage": ObjectOrNull([self.lastUsage registryObjectWithPlanFallback:self.plan]),
        @"last_usage_at": ObjectOrNull(SecondsFromDate(self.lastUsageAt)),
        @"last_local_rollout": ObjectOrNull(self.lastLocalRollout)
    };
}

@end

@implementation CodexRegistry

- (instancetype)initWithCodexHome:(NSString *)codexHome
                  activeAccountKey:(NSString *)activeAccountKey
          previousActiveAccountKey:(NSString *)previousActiveAccountKey
           activeAccountActivatedAt:(NSDate *)activeAccountActivatedAt
                    intervalSeconds:(NSInteger)intervalSeconds
                           accounts:(NSArray<CodexAccountRecord *> *)accounts {
    self = [super init];
    if (self) {
        _codexHome = [codexHome copy];
        _activeAccountKey = [activeAccountKey copy];
        _previousActiveAccountKey = [previousActiveAccountKey copy];
        _activeAccountActivatedAt = activeAccountActivatedAt;
        _intervalSeconds = intervalSeconds > 0 ? intervalSeconds : 60;
        _accounts = [accounts mutableCopy] ?: [NSMutableArray array];
    }
    return self;
}

+ (NSString *)defaultCodexHome {
    NSString *override = [NSProcessInfo.processInfo.environment[@"CODEX_HOME"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (override.length > 0) {
        return override.stringByStandardizingPath;
    }
    return [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
}

+ (instancetype)loadDefaultWithError:(NSError **)error {
    return [self loadFromCodexHome:self.defaultCodexHome error:error];
}

+ (instancetype)loadFromCodexHome:(NSString *)codexHome error:(NSError **)error {
    NSString *path = [[codexHome stringByAppendingPathComponent:@"accounts"] stringByAppendingPathComponent:@"registry.json"];
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        if (error) {
            NSString *detail = readError.localizedDescription ?: @"unknown error";
            *error = CodexBarError(CodexBarErrorReadFailed, [NSString stringWithFormat:@"Unable to read registry at %@: %@", path, detail]);
        }
        return nil;
    }

    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error) {
            NSString *detail = jsonError.localizedDescription ?: @"root value is not an object";
            *error = CodexBarError(CodexBarErrorInvalidJSON, [NSString stringWithFormat:@"Invalid registry.json: %@", detail]);
        }
        return nil;
    }

    NSDictionary *root = (NSDictionary *)json;
    NSInteger schema = [NumberValue(root[@"schema_version"] ?: root[@"version"]) integerValue];
    if (schema == 0) {
        schema = 4;
    }
    if (schema != 3 && schema != 4) {
        if (error) {
            *error = CodexBarError(CodexBarErrorUnsupportedRegistrySchema, [NSString stringWithFormat:@"Unsupported registry schema version %ld", (long)schema]);
        }
        return nil;
    }

    NSMutableArray<CodexAccountRecord *> *accounts = [NSMutableArray array];
    NSArray *accountObjects = [root[@"accounts"] isKindOfClass:NSArray.class] ? root[@"accounts"] : @[];
    for (id item in accountObjects) {
        if (![item isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *object = (NSDictionary *)item;
        NSString *accountKey = StringValue(object[@"account_key"]);
        NSString *chatGPTAccountID = StringValue(object[@"chatgpt_account_id"]);
        NSString *chatGPTUserID = StringValue(object[@"chatgpt_user_id"]);
        NSString *email = StringValue(object[@"email"]);
        if (!accountKey || !chatGPTAccountID || !chatGPTUserID || !email) {
            continue;
        }
        NSDate *lastUsageAt = DateFromSeconds(object[@"last_usage_at"]);
        UsageSnapshot *lastUsage = [UsageSnapshot snapshotFromRegistryObject:object[@"last_usage"] lastUsageAt:lastUsageAt];
        CodexAccountRecord *record = [[CodexAccountRecord alloc] initWithAccountKey:accountKey
                                                                   chatGPTAccountID:chatGPTAccountID
                                                                      chatGPTUserID:chatGPTUserID
                                                                              email:email
                                                                              alias:StringValue(object[@"alias"]) ?: @""
                                                                        accountName:StringValue(object[@"account_name"])
                                                                               plan:StringValue(object[@"plan"])
                                                                           authMode:StringValue(object[@"auth_mode"])
                                                                          createdAt:DateFromSeconds(object[@"created_at"]) ?: NSDate.date
                                                                         lastUsedAt:DateFromSeconds(object[@"last_used_at"])
                                                                          lastUsage:lastUsage
                                                                        lastUsageAt:lastUsageAt
                                                                   lastLocalRollout:object[@"last_local_rollout"]];
        [accounts addObject:record];
    }

    return [[self alloc] initWithCodexHome:codexHome
                          activeAccountKey:StringValue(root[@"active_account_key"])
                  previousActiveAccountKey:StringValue(root[@"previous_active_account_key"])
                   activeAccountActivatedAt:DateFromMilliseconds(root[@"active_account_activated_at_ms"])
                            intervalSeconds:[NumberValue(root[@"interval_seconds"]) integerValue]
                                   accounts:accounts];
}

+ (NSString *)accountSnapshotFileNameForAccountKey:(NSString *)accountKey {
    NSString *fileKey = accountKey;
    if (KeyNeedsFilenameEncoding(accountKey)) {
        fileKey = Base64URLNoPad([accountKey dataUsingEncoding:NSUTF8StringEncoding]);
    }
    return [fileKey stringByAppendingString:@".auth.json"];
}

+ (NSString *)planLabel:(NSString *)plan {
    NSString *normalized = [plan.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if (!normalized) {
        return @"--";
    }
    if ([normalized isEqualToString:@"free"]) return @"Free";
    if ([normalized isEqualToString:@"plus"]) return @"Plus";
    if ([normalized isEqualToString:@"prolite"] || [normalized isEqualToString:@"pro_lite"]) return @"Pro Lite";
    if ([normalized isEqualToString:@"pro"]) return @"Pro";
    if ([normalized isEqualToString:@"team"] || [normalized isEqualToString:@"business"]) return @"Business";
    if ([normalized isEqualToString:@"enterprise"]) return @"Enterprise";
    if ([normalized isEqualToString:@"edu"]) return @"Edu";
    if ([normalized isEqualToString:@"unknown"]) return @"Unknown";
    return plan.length > 0 ? plan : @"--";
}

- (NSString *)registryPath {
    return [self.accountsDirectoryPath stringByAppendingPathComponent:@"registry.json"];
}

- (NSString *)accountsDirectoryPath {
    return [self.codexHome stringByAppendingPathComponent:@"accounts"];
}

- (NSString *)activeAuthPath {
    return [self.codexHome stringByAppendingPathComponent:@"auth.json"];
}

- (CodexAccountRecord *)activeAccount {
    return self.activeAccountKey ? [self accountForKey:self.activeAccountKey] : nil;
}

- (CodexAccountRecord *)accountForKey:(NSString *)accountKey {
    for (CodexAccountRecord *record in self.accounts) {
        if ([record.accountKey isEqualToString:accountKey]) {
            return record;
        }
    }
    return nil;
}

- (NSString *)snapshotPathForAccountKey:(NSString *)accountKey {
    return [self.accountsDirectoryPath stringByAppendingPathComponent:[CodexRegistry accountSnapshotFileNameForAccountKey:accountKey]];
}

- (CodexAuth *)authForAccountKey:(NSString *)accountKey error:(NSError **)error {
    NSString *path = [self snapshotPathForAccountKey:accountKey];
    CodexAuth *auth = [CodexAuth loadFromPath:path error:error];
    if (!auth && error && !*error) {
        *error = CodexBarError(CodexBarErrorMissingAccountSnapshot, [NSString stringWithFormat:@"Missing account snapshot at %@", path]);
    }
    return auth;
}

- (BOOL)updateUsage:(UsageSnapshot *)usage forAccountKey:(NSString *)accountKey {
    CodexAccountRecord *record = [self accountForKey:accountKey];
    if (!record) {
        return NO;
    }
    record.lastUsage = usage;
    record.lastUsageAt = usage.fetchedAt;
    if (usage.planType.length > 0) {
        record.plan = usage.planType;
    }
    return YES;
}

- (BOOL)switchToAccountKey:(NSString *)accountKey error:(NSError **)error {
    CodexAccountRecord *target = [self accountForKey:accountKey];
    if (!target) {
        if (error) {
            *error = CodexBarError(CodexBarErrorMissingRegistryAccount, [NSString stringWithFormat:@"Account not found: %@", accountKey]);
        }
        return NO;
    }
    if ([self.activeAccountKey isEqualToString:accountKey]) {
        return YES;
    }

    NSString *src = [self snapshotPathForAccountKey:accountKey];
    NSError *readError = nil;
    NSData *snapshotData = [NSData dataWithContentsOfFile:src options:0 error:&readError];
    if (!snapshotData) {
        if (error) {
            NSString *detail = readError.localizedDescription ?: @"unknown error";
            *error = CodexBarError(CodexBarErrorMissingAccountSnapshot, [NSString stringWithFormat:@"Unable to read account snapshot at %@: %@", src, detail]);
        }
        return NO;
    }

    if (!BackupAuthIfChanged(self.activeAuthPath, self.accountsDirectoryPath, snapshotData, error)) {
        return NO;
    }
    if (!WritePrivateData(snapshotData, self.activeAuthPath, error)) {
        return NO;
    }

    if (self.activeAccountKey.length > 0 && [self accountForKey:self.activeAccountKey]) {
        self.previousActiveAccountKey = self.activeAccountKey;
    } else {
        self.previousActiveAccountKey = nil;
    }
    self.activeAccountKey = accountKey;
    self.activeAccountActivatedAt = NSDate.date;
    target.lastUsedAt = NSDate.date;
    return [self saveWithError:error];
}

- (BOOL)saveWithError:(NSError **)error {
    EnsurePrivateDirectory(self.accountsDirectoryPath);
    NSMutableArray *accountsOut = [NSMutableArray arrayWithCapacity:self.accounts.count];
    for (CodexAccountRecord *record in self.accounts) {
        [accountsOut addObject:record.registryObject];
    }
    NSDictionary *root = @{
        @"schema_version": @4,
        @"active_account_key": ObjectOrNull(self.activeAccountKey),
        @"previous_active_account_key": ObjectOrNull(self.previousActiveAccountKey),
        @"active_account_activated_at_ms": ObjectOrNull(MillisecondsFromDate(self.activeAccountActivatedAt)),
        @"interval_seconds": @(self.intervalSeconds > 0 ? self.intervalSeconds : 60),
        @"accounts": accountsOut
    };
    NSJSONWritingOptions options = NSJSONWritingPrettyPrinted;
    if (@available(macOS 10.13, *)) {
        options |= NSJSONWritingSortedKeys;
    }
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:options error:&jsonError];
    if (!data) {
        if (error) {
            *error = CodexBarError(CodexBarErrorInvalidJSON, jsonError.localizedDescription ?: @"Unable to serialize registry");
        }
        return NO;
    }
    if (!BackupIfChanged(self.registryPath, data, error)) {
        return NO;
    }
    if (!WritePrivateData(data, self.registryPath, error)) {
        return NO;
    }
    return YES;
}

@end
