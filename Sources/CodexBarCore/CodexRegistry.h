#import <Foundation/Foundation.h>

@class CodexAuth;
@class UsageSnapshot;
@class RateLimitWindow;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *CodexRelativeTimeString(NSDate *_Nullable date, NSDate *now);

@interface CodexAccountRecord : NSObject

@property (nonatomic, copy, readonly) NSString *accountKey;
@property (nonatomic, copy, readonly) NSString *chatGPTAccountID;
@property (nonatomic, copy, readonly) NSString *chatGPTUserID;
@property (nonatomic, copy, readonly) NSString *email;
@property (nonatomic, copy, readonly) NSString *alias;
@property (nonatomic, copy, nullable, readonly) NSString *accountName;
@property (nonatomic, copy, nullable) NSString *plan;
@property (nonatomic, copy, nullable, readonly) NSString *authMode;
@property (nonatomic, strong, readonly) NSDate *createdAt;
@property (nonatomic, strong, nullable) NSDate *lastUsedAt;
@property (nonatomic, strong, nullable) UsageSnapshot *lastUsage;
@property (nonatomic, strong, nullable) NSDate *lastUsageAt;
@property (nonatomic, strong, nullable, readonly) id lastLocalRollout;

- (instancetype)initWithAccountKey:(NSString *)accountKey
                   chatGPTAccountID:(NSString *)chatGPTAccountID
                      chatGPTUserID:(NSString *)chatGPTUserID
                              email:(NSString *)email
                              alias:(NSString *)alias
                        accountName:(nullable NSString *)accountName
                               plan:(nullable NSString *)plan
                           authMode:(nullable NSString *)authMode
                          createdAt:(NSDate *)createdAt
                         lastUsedAt:(nullable NSDate *)lastUsedAt
                          lastUsage:(nullable UsageSnapshot *)lastUsage
                        lastUsageAt:(nullable NSDate *)lastUsageAt
                   lastLocalRollout:(nullable id)lastLocalRollout NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSString *)identityDisplayName;
- (NSString *)displayPlan;
- (NSDictionary *)registryObject;

@end

@interface CodexRegistry : NSObject

@property (nonatomic, copy, readonly) NSString *codexHome;
@property (nonatomic, copy, nullable) NSString *activeAccountKey;
@property (nonatomic, copy, nullable) NSString *previousActiveAccountKey;
@property (nonatomic, strong, nullable) NSDate *activeAccountActivatedAt;
@property (nonatomic) NSInteger intervalSeconds;
@property (nonatomic, strong, readonly) NSMutableArray<CodexAccountRecord *> *accounts;

- (instancetype)initWithCodexHome:(NSString *)codexHome
                  activeAccountKey:(nullable NSString *)activeAccountKey
          previousActiveAccountKey:(nullable NSString *)previousActiveAccountKey
           activeAccountActivatedAt:(nullable NSDate *)activeAccountActivatedAt
                    intervalSeconds:(NSInteger)intervalSeconds
                           accounts:(NSArray<CodexAccountRecord *> *)accounts NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (NSString *)defaultCodexHome;
+ (nullable instancetype)loadDefaultWithError:(NSError **)error;
+ (nullable instancetype)loadFromCodexHome:(NSString *)codexHome error:(NSError **)error;
+ (NSString *)accountSnapshotFileNameForAccountKey:(NSString *)accountKey;
+ (NSString *)planLabel:(nullable NSString *)plan;

- (NSString *)registryPath;
- (NSString *)accountsDirectoryPath;
- (NSString *)activeAuthPath;
- (nullable CodexAccountRecord *)activeAccount;
- (nullable CodexAccountRecord *)accountForKey:(NSString *)accountKey;
- (NSString *)snapshotPathForAccountKey:(NSString *)accountKey;
- (nullable CodexAuth *)authForAccountKey:(NSString *)accountKey error:(NSError **)error;
- (BOOL)updateUsage:(UsageSnapshot *)usage forAccountKey:(NSString *)accountKey;
- (BOOL)switchToAccountKey:(NSString *)accountKey error:(NSError **)error;
- (BOOL)saveWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
