#import "BranchNPM.h"

#ifdef BRANCH_NPM
#import "Branch.h"
#import "BranchEvent.h"
#import "BranchQRCode.h"
#import "BranchLinkProperties.h"
#import "BranchUniversalObject.h"
#else
#import <BranchSDK/Branch.h>
#import <BranchSDK/BranchEvent.h>
#import <BranchSDK/BranchQRCode.h>
#import <BranchSDK/BranchLinkProperties.h>
#import <BranchSDK/BranchUniversalObject.h>
#endif

#import <Cordova/CDV.h>

FOUNDATION_EXPORT NSString * const BranchSDKURLProcessedKey;
FOUNDATION_EXPORT NSString * const BranchSDKLinkOpenedNotification;

@interface BranchSDK : CDVPlugin

@property (copy) NSString *canonicalIdentifier;
@property (copy) NSString *title;
@property (copy) NSString *contentDescription;
@property (copy) NSString *imageUrl;
@property (copy) NSString *type;
@property (copy) NSArray *keywords;
@property (copy) NSDictionary *metadata;
@property (copy) NSDate *expirationDate;

@property (strong, nonatomic) NSMutableArray *branchUniversalObjArray;

// Retain incoming URLs even when the app delegate runs before plugin initialization.
+ (void)recordDeepLinkURL:(NSURL *)url;
+ (void)recordNativeDeepLinkURL:(NSURL *)url;
+ (BOOL)routeNativeLinkURL:(NSURL *)url;
+ (BOOL)nativeLinkHandlingEnabled;
// Notify an initialized WebView when a URL is opened through the native delegate.
+ (void)notifyLinkOpened:(NSURL *)url;

// BranchSDK Basic Methods
- (void)enableTestMode:(CDVInvokedUrlCommand*)command;
- (void)initSession:(CDVInvokedUrlCommand*)command;
- (void)setNativeLinkHandling:(CDVInvokedUrlCommand *)command;
- (void)disableTracking:(CDVInvokedUrlCommand*)command;
- (void)enableLogging:(CDVInvokedUrlCommand*)command;
- (void)getAutoInstance:(CDVInvokedUrlCommand*)command;
- (void)getLatestReferringParams:(CDVInvokedUrlCommand*)command;
- (void)getFirstReferringParams:(CDVInvokedUrlCommand*)command;
- (void)setIdentity:(CDVInvokedUrlCommand*)command;
- (void)registerDeepLinkController:(CDVInvokedUrlCommand*)command;
- (void)logout:(CDVInvokedUrlCommand*)command;
- (void)setDMAParamsForEEA:(CDVInvokedUrlCommand*)command;
- (void)setConsumerProtectionAttributionLevel:(CDVInvokedUrlCommand*)command;

// Branch Universal Object Methods
- (void)createBranchUniversalObject:(CDVInvokedUrlCommand*)command;
- (void)registerView:(CDVInvokedUrlCommand*)command;
- (void)generateShortUrl:(CDVInvokedUrlCommand*)command;
- (void)showShareSheet:(CDVInvokedUrlCommand*)command;
- (void)onShareLinkDialogDismissed:(CDVInvokedUrlCommand*)command;
- (void)onLinkShareResponse:(CDVInvokedUrlCommand*)command;
- (void)listOnSpotlight:(CDVInvokedUrlCommand*)command;

// Branch Query Methods
- (void)lastAttributedTouchData:(CDVInvokedUrlCommand *)command;

// Resolve the latest received link again, or an optional URL supplied by JavaScript.
- (void)forceNewSession:(CDVInvokedUrlCommand *)command;



@end
