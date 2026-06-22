#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const CodexBarErrorDomain;

typedef NS_ENUM(NSInteger, CodexBarErrorCode) {
    CodexBarErrorReadFailed = 1,
    CodexBarErrorInvalidJSON = 2,
    CodexBarErrorUnsupportedAPIKeyAuth = 3,
    CodexBarErrorMissingAccessToken = 4,
    CodexBarErrorMissingAccountID = 5,
    CodexBarErrorInvalidUsageResponse = 6,
    CodexBarErrorMissingRateLimit = 7,
    CodexBarErrorInvalidHTTPResponse = 8,
    CodexBarErrorHTTPStatus = 9
};

@interface CodexAuth : NSObject

@property (nonatomic, copy, readonly) NSString *accessToken;
@property (nonatomic, copy, readonly) NSString *accountID;
@property (nonatomic, copy, nullable, readonly) NSString *accountEmail;
@property (nonatomic, copy, nullable, readonly) NSString *authMode;
@property (nonatomic, copy, nullable, readonly) NSString *sourcePath;

- (instancetype)initWithAccessToken:(NSString *)accessToken
                          accountID:(NSString *)accountID
                       accountEmail:(nullable NSString *)accountEmail
                           authMode:(nullable NSString *)authMode
                         sourcePath:(nullable NSString *)sourcePath NS_DESIGNATED_INITIALIZER;

- (NSString *)accountDisplayName;

- (instancetype)init NS_UNAVAILABLE;

+ (NSString *)defaultAuthPath;
+ (nullable instancetype)loadDefaultWithError:(NSError **)error;
+ (nullable instancetype)loadFromPath:(NSString *)path error:(NSError **)error;
+ (nullable instancetype)parseData:(NSData *)data sourcePath:(nullable NSString *)sourcePath error:(NSError **)error;

@end

NSError *CodexBarError(CodexBarErrorCode code, NSString *message);

NS_ASSUME_NONNULL_END
