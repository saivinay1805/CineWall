#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <bsm/libbsm.h>
#import <objc/runtime.h>

@interface CAContext : NSObject
@property(nonatomic, readonly) unsigned int contextId;
@property(nonatomic, retain) CALayer *layer;
- (void)invalidate;
+ (id)remoteContextWithOptions:(NSDictionary *)options;
@end

@interface NSXPCConnection (WallpaperCallerIdentity)
@property(nonatomic, readonly) audit_token_t auditToken;
@end

@protocol WallpaperExtensionXPCProtocol <NSObject>
- (void)acquireWithId:(id)identifier request:(id)request reply:(void (^)(id, NSError *))reply;
- (void)updateWithId:(id)identifier request:(id)request reply:(void (^)(NSError *))reply;
- (void)invalidateWithId:(id)identifier reply:(void (^)(NSError *))reply;
- (void)snapshotWithId:(id)identifier reply:(void (^)(id, NSError *))reply;
- (void)provideSettingsViewModelsWithContentTypes:(id)types reply:(void (^)(id, NSError *))reply;
- (void)isChoiceDownloadedWith:(id)choiceID reply:(void (^)(id, NSError *))reply;
- (void)selectedChoicesDidChangeFor:(id)identifier reply:(void (^)(NSError *))reply;
- (void)migrateSelectedChoiceFor:(id)choiceID reply:(void (^)(id, NSError *))reply;
- (void)addChoiceRequestWithChoiceRequest:(id)choiceRequest onBehalfOfProcess:(id)process reply:(void (^)(id, NSError *))reply;
- (void)canSkipShuffledContentWithId:(id)identifier reply:(void (^)(BOOL, NSError *))reply;
- (void)skipShuffledContentWithId:(id)identifier reply:(void (^)(NSError *))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id)choiceRequest reply:(void (^)(NSError *))reply;
- (NSProgress *)downloadWithChoiceID:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)cancelDownloadFor:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)pauseDownloadFor:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)resumeDownloadFor:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)removeDownloadFor:(id)choiceID reply:(void (^)(NSError *))reply;
- (void)invokeContextMenuActionWithMenuItemID:(NSString *)itemID groupItemID:(NSString *)groupItemID reply:(void (^)(NSError *))reply;
- (void)migrateFrom:(id)from to:(id)to reply:(void (^)(NSError *))reply;
- (void)handleDebugRequestFor:(id)request reply:(void (^)(id, NSError *))reply;
- (void)handleNotificationWithNamed:(NSString *)name reply:(void (^)(NSError *))reply;
@end
