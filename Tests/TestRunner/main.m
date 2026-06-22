#import <Foundation/Foundation.h>
#import "CodexAuth.h"
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

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        TestParsesCodexAuthFile();
        puts("PASS parses Codex auth file");
        TestRejectsAPIKeyAuth();
        puts("PASS rejects API key auth");
        TestRequiresAccessToken();
        puts("PASS requires access token");
        TestParsesUsageResponse();
        puts("PASS parses usage response");
        TestRejectsResponseWithoutRateLimits();
        puts("PASS rejects usage response without rate limits");
        puts("All tests passed.");
    }
    return 0;
}
