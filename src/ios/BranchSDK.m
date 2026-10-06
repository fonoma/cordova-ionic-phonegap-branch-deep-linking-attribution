#import "BranchSDK.h"
#import <dispatch/dispatch.h>
#include <math.h>

NSString * const pluginVersion = @"%BRANCH_PLUGIN_VERSION%";
NSString * const BranchSDKURLProcessedKey = @"BranchSDKURLProcessed";
static NSURL *lastDeepLinkURL;

@interface BranchSDK()

@property (strong, nonatomic) NSMutableArray *sessionRequests;
@property (copy, nonatomic) NSString *activeSessionRequestIdentifier;
@property (strong, nonatomic) dispatch_source_t sessionRequestTimer;
@property (atomic, assign) NSUInteger sessionGeneration;
@property (atomic, assign) BOOL sessionsDisposed;

+ (NSURL *)lastDeepLinkURL;
- (void)enqueueSessionCommand:(CDVInvokedUrlCommand *)command forceNewSession:(BOOL)force url:(NSURL *)url;
- (void)processNextSessionRequest;
- (NSTimeInterval)sessionRequestTimeout;
- (void)startTaggedSessionWithURL:(NSURL *)url identifier:(NSString *)identifier;
- (void)finishSessionRequest:(NSString *)identifier params:(NSDictionary *)params error:(NSError *)error;
- (void)invalidateSessionRequests;

- (void)doShareLinkResponse:(int)callbackId sendResponse:(NSDictionary*)response;

@end

@implementation BranchSDK

- (void)pluginInitialize
{
  self.branchUniversalObjArray = [[NSMutableArray alloc] init];
  self.sessionRequests = [[NSMutableArray alloc] init];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleOpenURLNotification:) name:CDVPluginHandleOpenURLNotification object:nil];
}

- (void)onReset
{
  [self invalidateSessionRequests];
  [super onReset];
}

- (void)dispose
{
  self.sessionsDisposed = YES;
  [self invalidateSessionRequests];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [super dispose];
}

- (void)dealloc
{
  if (_sessionRequestTimer) {
    dispatch_source_cancel(_sessionRequestTimer);
  }
}

- (void)invalidateSessionRequests
{
  NSUInteger generation;
  @synchronized (self) {
    self.sessionGeneration += 1;
    generation = self.sessionGeneration;
  }
  void (^invalidate)(void) = ^{
    if (generation != self.sessionGeneration) {
      return;
    }
    BOOL hasCurrentRequest = self.activeSessionRequestIdentifier && self.sessionRequests.count > 0 &&
                             [self.sessionRequests[0][@"generation"] unsignedIntegerValue] == generation;
    if (!hasCurrentRequest) {
      if (self.sessionRequestTimer) {
        dispatch_source_cancel(self.sessionRequestTimer);
        self.sessionRequestTimer = nil;
      }
      self.activeSessionRequestIdentifier = nil;
    }
    for (NSUInteger index = self.sessionRequests.count; index > 0; index--) {
      if ([self.sessionRequests[index - 1][@"generation"] unsignedIntegerValue] != generation) {
        [self.sessionRequests removeObjectAtIndex:index - 1];
      }
    }
    [self processNextSessionRequest];
  };
  if ([NSThread isMainThread]) {
    invalidate();
  } else {
    dispatch_async(dispatch_get_main_queue(), invalidate);
  }
}

- (void)handleOpenURLNotification:(NSNotification*)notification
{
    NSURL *url = (NSURL *)notification.object;
    if (![url isKindOfClass:[NSURL class]]) {
        return;
    }

    [BranchSDK recordDeepLinkURL:url];
    NSDictionary *options = [notification.userInfo isKindOfClass:[NSDictionary class]] ? notification.userInfo : @{};
    if (![options[BranchSDKURLProcessedKey] boolValue]) {
        // Other Cordova integrations may post URLs without passing through our delegate.
        [[Branch getInstance] application:[UIApplication sharedApplication] openURL:url options:options];
    }
}

#pragma mark - Private APIs

+ (void)recordDeepLinkURL:(NSURL *)url
{
  if ([url isKindOfClass:[NSURL class]] && url.scheme.length > 0) {
    @synchronized ([BranchSDK class]) {
      lastDeepLinkURL = [url copy];
    }
  }
}

+ (NSURL *)lastDeepLinkURL
{
  @synchronized ([BranchSDK class]) {
    return lastDeepLinkURL;
  }
}

#pragma mark - Global Instance Accessors

- (Branch *)getInstance
{
  return [Branch getInstance];
}

- (Branch *)getInstance:(NSString *)branchKey
{
  if (branchKey) {
    return [Branch getInstance:branchKey];
  }
  else {
    return [Branch getInstance];
  }
}

- (Branch *)getTestInstance
{
  return [Branch getTestInstance];
}

#pragma mark - Deep Linking Handlers

- (id)handleDeepLink:(CDVInvokedUrlCommand*)command
{
  NSString *arg = [command.arguments objectAtIndex:0];
  NSURL *url = [NSURL URLWithString:arg];
  [BranchSDK recordDeepLinkURL:url];

  return [NSNumber numberWithBool:[[Branch getInstance] handleDeepLink:url]];
}

- (id)handleDeepLinkWithNewSession:(CDVInvokedUrlCommand*)command
{
  NSString *arg = [command.arguments objectAtIndex:0];
  NSURL *url = [NSURL URLWithString:arg];
  [BranchSDK recordDeepLinkURL:url];

  return [NSNumber numberWithBool:[[Branch getInstance] handleDeepLinkWithNewSession:url]];
}

- (void)continueUserActivity:(CDVInvokedUrlCommand*)command
{
    dispatch_async(dispatch_get_main_queue(), ^{

        NSString *activityType = nil;
        if (command.arguments.count > 0 && [command.arguments[0] isKindOfClass:[NSString class]]) {
            activityType = (NSString *)command.arguments[0];
        }

        NSDictionary *userInfo = nil;
        if (command.arguments.count > 1 && [command.arguments[1] isKindOfClass:[NSDictionary class]]) {
            userInfo = (NSDictionary *)command.arguments[1];
        }

        NSString *optionalURLString = nil;
        if (command.arguments.count > 2 && [command.arguments[2] isKindOfClass:[NSString class]]) {
            optionalURLString = (NSString *)command.arguments[2];
        }

        if (activityType.length == 0) {
            activityType = NSUserActivityTypeBrowsingWeb;
        }

        NSUserActivity *userActivity = [[NSUserActivity alloc] initWithActivityType:activityType];
        if (userInfo) {
            userActivity.userInfo = userInfo;
        }
        if ([activityType isEqualToString:NSUserActivityTypeBrowsingWeb] && optionalURLString.length > 0) {
            NSURL *webURL = [NSURL URLWithString:optionalURLString];
            if (webURL) {
                userActivity.webpageURL = webURL;
                [BranchSDK recordDeepLinkURL:webURL];
            }
        }
        [[Branch getInstance] continueUserActivity:userActivity];
    });
}


#pragma mark - Public APIs
#pragma mark - Branch Basic Methods

- (void)enableTestMode:(CDVInvokedUrlCommand*)command
{
  [Branch setUseTestBranchKey:TRUE];
}

- (void)initSession:(CDVInvokedUrlCommand*)command
{
  [self enqueueSessionCommand:command forceNewSession:NO url:nil];
}

- (void)forceNewSession:(CDVInvokedUrlCommand*)command
{
  NSURL *url = nil;
  if (command.arguments.count > 0) {
    id argument = command.arguments[0];
    if ([argument isKindOfClass:[NSString class]]) {
      url = [NSURL URLWithString:argument];
    }
    BOOL isWebURL = [url.scheme.lowercaseString isEqualToString:@"https"] ||
                    [url.scheme.lowercaseString isEqualToString:@"http"];
    if (url.scheme.length == 0 || (isWebURL && url.host.length == 0)) {
      CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                               messageAsString:@"Please provide a valid absolute URL"];
      [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
      return;
    }
  }
  [self enqueueSessionCommand:command forceNewSession:YES url:url];
}

#pragma mark - Session requests

- (void)enqueueSessionCommand:(CDVInvokedUrlCommand *)command forceNewSession:(BOOL)force url:(NSURL *)url
{
  NSUInteger generation = self.sessionGeneration;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.sessionsDisposed || generation != self.sessionGeneration) {
      return;
    }
    NSURL *requestURL = url;
    if (force) {
      if (requestURL) {
        [BranchSDK recordDeepLinkURL:requestURL];
      } else {
        requestURL = [BranchSDK lastDeepLinkURL];
      }
    }
    NSDictionary *request = @{
      @"command": command ?: [NSNull null],
      @"force": @(force),
      @"url": requestURL ?: [NSNull null],
      @"identifier": [NSUUID UUID].UUIDString,
      @"generation": @(generation)
    };
    [self.sessionRequests addObject:request];
    [self processNextSessionRequest];
  });
}

- (void)processNextSessionRequest
{
  if (self.sessionsDisposed || self.activeSessionRequestIdentifier || self.sessionRequests.count == 0) {
    return;
  }

  NSDictionary *request = self.sessionRequests[0];
  if ([request[@"generation"] unsignedIntegerValue] != self.sessionGeneration) {
    return;
  }
  NSString *requestIdentifier = request[@"identifier"];
  self.activeSessionRequestIdentifier = requestIdentifier;
  BOOL force = [request[@"force"] boolValue];
  NSURL *url = request[@"url"] == [NSNull null] ? nil : request[@"url"];
  Branch *branch = [Branch getInstance];
  [branch registerPluginName:@"CordovaIonic" version:pluginVersion];

  __weak BranchSDK *weakSelf = self;
  NSTimeInterval timeout = [self sessionRequestTimeout];
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  if (!timer) {
    NSError *error = [NSError errorWithDomain:@"BranchCordovaSDK" code:4
                                    userInfo:@{ NSLocalizedDescriptionKey: @"Unable to schedule this Branch session" }];
    [self finishSessionRequest:requestIdentifier params:nil error:error];
    return;
  }
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler(timer, ^{
    NSError *error = [NSError errorWithDomain:@"BranchCordovaSDK" code:1
                                    userInfo:@{ NSLocalizedDescriptionKey: @"Timed out waiting for Branch to resolve this session. You can call forceNewSession again." }];
    [weakSelf finishSessionRequest:requestIdentifier params:nil error:error];
  });
  self.sessionRequestTimer = timer;
  dispatch_resume(timer);

  // For forced calls, register without an automatic, untagged session first.
  // Branch checks the presence of this key; a URL-less force is triggered below.
  NSDictionary *launchOptions = force ? @{ UIApplicationLaunchOptionsURLKey: url ?: [NSNull null] } : @{};
  @try {
    // Release the SDK's plugin-runtime gate before installing this request's handler.
    [branch notifyNativeToInit];
    [branch initSceneSessionWithLaunchOptions:launchOptions
                              isReferrable:YES
             explicitlyRequestedReferrable:NO
            automaticallyDisplayController:NO
                   registerDeepLinkHandler:^(BNCInitSessionResponse *response, NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        BranchSDK *plugin = weakSelf;
        if (![plugin.activeSessionRequestIdentifier isEqualToString:requestIdentifier]) {
          return;
        }
        if (!response) {
          NSError *responseError = error ?: [NSError errorWithDomain:@"BranchCordovaSDK" code:2
                                                           userInfo:@{ NSLocalizedDescriptionKey: @"Branch returned an empty session response" }];
          [plugin finishSessionRequest:requestIdentifier params:nil error:responseError];
          return;
        }
        // Ordinary initSession receives the current SDK session; forced calls
        // must receive the response belonging to their own open.
        BOOL matchesRequest = !force || [response.sceneIdentifier isEqualToString:requestIdentifier];
        if (!matchesRequest) {
          if (force && !url) {
            // A URL-less open can be absorbed by an earlier pending SDK open.
            // Once it completes, retry our own tagged open using the same deadline.
            [plugin startTaggedSessionWithURL:nil identifier:requestIdentifier];
          }
          return;
        }
        [plugin finishSessionRequest:requestIdentifier params:response.params error:error];
      });
    }];

    if (force) {
      // This resets on every call, including repeated URLs and URL-less opens.
      // The BOOL reports recognition; both recognized and other URLs can callback.
      [self startTaggedSessionWithURL:url identifier:requestIdentifier];
    }
  }
  @catch (NSException *exception) {
    NSError *error = [NSError errorWithDomain:@"BranchCordovaSDK" code:3
                                    userInfo:@{ NSLocalizedDescriptionKey: exception.reason ?: @"Branch could not start this session" }];
    [self finishSessionRequest:requestIdentifier params:nil error:error];
  }
}

- (void)startTaggedSessionWithURL:(NSURL *)url identifier:(NSString *)identifier
{
  if (self.sessionsDisposed || ![self.activeSessionRequestIdentifier isEqualToString:identifier] || self.sessionRequests.count == 0 ||
      [self.sessionRequests[0][@"generation"] unsignedIntegerValue] != self.sessionGeneration) {
    return;
  }
  if (!url && [[BNCServerRequestQueue getInstance] findExistingInstallOrOpen]) {
    // A URL-less open would adopt the earlier request's callback. Wait until
    // it leaves the SDK queue before creating our own tagged session.
    __weak BranchSDK *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
      [weakSelf startTaggedSessionWithURL:nil identifier:identifier];
    });
    return;
  }
  @try {
    [[Branch getInstance] handleDeepLink:url sceneIdentifier:identifier];
  }
  @catch (NSException *exception) {
    NSError *error = [NSError errorWithDomain:@"BranchCordovaSDK" code:3
                                    userInfo:@{ NSLocalizedDescriptionKey: exception.reason ?: @"Branch could not start this session" }];
    [self finishSessionRequest:identifier params:nil error:error];
  }
}

- (NSTimeInterval)sessionRequestTimeout
{
  BNCPreferenceHelper *preferences = [BNCPreferenceHelper sharedInstance];
  NSTimeInterval networkTimeout = MAX(1.0, preferences.timeout);
  double retries = MAX(0, preferences.retryCount);
  NSTimeInterval retryInterval = MAX(0.0, preferences.retryInterval);
  NSTimeInterval requestBudget = (retries + 1.0) * networkTimeout + retries * retryInterval;
  // Allow an earlier SDK request plus our own retries and initialization work.
  NSTimeInterval timeout = 2.0 * requestBudget + 15.0;
  return isfinite(timeout) ? MAX(30.0, timeout) : 60.0;
}

- (void)finishSessionRequest:(NSString *)identifier params:(NSDictionary *)params error:(NSError *)error
{
  if (self.sessionsDisposed || ![self.activeSessionRequestIdentifier isEqualToString:identifier] || self.sessionRequests.count == 0 ||
      ![self.sessionRequests[0][@"identifier"] isEqualToString:identifier] ||
      [self.sessionRequests[0][@"generation"] unsignedIntegerValue] != self.sessionGeneration) {
    return;
  }

  NSDictionary *request = self.sessionRequests[0];
  CDVInvokedUrlCommand *command = request[@"command"] == [NSNull null] ? nil : request[@"command"];
  BOOL force = [request[@"force"] boolValue];
  if (self.sessionRequestTimer) {
    dispatch_source_cancel(self.sessionRequestTimer);
    self.sessionRequestTimer = nil;
  }
  [self.sessionRequests removeObjectAtIndex:0];
  self.activeSessionRequestIdentifier = nil;

  CDVPluginResult *result;
  if (error) {
    NSString *message = error.localizedDescription ?: @"Branch init session failed";
    if (!force) {
      // Preserve initSession's JSON error string for existing callers.
      NSData *json = [NSJSONSerialization dataWithJSONObject:@{ @"error": message } options:0 error:NULL];
      message = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    }
    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
  } else {
    NSDictionary *safeParams = [params isKindOfClass:[NSDictionary class]] ? params : @{};
    id referringLink = safeParams[@"~referring_link"];
    NSURL *referringURL = [referringLink isKindOfClass:[NSString class]] ? [NSURL URLWithString:referringLink] : nil;
    if (referringURL.scheme.length > 0) {
      if (![BranchSDK lastDeepLinkURL]) {
        [BranchSDK recordDeepLinkURL:referringURL];
      }
      // Calls queued before deferred-link resolution can now replay that link.
      for (NSUInteger index = 0; index < self.sessionRequests.count; index++) {
        NSDictionary *pending = self.sessionRequests[index];
        if ([pending[@"force"] boolValue] && pending[@"url"] == [NSNull null]) {
          NSMutableDictionary *updated = [pending mutableCopy];
          updated[@"url"] = referringURL;
          self.sessionRequests[index] = updated;
        }
      }
    }
    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:safeParams];
  }
  if (command) {
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
  }
  // Let the SDK finish cleaning up the previous response before starting another.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self processNextSessionRequest];
  });
}

- (void)setRequestMetadata:(CDVInvokedUrlCommand*)command
{

  [[Branch getInstance] setRequestMetadataKey:[command.arguments objectAtIndex:0] value:[command.arguments objectAtIndex:1]];

}

- (void)disableTracking:(CDVInvokedUrlCommand*)command
{

  bool enabled = [[command.arguments objectAtIndex:0] boolValue];
  [Branch setTrackingDisabled:enabled];

  CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:enabled];

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)enableLogging:(CDVInvokedUrlCommand*)command
{
  bool enableLogging = [[command.arguments objectAtIndex:0] boolValue];
  if (enableLogging) {
    [[Branch getInstance] enableLogging];
  }

  CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:enableLogging];

  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)getAutoInstance:(CDVInvokedUrlCommand*)command
{
  [self initSession:nil];
}

- (void)getLatestReferringParams:(CDVInvokedUrlCommand*)command
{
  Branch *branch = [self getInstance];
  NSDictionary *sessionParams = [branch getLatestReferringParams];

  CDVPluginResult* pluginResult = nil;

  if (sessionParams != nil && [sessionParams count] > 0) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:sessionParams];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:FALSE];
  }
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)getFirstReferringParams:(CDVInvokedUrlCommand*)command
{
  Branch *branch = [self getInstance];
  NSDictionary *installParams = [branch getFirstReferringParams];

  CDVPluginResult* pluginResult = nil;

  if (installParams != nil && [installParams count] > 0) {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:installParams];
  } else {
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:FALSE];
  }
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)setIdentity:(CDVInvokedUrlCommand*)command
{
  Branch *branch = [self getInstance];

  [branch setIdentity:[command.arguments objectAtIndex:0] withCallback:^(NSDictionary *params, NSError *error) {

    CDVPluginResult* pluginResult = nil;
    if (!error) {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:params];
    }
    else {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];
    }

    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }];
}

- (void)registerDeepLinkController:(CDVInvokedUrlCommand*)command
{
  UIViewController<BranchDeepLinkingController> *controller = (UIViewController<BranchDeepLinkingController>*)self.viewController;
  Branch *branch = [self getInstance];
  [branch registerDeepLinkController:controller forKey:[command.arguments objectAtIndex:0]];
}

-(void)sendBranchEvent:(CDVInvokedUrlCommand*)command
{
    NSString *eventName = [command.arguments objectAtIndex:0];
    NSDictionary *metadata;
    if ([command.arguments count] == 2) {
        metadata = [command.arguments objectAtIndex:1];
    }
    BranchEvent *event = [BranchEvent customEventWithName:eventName];
    for (id key in metadata) {
        if ([key isEqualToString:@"transactionID"]) {
            event.transactionID = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"currency"]) {
            event.currency = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"shipping"]) {
            NSString *value = ([[metadata objectForKey:key] isKindOfClass:[NSString class]]) ? [metadata objectForKey:key] : [[metadata objectForKey:key] stringValue];
            event.shipping = [NSDecimalNumber decimalNumberWithString:value];
        }
        else if ([key isEqualToString:@"tax"]) {
            NSString *value = ([[metadata objectForKey:key] isKindOfClass:[NSString class]]) ? [metadata objectForKey:key] : [[metadata objectForKey:key] stringValue];
            event.tax = [NSDecimalNumber decimalNumberWithString:value];
        }
        else if ([key isEqualToString:@"coupon"]) {
            event.coupon = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"affiliation"]) {
            event.affiliation = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"eventDescription"]) {
            event.eventDescription = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"revenue"]) {
            NSString *value = ([[metadata objectForKey:key] isKindOfClass:[NSString class]]) ? [metadata objectForKey:key] : [[metadata objectForKey:key] stringValue];
            event.revenue = [NSDecimalNumber decimalNumberWithString:value];
        }
        else if ([key isEqualToString:@"searchQuery"]) {
            event.searchQuery = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"description"]) {
            event.eventDescription = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"customerEventAlias"]) {
            event.alias = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"customData"] && [[metadata objectForKey:key] isKindOfClass:[NSMutableDictionary class]]) {
            event.customData = [metadata objectForKey:key];
        }
        else if ([key isEqualToString:@"contentMetadata"]){
             NSMutableArray *mArray = [[NSMutableArray alloc]init];

             for (NSDictionary *dataDictionary in [metadata objectForKey:key]){
                 BranchUniversalObject *contentItem = [BranchUniversalObject objectWithDictionary:(dataDictionary)];
                 [mArray addObject:contentItem];
             }
             event.contentItems = [mArray copy];
        }
    }
    [event logEvent];
}


- (void)logout:(CDVInvokedUrlCommand*)command
{
  Branch *branch = [self getInstance];
  [branch logoutWithCallback:^(BOOL changed, NSError *error) {
    CDVPluginResult *pluginResult = nil;
    if (!error) {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:changed];
    } else {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }];
  self.branchUniversalObjArray = [[NSMutableArray alloc] init];
}

- (void)setDMAParamsForEEA:(CDVInvokedUrlCommand*)command {
  if (command.arguments.count < 3) {
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Insufficient arguments"];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    return;
  }

  BOOL eeaRegion = [[command.arguments objectAtIndex:0] boolValue];
  BOOL adPersonalizationConsent = [[command.arguments objectAtIndex:1] boolValue];
  BOOL adUserDataUsageConsent = [[command.arguments objectAtIndex:2] boolValue];

  [Branch setDMAParamsForEEA:eeaRegion AdPersonalizationConsent:adPersonalizationConsent AdUserDataUsageConsent:adUserDataUsageConsent];

  CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)setConsumerProtectionAttributionLevel:(CDVInvokedUrlCommand*)command {
    NSString *level = [command.arguments objectAtIndex:0];
    BranchAttributionLevel attributionLevel;
    
    if ([level isEqualToString:@"FULL"]) {
        attributionLevel = BranchAttributionLevelFull;
    } else if ([level isEqualToString:@"REDUCED"]) {
        attributionLevel = BranchAttributionLevelReduced;
    } else if ([level isEqualToString:@"MINIMAL"]) {
        attributionLevel = BranchAttributionLevelMinimal;
    } else if ([level isEqualToString:@"NONE"]) {
        attributionLevel = BranchAttributionLevelNone;
    } else {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR 
                                                        messageAsString:@"Invalid attribution level"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    [[Branch getInstance] setConsumerProtectionAttributionLevel:attributionLevel];
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

#pragma mark - Branch Universal Object Methods

- (void)createBranchUniversalObject:(CDVInvokedUrlCommand*)command
{
  NSDictionary *properties = [command.arguments objectAtIndex:0];
  BranchUniversalObject *branchUniversalObj = [[BranchUniversalObject alloc] init];

  for (id key in properties) {
    if ([key isEqualToString:@"contentMetadata"]){
        NSMutableDictionary<NSString *,NSString *> *metadata = (NSMutableDictionary<NSString *,NSString *> *)[properties valueForKey:key];
        [[branchUniversalObj contentMetadata] setCustomMetadata:metadata];
    }
    else if ([key isEqualToString:@"contentIndexingMode"]) {
      NSString *indexingMode = [properties valueForKey:key];
      // Default contentIndexMode is always public
      if ([indexingMode isEqualToString:@"private"]) {
        branchUniversalObj.publiclyIndex = false;
      }
      else {
        branchUniversalObj.publiclyIndex = true;
      }
    }
    else if ([key isEqualToString:@"canonicalIdentifier"]) {
      branchUniversalObj.canonicalIdentifier = [properties valueForKey:key];
    }
    else if ([key isEqualToString:@"title"]) {
      branchUniversalObj.title = [properties valueForKey:key];
    }
    else if ([key isEqualToString:@"contentDescription"]) {
      branchUniversalObj.contentDescription = [properties valueForKey:key];
    }
    else if ([key isEqualToString:@"contentImageUrl"]){
      NSString *imageUrl = [properties valueForKey:key];
      branchUniversalObj.imageUrl = imageUrl;
    }
    else {
      [branchUniversalObj setValue:[properties objectForKey:key] forKey:key];
    }
  }

  // [self.branchUniversalObjArray addObject:branchUniversalObj];

  // Instantiate callback ids
  NSMutableDictionary *branchUniversalObjDict = [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                                @"branchUniversalObj": branchUniversalObj,
                                                                                                @"onShareSheetDismissed": command.callbackId,
                                                                                                @"onShareSheetLaunched": command.callbackId,
                                                                                                @"onLinkShareResponse": command.callbackId,
                                                                                                @"onChannelSelected": command.callbackId
                                                                                                }];
  [self.branchUniversalObjArray addObject:branchUniversalObjDict];

  NSNumber *branchUniversalObjectId = [[NSNumber alloc] initWithInteger:([self.branchUniversalObjArray count] - 1)];
  NSString *message = @"createBranchUniversalObject Success";
  NSDictionary *params = [[NSDictionary alloc] initWithObjectsAndKeys:message, @"message", branchUniversalObjectId, @"branchUniversalObjectId", nil];

  CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:params];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)registerView:(CDVInvokedUrlCommand*)command
{
  int branchUniversalObjectId = [[command.arguments objectAtIndex:0] intValue];

  NSMutableDictionary *branchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:branchUniversalObjectId];
  BranchUniversalObject *branchUniversalObj = [branchUniversalObjDict objectForKey:@"branchUniversalObj"];

  [branchUniversalObj registerViewWithCallback:^(NSDictionary *params, NSError *error) {
    CDVPluginResult *pluginResult = nil;
    if (!error) {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:params];
    } else {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }];
}

- (void)generateShortUrl:(CDVInvokedUrlCommand*)command
{

  int branchUniversalObjectId = [[command.arguments objectAtIndex:0] intValue];
  NSDictionary *arg1 = [command.arguments objectAtIndex:1];
  NSDictionary *arg2 = [command.arguments objectAtIndex:2];

  NSMutableDictionary *branchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:branchUniversalObjectId];
  BranchUniversalObject *branchUniversalObj = [branchUniversalObjDict objectForKey:@"branchUniversalObj"];

  BranchLinkProperties *props = [[BranchLinkProperties alloc] init];

  for (id key in arg1) {
    if ([key isEqualToString:@"duration"]) {
      props.matchDuration = (NSUInteger)[((NSNumber *)[arg1 objectForKey:key]) integerValue];
    }
    else if ([key isEqualToString:@"feature"]) {
      props.feature = [arg1 objectForKey:key];
    }
    else if ([key isEqualToString:@"stage"]) {
      props.stage = [arg1 objectForKey:key];
    }
    else if ([key isEqualToString:@"campaign"]) {
      props.campaign = [arg1 objectForKey:key];
    }
    else if ([key isEqualToString:@"alias"]) {
      props.alias = [arg1 objectForKey:key];
    }
    else if ([key isEqualToString:@"channel"]) {
      props.channel = [arg1 objectForKey:key];
    }
    else if ([key isEqualToString:@"tags"] && [[arg1 objectForKey:key] isKindOfClass:[NSArray class]]) {
      props.tags = [arg1 objectForKey:key];
    }
  }
  if (arg2) {
    for (id key in arg2) {
      [props addControlParam:key withValue:[arg2 objectForKey:key]];
    }
  }

  [branchUniversalObj getShortUrlWithLinkProperties:props andCallback:^(NSString *url, NSError *error) {
    CDVPluginResult* pluginResult = nil;

    if (url) {
      NSError *err;
      NSDictionary *jsonObj = [[NSDictionary alloc] initWithObjectsAndKeys:url, @"url", 0, @"options", &err, @"error", nil];

      if (!jsonObj) {
        NSLog(@"Parsing Error: %@", [err localizedDescription]);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[err localizedDescription]];
      } else {
        NSLog(@"Success");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:jsonObj];
      }
    }
    else {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }];
}

- (void)showShareSheet:(CDVInvokedUrlCommand*)command
{
  NSString *shareText = @"Share Link";

  if ([command.arguments count] >= 4) {
    shareText = [command.arguments objectAtIndex:3];
  }

  int branchUniversalObjectId = [[command.arguments objectAtIndex:0] intValue];
  NSDictionary *arg1 = [command.arguments objectAtIndex:1];
  NSDictionary *arg2 = [command.arguments objectAtIndex:2];

  NSMutableDictionary *branchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:branchUniversalObjectId];
  BranchUniversalObject *branchUniversalObj = [branchUniversalObjDict objectForKey:@"branchUniversalObj"];

  BranchLinkProperties *linkProperties = [[BranchLinkProperties alloc] init];

  for (id key in arg1) {
    if ([key isEqualToString:@"duration"]) {
      linkProperties.matchDuration = (NSUInteger)[((NSNumber *)[arg1 objectForKey:key]) integerValue];
    }
    else {
      [linkProperties setValue:[arg1 objectForKey:key] forKey:key];
    }
  }

  if (arg2) {
    for (id key in arg2) {
      [linkProperties addControlParam:key withValue:[arg2 objectForKey:key]];
    }
  }
    [branchUniversalObj showShareSheetWithLinkProperties:linkProperties andShareText:shareText fromViewController:self.viewController completionWithError:^(NSString * _Nullable activityType, BOOL completed, NSError * _Nullable error) {
        
        int listenerCallbackId = [[command.arguments objectAtIndex:0] intValue];

        if (completed) {
          NSLog(@"Share link complete");
          [branchUniversalObj getShortUrlWithLinkProperties:linkProperties andCallback:^(NSString *url, NSError *error) {
            if (!error) {
              NSDictionary *response = [[NSDictionary alloc] initWithObjectsAndKeys:url, @"sharedLink", activityType, @"sharedChannel", nil];
              [self doShareLinkResponse:listenerCallbackId sendResponse:response];
            }
          }];
        }

    CDVPluginResult *shareDialogDismissed = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];

    NSMutableDictionary *branchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:listenerCallbackId];

    [shareDialogDismissed setKeepCallbackAsBool:TRUE];

    [self.commandDelegate sendPluginResult:shareDialogDismissed callbackId:[branchUniversalObjDict objectForKey:@"onShareSheetDismissed"]];
  }];
}

- (void)doShareLinkResponse:(int)callbackId sendResponse:(NSDictionary*)response {
  CDVPluginResult *linkShareResponse = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:response];
  NSMutableDictionary *branchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:callbackId];

  [linkShareResponse setKeepCallbackAsBool:TRUE];

  [self.commandDelegate sendPluginResult:linkShareResponse callbackId:[branchUniversalObjDict objectForKey:@"onLinkShareResponse"]];
}

- (void)onShareLinkDialogDismissed:(CDVInvokedUrlCommand*)command
{
  int listenerCallbackId = [[command.arguments objectAtIndex:0] intValue];

  NSMutableDictionary *newBranchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:listenerCallbackId];
  [newBranchUniversalObjDict setObject:command.callbackId forKey:@"onShareSheetDismissed"];

  [self.branchUniversalObjArray replaceObjectAtIndex:listenerCallbackId withObject:newBranchUniversalObjDict];
}

- (void)onLinkShareResponse:(CDVInvokedUrlCommand*)command
{
  int listenerCallbackId = [[command.arguments objectAtIndex:0] intValue];

  NSMutableDictionary *newBranchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:listenerCallbackId];
  [newBranchUniversalObjDict setObject:command.callbackId forKey:@"onLinkShareResponse"];

  [self.branchUniversalObjArray replaceObjectAtIndex:listenerCallbackId withObject:newBranchUniversalObjDict];
}

- (void)listOnSpotlight:(CDVInvokedUrlCommand*)command {
  int branchUniversalObjectId = [[command.arguments objectAtIndex:0] intValue];

  NSMutableDictionary *branchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:branchUniversalObjectId];
  BranchUniversalObject *branchUniversalObj = [branchUniversalObjDict objectForKey:@"branchUniversalObj"];

  [branchUniversalObj listOnSpotlightWithCallback:^(NSString *string, NSError *error) {
    CDVPluginResult* pluginResult = nil;
    if (!error) {
      NSError *err;
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@{@"result":string} options:0 error:&err];
      if (!jsonData) {
        NSLog(@"Parsing Error: %@", [err localizedDescription]);
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[err localizedDescription]];
      } else {
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:jsonString];
      }
    }
    else {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }];
}

#pragma mark Branch Query Methods

- (void)lastAttributedTouchData:(CDVInvokedUrlCommand *)command {
  NSMutableDictionary *json = [NSMutableDictionary new];

  Branch *branch = [self getInstance];
  [branch lastAttributedTouchDataWithAttributionWindow:30 completion:^(BranchLastAttributedTouchData * _Nullable latd, NSError * _Nullable error) {
    CDVPluginResult* pluginResult = nil;
    if (latd) {
      [json setObject:latd.attributionWindow forKey:@"attribution_window"];
      [json setObject:latd.lastAttributedTouchJSON forKey:@"last_attributed_touch_data"];

      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:json];
    } else {
      pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No LATD available"];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
  }];
}

- (void)getBranchQRCode:(CDVInvokedUrlCommand*)command
{
    int branchUniversalObjectId = [[command.arguments objectAtIndex:1] intValue];
    NSMutableDictionary *branchUniversalObjDict = [self.branchUniversalObjArray objectAtIndex:branchUniversalObjectId];
    BranchUniversalObject *branchUniversalObj = [branchUniversalObjDict objectForKey:@"branchUniversalObj"];

    BranchLinkProperties *linkProperties = [BranchLinkProperties new];
    
    NSDictionary *arg1 = [command.arguments objectAtIndex:2];
    NSDictionary *arg2 = [command.arguments objectAtIndex:3];

    for (id key in arg1) {
      if ([key isEqualToString:@"duration"]) {
        linkProperties.matchDuration = (NSUInteger)[((NSNumber *)[arg1 objectForKey:key]) integerValue];
      }
      else if ([key isEqualToString:@"feature"]) {
        linkProperties.feature = [arg1 objectForKey:key];
      }
      else if ([key isEqualToString:@"stage"]) {
        linkProperties.stage = [arg1 objectForKey:key];
      }
      else if ([key isEqualToString:@"campaign"]) {
        linkProperties.campaign = [arg1 objectForKey:key];
      }
      else if ([key isEqualToString:@"alias"]) {
        linkProperties.alias = [arg1 objectForKey:key];
      }
      else if ([key isEqualToString:@"channel"]) {
        linkProperties.channel = [arg1 objectForKey:key];
      }
      else if ([key isEqualToString:@"tags"] && [[arg1 objectForKey:key] isKindOfClass:[NSArray class]]) {
        linkProperties.tags = [arg1 objectForKey:key];
      }
    }
    if (arg2) {
      for (id key in arg2) {
        [linkProperties addControlParam:key withValue:[arg2 objectForKey:key]];
      }
    }

    NSMutableDictionary *qrCodeSettingsMap = [command.arguments objectAtIndex:0];

    BranchQRCode *qrCode = [BranchQRCode new];
    
    if (qrCodeSettingsMap[@"codeColor"]) {
        qrCode.codeColor = [self colorWithHexString:qrCodeSettingsMap[@"codeColor"]];
    }
    if (qrCodeSettingsMap[@"backgroundColor"]) {
        qrCode.backgroundColor = [self colorWithHexString:qrCodeSettingsMap[@"backgroundColor"]];
    }
    if (qrCodeSettingsMap[@"centerLogo"]) {
        qrCode.centerLogo = qrCodeSettingsMap[@"centerLogo"];
    }
    if (qrCodeSettingsMap[@"width"]) {
        qrCode.width = qrCodeSettingsMap[@"width"];
    }
    if (qrCodeSettingsMap[@"margin"]) {
        qrCode.margin = qrCodeSettingsMap[@"margin"];
    }
    if (qrCodeSettingsMap[@"imageFormat"]) {
        if ([qrCodeSettingsMap[@"imageFormat"] isEqual:@"JPEG"]) {
            qrCode.imageFormat = BranchQRCodeImageFormatJPEG;
        } else {
            qrCode.imageFormat = BranchQRCodeImageFormatPNG;
        }
    }

    [qrCode getQRCodeAsData:branchUniversalObj linkProperties:linkProperties completion:^(NSData * _Nonnull qrCodeData, NSError * _Nonnull error) {
      CDVPluginResult* pluginResult = nil;
        
        if (!error) {
            NSString* imageString = [qrCodeData base64EncodedStringWithOptions:nil];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:imageString];
        } else {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];
        }

        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (UIColor *) colorWithHexString: (NSString *) hexString {
    NSString *colorString = [[hexString stringByReplacingOccurrencesOfString: @"#" withString: @""] uppercaseString];
    CGFloat alpha, red, blue, green;
    switch ([colorString length]) {
        case 3: // #RGB
            alpha = 1.0f;
            red   = [self colorComponentFrom: colorString start: 0 length: 1];
            green = [self colorComponentFrom: colorString start: 1 length: 1];
            blue  = [self colorComponentFrom: colorString start: 2 length: 1];
            break;
        case 4: // #ARGB
            alpha = [self colorComponentFrom: colorString start: 0 length: 1];
            red   = [self colorComponentFrom: colorString start: 1 length: 1];
            green = [self colorComponentFrom: colorString start: 2 length: 1];
            blue  = [self colorComponentFrom: colorString start: 3 length: 1];          
            break;
        case 6: // #RRGGBB
            alpha = 1.0f;
            red   = [self colorComponentFrom: colorString start: 0 length: 2];
            green = [self colorComponentFrom: colorString start: 2 length: 2];
            blue  = [self colorComponentFrom: colorString start: 4 length: 2];                      
            break;
        case 8: // #AARRGGBB
            alpha = [self colorComponentFrom: colorString start: 0 length: 2];
            red   = [self colorComponentFrom: colorString start: 2 length: 2];
            green = [self colorComponentFrom: colorString start: 4 length: 2];
            blue  = [self colorComponentFrom: colorString start: 6 length: 2];                      
            break;
        default:
            NSLog(@"Error: Invalid color value. It should be a hex value of the form #RBG, #ARGB, #RRGGBB, or #AARRGGBB");
            break;
    }
    return [UIColor colorWithRed: red green: green blue: blue alpha: alpha];
}

- (CGFloat) colorComponentFrom: (NSString *) string start: (NSUInteger) start length: (NSUInteger) length {
    NSString *substring = [string substringWithRange: NSMakeRange(start, length)];
    NSString *fullHex = length == 2 ? substring : [NSString stringWithFormat: @"%@%@", substring, substring];
    unsigned hexComponent;
    [[NSScanner scannerWithString: fullHex] scanHexInt: &hexComponent];
    return hexComponent / 255.0;
}

#pragma mark - URL Methods (not fully implemented YET!)

- (NSString *)getShortURL:(CDVInvokedUrlCommand*)command
{
  Branch *branch = [self getInstance];
  return [branch getShortURL];
}

- (id)getShortURLWithParams:(CDVInvokedUrlCommand*)command
{
  Branch *branch = [self getInstance];
  NSDictionary *params = [command.arguments objectAtIndex:0];

  return [branch getShortURLWithParams:params];
}

- (NSString *)getLongURLWithParams:(CDVInvokedUrlCommand*)command
{
  id params = [command.arguments objectAtIndex:0];
  return [[self getInstance] getLongURLWithParams:params];
}

- (void)getBranchActivityItemWithParams:(CDVInvokedUrlCommand*)command
{
  UIActivityItemProvider *provider = [Branch getBranchActivityItemWithParams:[command.arguments objectAtIndex:0]];

  UIActivityViewController *shareViewController = [[UIActivityViewController alloc] initWithActivityItems:@[ provider ] applicationActivities:nil];

  [self.viewController presentViewController:shareViewController animated:YES completion:nil];
}



@end
