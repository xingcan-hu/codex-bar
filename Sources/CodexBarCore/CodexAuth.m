#import "CodexAuth.h"

NSString *const CodexBarErrorDomain = @"CodexBarErrorDomain";

NSError *CodexBarError(CodexBarErrorCode code, NSString *message) {
    return [NSError errorWithDomain:CodexBarErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *TrimmedNonEmpty(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }

    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length == 0 ? nil : trimmed;
}

static NSData *Base64URLDecode(NSString *value) {
    NSString *base64 = [[value stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger padding = base64.length % 4;
    if (padding > 0) {
        base64 = [base64 stringByPaddingToLength:base64.length + (4 - padding)
                                      withString:@"="
                                 startingAtIndex:0];
    }
    return [[NSData alloc] initWithBase64EncodedString:base64 options:0];
}

static NSString *EmailFromIDToken(NSString *idToken) {
    NSArray<NSString *> *parts = [idToken componentsSeparatedByString:@"."];
    if (parts.count < 2) {
        return nil;
    }

    NSData *payloadData = Base64URLDecode(parts[1]);
    if (!payloadData) {
        return nil;
    }

    id payload = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil];
    if (![payload isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    NSString *email = TrimmedNonEmpty(((NSDictionary *)payload)[@"email"]);
    return email;
}

@implementation CodexAuth

- (instancetype)initWithAccessToken:(NSString *)accessToken
                          accountID:(NSString *)accountID
                       accountEmail:(NSString *)accountEmail
                           authMode:(NSString *)authMode
                         sourcePath:(NSString *)sourcePath {
    self = [super init];
    if (self) {
        _accessToken = [accessToken copy];
        _accountID = [accountID copy];
        _accountEmail = [accountEmail copy];
        _authMode = [authMode copy];
        _sourcePath = [sourcePath copy];
    }
    return self;
}

+ (NSString *)defaultAuthPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".codex/auth.json"];
}

+ (instancetype)loadDefaultWithError:(NSError **)error {
    return [self loadFromPath:self.defaultAuthPath error:error];
}

+ (instancetype)loadFromPath:(NSString *)path error:(NSError **)error {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data) {
        if (error) {
            NSString *detail = readError.localizedDescription ?: @"unknown error";
            *error = CodexBarError(CodexBarErrorReadFailed, [NSString stringWithFormat:@"Unable to read auth file at %@: %@", path, detail]);
        }
        return nil;
    }

    return [self parseData:data sourcePath:path error:error];
}

+ (instancetype)parseData:(NSData *)data sourcePath:(NSString *)sourcePath error:(NSError **)error {
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![object isKindOfClass:NSDictionary.class]) {
        if (error) {
            NSString *detail = jsonError.localizedDescription ?: @"root value is not an object";
            *error = CodexBarError(CodexBarErrorInvalidJSON, [NSString stringWithFormat:@"Invalid auth.json: %@", detail]);
        }
        return nil;
    }

    NSDictionary *root = (NSDictionary *)object;
    NSString *authMode = TrimmedNonEmpty(root[@"auth_mode"]);
    NSString *apiKey = TrimmedNonEmpty(root[@"OPENAI_API_KEY"]);
    if ([authMode isEqualToString:@"apikey"] || apiKey.length > 0) {
        if (error) {
            *error = CodexBarError(CodexBarErrorUnsupportedAPIKeyAuth, @"auth.json uses API key auth; Codex Bar only supports ChatGPT auth tokens");
        }
        return nil;
    }

    id tokensValue = root[@"tokens"];
    NSDictionary *tokens = [tokensValue isKindOfClass:NSDictionary.class] ? (NSDictionary *)tokensValue : nil;

    NSString *accessToken = TrimmedNonEmpty(tokens[@"access_token"]);
    if (!accessToken) {
        if (error) {
            *error = CodexBarError(CodexBarErrorMissingAccessToken, @"auth.json is missing tokens.access_token");
        }
        return nil;
    }

    NSString *accountID = TrimmedNonEmpty(tokens[@"account_id"]);
    if (!accountID) {
        if (error) {
            *error = CodexBarError(CodexBarErrorMissingAccountID, @"auth.json is missing tokens.account_id");
        }
        return nil;
    }

    NSString *accountEmail = EmailFromIDToken(TrimmedNonEmpty(tokens[@"id_token"]));
    return [[self alloc] initWithAccessToken:accessToken
                                   accountID:accountID
                                accountEmail:accountEmail
                                    authMode:authMode
                                  sourcePath:sourcePath];
}

- (NSString *)accountDisplayName {
    if (self.accountEmail.length > 0) {
        return self.accountEmail;
    }

    if (self.accountID.length <= 8) {
        return self.accountID;
    }

    return [NSString stringWithFormat:@"...%@", [self.accountID substringFromIndex:self.accountID.length - 8]];
}

@end
