#import "AppDelegate.h"

#import "BranchNPM.h"
#import "BranchSDK.h"

#ifdef BRANCH_NPM
#import "Branch.h"
#else
#import <BranchSDK/Branch.h>
#endif

// Provides Ionic Capacitor compatibility
#import <Cordova/CDVPlugin.h>

@interface AppDelegate (BranchSDK)

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray * _Nullable))restorationHandler;

@end

@implementation AppDelegate (BranchSDK)

// Respond to URI scheme links
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
  [BranchSDK recordDeepLinkURL:url];
  // pass the url to the handle deep link call
  if (![[Branch getInstance] application:app openURL:url options:options]) {
    // do other deep link routing for the Facebook SDK, Pinterest SDK, etc
    NSMutableDictionary *notificationOptions = [options mutableCopy] ?: [NSMutableDictionary dictionary];
    notificationOptions[BranchSDKURLProcessedKey] = @YES;
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url userInfo:notificationOptions]];
    // send unhandled URL to notification
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:@"BSDKPostUnhandledURL" object:[url absoluteString]]];
  }
  return YES;
}

// Respond to Universal Links
- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray *restorableObjects))restorationHandler {
  [BranchSDK recordDeepLinkURL:userActivity.webpageURL];
  if (![[Branch getInstance] continueUserActivity:userActivity]) {
    // send unhandled URL to notification
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
      [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:@"BSDKPostUnhandledURL" object:[userActivity.webpageURL absoluteString]]];
    }
  }

  return YES;
}

// Respond to Push Notifications
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
  @try {
    id branchLink = userInfo[@"branch"];
    if ([branchLink isKindOfClass:[NSString class]]) {
      [BranchSDK recordDeepLinkURL:[NSURL URLWithString:branchLink]];
    }
    [[Branch getInstance] handlePushNotification:userInfo];
  }
  @catch (NSException *exception) {
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:@"BSDKPostUnhandledURL" object:userInfo]];
  }
}

@end
