#import <Foundation/Foundation.h>
#import "CodexAuth.h"
#import "CodexRegistry.h"
#import "UsageSnapshot.h"
#import <math.h>

static void Fail(NSString *message) {
    fprintf(stderr, "FAIL %s\n", message.UTF8String);
    exit(1);
}

static void Expect(BOOL condition, NSString *message) {
    if (!condition) {
        Fail(message);
    }
}

static void ExpectEqualObjects(id actual, id expected, NSString *message) {
    if (actual == expected) {
        return;
    }
    if ([actual isEqual:expected]) {
        return;
    }
    Fail([NSString stringWithFormat:@"%@: expected %@, got %@", message, expected, actual]);
}

static void ExpectNear(double actual, double expected, NSString *message) {
    if (fabs(actual - expected) > 0.0001) {
        Fail([NSString stringWithFormat:@"%@: expected %.4f, got %.4f", message, expected, actual]);
    }
}

static NSData *DataFromString(NSString *string) {
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *Base64URLNoPad(NSString *string) {
    NSString *base64 = [DataFromString(string) base64EncodedStringWithOptions:0];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    while ([base64 hasSuffix:@"="]) {
        base64 = [base64 substringToIndex:base64.length - 1];
    }
    return base64;
}

static NSString *IDToken(NSString *email, NSString *userID, NSString *accountID, NSString *plan) {
    NSString *header = @"{\"alg\":\"none\",\"typ\":\"JWT\"}";
    NSString *payload = [NSString stringWithFormat:
        @"{\"email\":\"%@\",\"https://api.openai.com/auth\":{\"chatgpt_user_id\":\"%@\",\"chatgpt_account_id\":\"%@\",\"chatgpt_plan_type\":\"%@\"}}",
        email,
        userID,
        accountID,
        plan
    ];
    return [NSString stringWithFormat:@"%@.%@.sig", Base64URLNoPad(header), Base64URLNoPad(payload)];
}

static NSString *AuthJSON(NSString *email, NSString *userID, NSString *accountID, NSString *plan, NSString *accessToken) {
    return [NSString stringWithFormat:
        @"{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"%@\",\"account_id\":\"%@\",\"id_token\":\"%@\"}}",
        accessToken,
        accountID,
        IDToken(email, userID, accountID, plan)
    ];
}

static NSString *TempDirectory(void) {
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"codex-bar-tests.XXXXXX"];
    const char *templateCString = template.fileSystemRepresentation;
    char *buffer = strdup(templateCString);
    if (!mkdtemp(buffer)) {
        Fail(@"mkdtemp failed");
    }
    NSString *path = [NSFileManager.defaultManager stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
    free(buffer);
    return path;
}

static void TestParsesCodexAuthFile(void) {
    NSString *json = @"{"
        "\"auth_mode\":\"chatgpt\","
        "\"tokens\":{"
            "\"access_token\":\" access-token \","
            "\"account_id\":\" account-id \","
            "\"id_token\":\"header.eyJlbWFpbCI6InVzZXJAZXhhbXBsZS5jb20ifQ.signature\""
        "},"
        "\"last_refresh\":\"2026-06-22T00:00:00Z\""
    "}";

    NSError *error = nil;
    CodexAuth *auth = [CodexAuth parseData:DataFromString(json) sourcePath:nil error:&error];
    Expect(auth != nil, [NSString stringWithFormat:@"auth parse failed: %@", error]);
    ExpectEqualObjects(auth.authMode, @"chatgpt", @"auth mode");
    ExpectEqualObjects(auth.accessToken, @"access-token", @"access token");
    ExpectEqualObjects(auth.accountID, @"account-id", @"account id");
    ExpectEqualObjects(auth.accountEmail, @"user@example.com", @"account email");
    ExpectEqualObjects(auth.accountDisplayName, @"user@example.com", @"account display name");
}

static void TestParsesCodexAuthAccountKey(void) {
    NSString *json = AuthJSON(@"key@example.com", @"user-key", @"acct-key", @"prolite", @"access-key");
    NSError *error = nil;
    CodexAuth *auth = [CodexAuth parseData:DataFromString(json) sourcePath:nil error:&error];
    Expect(auth != nil, [NSString stringWithFormat:@"auth parse failed: %@", error]);
    ExpectEqualObjects(auth.accountEmail, @"key@example.com", @"auth account email");
    ExpectEqualObjects(auth.chatGPTAccountID, @"acct-key", @"chatgpt account id");
    ExpectEqualObjects(auth.chatGPTUserID, @"user-key", @"chatgpt user id");
    ExpectEqualObjects(auth.planType, @"prolite", @"auth plan");
    ExpectEqualObjects(auth.accountKey, @"user-key::acct-key", @"auth account key");
}

static void TestRejectsAPIKeyAuth(void) {
    NSString *json = @"{"
        "\"auth_mode\":\"apikey\","
        "\"OPENAI_API_KEY\":\"sk-test\""
    "}";

    NSError *error = nil;
    CodexAuth *auth = [CodexAuth parseData:DataFromString(json) sourcePath:nil error:&error];
    Expect(auth == nil, @"API key auth should fail");
    Expect(error.code == CodexBarErrorUnsupportedAPIKeyAuth, @"API key auth wrong error");
}

static void TestRequiresAccessToken(void) {
    NSString *json = @"{"
        "\"auth_mode\":\"chatgpt\","
        "\"tokens\":{\"account_id\":\"account-id\"}"
    "}";

    NSError *error = nil;
    CodexAuth *auth = [CodexAuth parseData:DataFromString(json) sourcePath:nil error:&error];
    Expect(auth == nil, @"missing token should fail");
    Expect(error.code == CodexBarErrorMissingAccessToken, @"missing token wrong error");
}

static void TestParsesUsageResponse(void) {
    NSString *json = @"{"
        "\"plan_type\":\"plus\","
        "\"credits\":{"
            "\"has_credits\":true,"
            "\"unlimited\":false,"
            "\"balance\":\"12.34\""
        "},"
        "\"rate_limit\":{"
            "\"primary_window\":{"
                "\"used_percent\":31.5,"
                "\"limit_window_seconds\":18000,"
                "\"reset_at\":1782090000"
            "},"
            "\"secondary_window\":{"
                "\"used_percent\":45,"
                "\"limit_window_seconds\":604800,"
                "\"reset_at\":1782608400"
            "}"
        "}"
    "}";

    NSDate *fetchedAt = [NSDate dateWithTimeIntervalSince1970:1782000000];
    NSError *error = nil;
    UsageSnapshot *snapshot = [UsageSnapshot parseData:DataFromString(json) fetchedAt:fetchedAt error:&error];
    Expect(snapshot != nil, [NSString stringWithFormat:@"usage parse failed: %@", error]);
    ExpectEqualObjects(snapshot.planType, @"plus", @"plan type");
    ExpectNear(snapshot.primary.usedPercent, 31.5, @"primary used");
    ExpectNear(snapshot.primary.remainingPercent, 68.5, @"primary remaining");
    ExpectEqualObjects(snapshot.primary.windowMinutes, @300, @"primary window minutes");
    ExpectNear(snapshot.secondary.remainingPercent, 55.0, @"secondary remaining");
    ExpectNear(snapshot.remainingPercent.doubleValue, 55.0, @"limiting remaining");
    ExpectEqualObjects(snapshot.credits.balance, @"12.34", @"credit balance");
    ExpectEqualObjects(snapshot.fetchedAt, fetchedAt, @"fetched at");
}

static void TestRejectsResponseWithoutRateLimits(void) {
    NSString *json = @"{"
        "\"plan_type\":\"plus\","
        "\"rate_limit\":{}"
    "}";

    NSError *error = nil;
    UsageSnapshot *snapshot = [UsageSnapshot parseData:DataFromString(json) fetchedAt:NSDate.date error:&error];
    Expect(snapshot == nil, @"missing rate limits should fail");
    Expect(error.code == CodexBarErrorMissingRateLimit, @"missing rate limits wrong error");
}

static void TestRegistrySnapshotFileNames(void) {
    ExpectEqualObjects([CodexRegistry accountSnapshotFileNameForAccountKey:@"safe-KEY_123.ok"], @"safe-KEY_123.ok.auth.json", @"safe snapshot filename");
    NSString *encoded = [CodexRegistry accountSnapshotFileNameForAccountKey:@"user-key::acct-key"];
    Expect([encoded hasSuffix:@".auth.json"], @"encoded snapshot suffix");
    Expect([encoded rangeOfString:@":"].location == NSNotFound, @"encoded snapshot should not contain colon");
}

static void TestParsesRegistry(void) {
    NSString *tmp = TempDirectory();
    NSString *accounts = [tmp stringByAppendingPathComponent:@"accounts"];
    [NSFileManager.defaultManager createDirectoryAtPath:accounts withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *registryJSON = @"{"
        "\"schema_version\":4,"
        "\"active_account_key\":\"user-a::acct-a\","
        "\"previous_active_account_key\":null,"
        "\"active_account_activated_at_ms\":1782094780398,"
        "\"interval_seconds\":60,"
        "\"accounts\":[{"
            "\"account_key\":\"user-a::acct-a\","
            "\"chatgpt_account_id\":\"acct-a\","
            "\"chatgpt_user_id\":\"user-a\","
            "\"email\":\"a@example.com\","
            "\"alias\":\"work\","
            "\"account_name\":null,"
            "\"plan\":\"prolite\","
            "\"auth_mode\":\"chatgpt\","
            "\"created_at\":1,"
            "\"last_used_at\":2,"
            "\"last_usage\":{"
                "\"primary\":{\"used_percent\":20,\"window_minutes\":300,\"resets_at\":1782100000},"
                "\"secondary\":{\"used_percent\":35,\"window_minutes\":10080,\"resets_at\":1782600000},"
                "\"credits\":{\"has_credits\":false,\"unlimited\":false,\"balance\":\"0\"},"
                "\"plan_type\":\"prolite\""
            "},"
            "\"last_usage_at\":1782096985,"
            "\"last_local_rollout\":null"
        "}]"
    "}";
    NSString *registryPath = [accounts stringByAppendingPathComponent:@"registry.json"];
    [registryJSON writeToFile:registryPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSError *error = nil;
    CodexRegistry *registry = [CodexRegistry loadFromCodexHome:tmp error:&error];
    Expect(registry != nil, [NSString stringWithFormat:@"registry parse failed: %@", error]);
    ExpectEqualObjects(registry.activeAccountKey, @"user-a::acct-a", @"active account key");
    ExpectEqualObjects(@(registry.accounts.count), @1, @"registry account count");
    CodexAccountRecord *record = registry.accounts.firstObject;
    ExpectEqualObjects(record.identityDisplayName, @"work(a@example.com)", @"identity label");
    ExpectEqualObjects(record.displayPlan, @"Pro Lite", @"display plan");
    ExpectNear(record.lastUsage.primary.remainingPercent, 80, @"registry primary remaining");
    ExpectNear(record.lastUsage.secondary.remainingPercent, 65, @"registry secondary remaining");
}

static void TestRelativeTimeString(void) {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:200000];
    ExpectEqualObjects(CodexRelativeTimeString(nil, now), @"Never", @"relative never");
    ExpectEqualObjects(CodexRelativeTimeString([NSDate dateWithTimeIntervalSince1970:199980], now), @"Now", @"relative now");
    ExpectEqualObjects(CodexRelativeTimeString([NSDate dateWithTimeIntervalSince1970:199700], now), @"5m ago", @"relative minutes");
    ExpectEqualObjects(CodexRelativeTimeString([NSDate dateWithTimeIntervalSince1970:192800], now), @"2h ago", @"relative hours");
    ExpectEqualObjects(CodexRelativeTimeString([NSDate dateWithTimeIntervalSince1970:27200], now), @"2d ago", @"relative days");
}

static void TestSwitchAccount(void) {
    NSString *tmp = TempDirectory();
    NSString *accounts = [tmp stringByAppendingPathComponent:@"accounts"];
    [NSFileManager.defaultManager createDirectoryAtPath:accounts withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *keyA = @"user-a::acct-a";
    NSString *keyB = @"user-b::acct-b";
    NSString *authA = AuthJSON(@"a@example.com", @"user-a", @"acct-a", @"plus", @"access-a");
    NSString *authB = AuthJSON(@"b@example.com", @"user-b", @"acct-b", @"prolite", @"access-b");
    [authA writeToFile:[tmp stringByAppendingPathComponent:@"auth.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [authA writeToFile:[accounts stringByAppendingPathComponent:[CodexRegistry accountSnapshotFileNameForAccountKey:keyA]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [authB writeToFile:[accounts stringByAppendingPathComponent:[CodexRegistry accountSnapshotFileNameForAccountKey:keyB]] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *registryJSON = [NSString stringWithFormat:
        @"{\"schema_version\":4,\"active_account_key\":\"%@\",\"previous_active_account_key\":null,\"active_account_activated_at_ms\":1,\"interval_seconds\":60,\"accounts\":["
        "{\"account_key\":\"%@\",\"chatgpt_account_id\":\"acct-a\",\"chatgpt_user_id\":\"user-a\",\"email\":\"a@example.com\",\"alias\":\"\",\"account_name\":null,\"plan\":\"plus\",\"auth_mode\":\"chatgpt\",\"created_at\":1,\"last_used_at\":null,\"last_usage\":null,\"last_usage_at\":null,\"last_local_rollout\":null},"
        "{\"account_key\":\"%@\",\"chatgpt_account_id\":\"acct-b\",\"chatgpt_user_id\":\"user-b\",\"email\":\"b@example.com\",\"alias\":\"\",\"account_name\":null,\"plan\":\"prolite\",\"auth_mode\":\"chatgpt\",\"created_at\":1,\"last_used_at\":null,\"last_usage\":null,\"last_usage_at\":null,\"last_local_rollout\":null}"
        "]}",
        keyA,
        keyA,
        keyB
    ];
    [registryJSON writeToFile:[accounts stringByAppendingPathComponent:@"registry.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSError *error = nil;
    CodexRegistry *registry = [CodexRegistry loadFromCodexHome:tmp error:&error];
    Expect(registry != nil, [NSString stringWithFormat:@"registry load failed: %@", error]);
    Expect([registry switchToAccountKey:keyB error:&error], [NSString stringWithFormat:@"switch failed: %@", error]);
    ExpectEqualObjects(registry.activeAccountKey, keyB, @"switch active key");
    ExpectEqualObjects(registry.previousActiveAccountKey, keyA, @"switch previous key");
    NSString *activeAuth = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"auth.json"] encoding:NSUTF8StringEncoding error:nil];
    Expect([activeAuth rangeOfString:@"access-b"].location != NSNotFound, @"active auth should contain switched token");
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:accounts error:nil];
    NSPredicate *backupPredicate = [NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        (void)bindings;
        return [name hasPrefix:@"auth.json.bak."];
    }];
    Expect([files filteredArrayUsingPredicate:backupPredicate].count == 1, @"auth backup should be created");
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        TestParsesCodexAuthFile();
        puts("PASS parses Codex auth file");
        TestParsesCodexAuthAccountKey();
        puts("PASS parses Codex auth account key");
        TestRejectsAPIKeyAuth();
        puts("PASS rejects API key auth");
        TestRequiresAccessToken();
        puts("PASS requires access token");
        TestParsesUsageResponse();
        puts("PASS parses usage response");
        TestRejectsResponseWithoutRateLimits();
        puts("PASS rejects usage response without rate limits");
        TestRegistrySnapshotFileNames();
        puts("PASS registry snapshot filenames");
        TestParsesRegistry();
        puts("PASS parses registry");
        TestRelativeTimeString();
        puts("PASS relative time string");
        TestSwitchAccount();
        puts("PASS switches account");
        puts("All tests passed.");
    }
    return 0;
}
