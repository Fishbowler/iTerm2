//
//  iTermAPIHelper.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 4/18/18.
//

#import "iTermAPIHelper.h"

#import "CVector.h"
#import "DebugLogging.h"
#import "iTermAPIAuthorizationController.h"
#import "iTermBuriedSessions.h"
#import "iTermBuiltInFunctions.h"
#import "iTermController.h"
#import "iTermDisclosableView.h"
#import "iTermLSOF.h"
#import "iTermProfilePreferences.h"
#import "iTermPythonArgumentParser.h"
#import "iTermVariables.h"
#import "MovePaneController.h"
#import "NSArray+iTerm.h"
#import "NSDictionary+iTerm.h"
#import "NSFileManager+iTerm.h"
#import "NSJSONSerialization+iTerm.h"
#import "NSObject+iTerm.h"
#import "ProfileModel.h"
#import "PseudoTerminal.h"
#import "PTYSession.h"
#import "PTYTab.h"
#import "WindowControllerInterface.h"
#import "VT100Parser.h"

NSString *const iTermRemoveAPIServerSubscriptionsNotification = @"iTermRemoveAPIServerSubscriptionsNotification";
NSString *const iTermAPIRegisteredFunctionsDidChangeNotification = @"iTermAPIRegisteredFunctionsDidChangeNotification";
NSString *const iTermAPIDidRegisterSessionTitleFunctionNotification = @"iTermAPIDidRegisterSessionTitleFunctionNotification";

const NSInteger iTermAPIHelperFunctionCallUnregisteredErrorCode = 100;
const NSInteger iTermAPIHelperFunctionCallOtherErrorCode = 1;

@interface iTermAllSessionsSubscription : NSObject
@property (nonatomic, strong) ITMNotificationRequest *request;
@property (nonatomic, strong) id connection;
@end

@interface ITMRPCRegistrationRequest(Extensions)
@property (nonatomic, readonly) BOOL it_valid;
@property (nonatomic, readonly) NSString *it_stringRepresentation;
@end

@implementation ITMRPCRegistrationRequest(Extensions)

- (BOOL)it_valid {
    NSCharacterSet *ascii = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 128)];
    NSMutableCharacterSet *invalidIdentifierCharacterSet = [NSMutableCharacterSet alphanumericCharacterSet];
    [invalidIdentifierCharacterSet addCharactersInString:@"_"];
    [invalidIdentifierCharacterSet formIntersectionWithCharacterSet:ascii];
    [invalidIdentifierCharacterSet invert];

    if (self.name.length == 0) {
        return NO;
    }
    if ([self.name rangeOfCharacterFromSet:invalidIdentifierCharacterSet].location != NSNotFound) {
        return NO;
    }
    NSMutableSet<NSString *> *args = [NSMutableSet set];
    for (ITMRPCRegistrationRequest_RPCArgumentSignature *arg in self.argumentsArray) {
        NSString *name = arg.name;
        if (name.length == 0) {
            return NO;
        }
        if ([name rangeOfCharacterFromSet:invalidIdentifierCharacterSet].location != NSNotFound) {
            return NO;
        }
        if ([args containsObject:name]) {
            return NO;
        }
        [args addObject:name];
    }

    return YES;
}

- (NSString *)it_stringRepresentation {
    NSArray<NSString *> *argNames = [self.argumentsArray mapWithBlock:^id(ITMRPCRegistrationRequest_RPCArgumentSignature *anObject) {
        return anObject.name;
    }];
    return iTermFunctionSignatureFromNameAndArguments(self.name, argNames);
}

@end

@interface ITMServerOriginatedRPC(Extensions)
@property (nonatomic, readonly) NSString *it_stringRepresentation;
@end

@implementation ITMServerOriginatedRPC(Extensions)

- (NSString *)it_stringRepresentation {
    NSArray<NSString *> *argNames = [self.argumentsArray mapWithBlock:^id(ITMServerOriginatedRPC_RPCArgument *anObject) {
        return anObject.name;
    }];
    return iTermFunctionSignatureFromNameAndArguments(self.name, argNames);
}

@end

@implementation iTermAllSessionsSubscription
@end

@implementation iTermAPIHelper {
    iTermAPIServer *_apiServer;
    BOOL _layoutChanged;

    // When adding a new dictionary of subscriptions update removeAllSubscriptionsForConnection:.
    NSMutableDictionary<id, ITMNotificationRequest *> *_newSessionSubscriptions;
    NSMutableDictionary<id, ITMNotificationRequest *> *_terminateSessionSubscriptions;
    NSMutableDictionary<id, ITMNotificationRequest *> *_layoutChangeSubscriptions;
    NSMutableDictionary<id, ITMNotificationRequest *> *_focusChangeSubscriptions;
    // signature -> { connection -> request }
    NSMutableDictionary<NSString *, NSMutableDictionary<id, ITMNotificationRequest *> *> *_serverOriginatedRPCSubscriptions;
    NSMutableArray<iTermAllSessionsSubscription *> *_allSessionsSubscriptions;
    NSMutableDictionary<NSString *, iTermServerOriginatedRPCCompletionBlock> *_serverOriginatedRPCCompletionBlocks;
    // connection -> RPC ID (RPC ID is key in _serverOriginatedRPCCompletionBlocks)
    // WARNING: These can exist after the block has been removed from
    // _serverOriginatedRPCCompletionBlocks if it times out.
    NSMutableDictionary<id, NSMutableSet<NSString *> *> *_outstandingRPCs;
}

+ (instancetype)sharedInstance {
    static id instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _apiServer = [[iTermAPIServer alloc] init];
        _apiServer.delegate = self;
        _serverOriginatedRPCCompletionBlocks = [NSMutableDictionary dictionary];
        _outstandingRPCs = [NSMutableDictionary dictionary];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionDidTerminate:)
                                                     name:PTYSessionTerminatedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionCreated:)
                                                     name:PTYSessionCreatedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sessionCreated:)
                                                     name:PTYSessionRevivedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(layoutChanged:)
                                                     name:iTermSessionDidChangeTabNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(layoutChanged:)
                                                     name:iTermTabDidChangeWindowNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(layoutChanged:)
                                                     name:iTermTabDidChangePositionInWindowNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(layoutChanged:)
                                                     name:iTermSessionBuriedStateChangeTabNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:NSApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidResignActive:)
                                                     name:NSApplicationDidResignActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidBecomeKey:)
                                                     name:NSWindowDidBecomeKeyNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidResignKey:)
                                                     name:NSWindowDidResignKeyNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(selectedTabDidChange:)
                                                     name:iTermSelectedTabDidChange
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(activeSessionDidChange:)
                                                     name:iTermSessionBecameKey
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)postAPINotification:(ITMNotification *)notification toConnection:(id)connection {
    [_apiServer postAPINotification:notification toConnection:connection];
}

- (void)sessionCreated:(NSNotification *)notification {
    for (iTermAllSessionsSubscription *sub in _allSessionsSubscriptions) {
        [self handleAPINotificationRequest:sub.request connection:sub.connection];
    }

    PTYSession *session = notification.object;
    [_newSessionSubscriptions enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, ITMNotificationRequest * _Nonnull obj, BOOL * _Nonnull stop) {
        ITMNotification *notification = [[ITMNotification alloc] init];
        notification.newSessionNotification = [[ITMNewSessionNotification alloc] init];
        notification.newSessionNotification.uniqueIdentifier = session.guid;
        [self postAPINotification:notification toConnection:key];
    }];
}

- (void)sessionDidTerminate:(NSNotification *)notification {
    PTYSession *session = notification.object;
    [_terminateSessionSubscriptions enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, ITMNotificationRequest * _Nonnull obj, BOOL * _Nonnull stop) {
        ITMNotification *notification = [[ITMNotification alloc] init];
        notification.terminateSessionNotification = [[ITMTerminateSessionNotification alloc] init];
        notification.terminateSessionNotification.uniqueIdentifier = session.guid;
        [self postAPINotification:notification toConnection:key];
    }];
}

- (void)layoutChanged:(NSNotification *)notification {
    if (!_layoutChanged) {
        _layoutChanged = YES;
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleLayoutChange];
        });
    }
}

- (void)handleLayoutChange {
    _layoutChanged = NO;
    [_layoutChangeSubscriptions enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, ITMNotificationRequest * _Nonnull obj, BOOL * _Nonnull stop) {
        ITMNotification *notification = [[ITMNotification alloc] init];
        notification.layoutChangedNotification.listSessionsResponse = [self newListSessionsResponse];
        [self postAPINotification:notification toConnection:key];
    }];
}

/*
 oneof event {
 // true: application became active. false: application resigned active.
 bool application_active = 1;

 // true: window became key. false: window resigned key.
 bool window_key = 2;

 // If set, selected tab changed to the one identified herein.
 Tab selected_tab = 3;

 // If set, the given session became active in its tab.
 string session = 4;
 }
*/

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    ITMFocusChangedNotification *focusChange = [[ITMFocusChangedNotification alloc] init];
    focusChange.applicationActive = YES;
    [self handleFocusChange:focusChange];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    ITMFocusChangedNotification *focusChange = [[ITMFocusChangedNotification alloc] init];
    focusChange.applicationActive = NO;
    [self handleFocusChange:focusChange];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    ITMFocusChangedNotification *focusChange = [[ITMFocusChangedNotification alloc] init];
    NSWindow *window = notification.object;
    PseudoTerminal *term = [[iTermController sharedInstance] terminalForWindow:window];
    focusChange.window = [[ITMFocusChangedNotification_Window alloc] init];
    if (term) {
        focusChange.window.windowId = term.terminalGuid;
        focusChange.window.windowStatus = ITMFocusChangedNotification_Window_WindowStatus_TerminalWindowBecameKey;
    } else {
        term = [[iTermController sharedInstance] currentTerminal];
        if (!term) {
            // Non-terminal window became key and no terminal is current (e.g., you opened prefs).
            // Not very interesting.
            return;
        }
        focusChange.window.windowId = [term terminalGuid];
        focusChange.window.windowStatus = ITMFocusChangedNotification_Window_WindowStatus_TerminalWindowIsCurrent;
    }
    [self handleFocusChange:focusChange];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    ITMFocusChangedNotification *focusChange = [[ITMFocusChangedNotification alloc] init];
    NSWindow *window = notification.object;
    PseudoTerminal *term = [[iTermController sharedInstance] terminalForWindow:window];
    if (window && term) {
        focusChange.window = [[ITMFocusChangedNotification_Window alloc] init];
        focusChange.window.windowId = term.terminalGuid;
        focusChange.window.windowStatus = ITMFocusChangedNotification_Window_WindowStatus_TerminalWindowResignedKey;
        [self handleFocusChange:focusChange];
    }
}

- (void)selectedTabDidChange:(NSNotification *)notification {
    PTYTab *tab = notification.object;
    ITMFocusChangedNotification *focusChange = [[ITMFocusChangedNotification alloc] init];
    focusChange.selectedTab = [@(tab.uniqueId) stringValue];
    [self handleFocusChange:focusChange];
}

- (void)activeSessionDidChange:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSNumber *changed = userInfo[@"changed"];
    if (changed && !changed.boolValue) {
        return;
    }
    PTYSession *session = notification.object;
    ITMFocusChangedNotification *focusChange = [[ITMFocusChangedNotification alloc] init];
    focusChange.session = session.guid;
    [self handleFocusChange:focusChange];
}

- (void)handleFocusChange:(ITMFocusChangedNotification *)notif {
    [_focusChangeSubscriptions enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, ITMNotificationRequest * _Nonnull obj, BOOL * _Nonnull stop) {
        ITMNotification *notification = [[ITMNotification alloc] init];
        notification.focusChangedNotification = notif;
        [self postAPINotification:notification toConnection:key];
    }];
}

- (ITMServerOriginatedRPC *)serverOriginatedRPCWithName:(NSString *)name
                                              arguments:(NSDictionary *)arguments
                                                  error:(out NSError **)error {

    ITMServerOriginatedRPC *rpc = [[ITMServerOriginatedRPC alloc] init];
    rpc.name = name;
    for (NSString *argumentName in [arguments.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id argumentValue = arguments[argumentName];
        NSString *jsonValue;
        if ([NSNull castFrom:argumentValue]) {
            jsonValue = nil;
        } else {
            jsonValue = [NSJSONSerialization it_jsonStringForObject:argumentValue];
            if (!jsonValue) {
                NSString *reason = [NSString stringWithFormat:@"Could not JSON encode value “%@”", arguments[argumentName]];
                *error = [NSError errorWithDomain:@"com.iterm2.api"
                                             code:2
                                         userInfo:@{ NSLocalizedDescriptionKey: reason }];
                return nil;
            }
        }
        ITMServerOriginatedRPC_RPCArgument *argument = [[ITMServerOriginatedRPC_RPCArgument alloc] init];
        argument.name = argumentName;
        if (jsonValue) {
            argument.jsonValue = jsonValue;
        }

        [rpc.argumentsArray addObject:argument];
    }
    return rpc;
}

// Build a proto buffer and dispatch it.
- (void)dispatchRPCWithName:(NSString *)name
                  arguments:(NSDictionary *)arguments
                 completion:(iTermServerOriginatedRPCCompletionBlock)completion {
    NSError *error = nil;
    ITMServerOriginatedRPC *rpc = [self serverOriginatedRPCWithName:name arguments:arguments error:&error];
    if (error) {
        completion(nil, error);
    }
    [self dispatchServerOriginatedRPC:rpc completion:completion];
}

- (id)synchronousDispatchRPCWithName:(NSString *)name
                           arguments:(NSDictionary *)arguments
                             timeout:(NSTimeInterval)timeout
                               error:(out NSError **)error {
    NSError *innerError = nil;
    ITMServerOriginatedRPC *rpc = [self serverOriginatedRPCWithName:name arguments:arguments error:&innerError];
    if (innerError) {
        if (error) {
            *error = innerError;
        }
        return nil;
    }
    ITMServerOriginatedRPCResultRequest *result = [self synchronousDispatchServerOriginatedRPC:rpc
                                                                                       timeout:timeout
                                                                                         error:&innerError];
    if (innerError) {
        if (error) {
            *error = innerError;
        }
        return nil;
    }
    if (result.jsonException.length > 0) {
        NSError *internalError;
        id exception = [NSJSONSerialization JSONObjectWithData:[result.jsonException dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:NSJSONReadingAllowFragments
                                                      error:&internalError];
        if (internalError) {
            exception = @{ @"reason": [NSString stringWithFormat:@"Undecodable exception: %@", internalError.localizedDescription] };
        } else {
            exception = [NSDictionary castFrom:exception] ?: @{ @"reason": @"Malformed exception" };
        }
        if (error) {
            *error = [self rpcDispatchError:exception[@"reason"]
                                     detail:exception[@"traceback"]
                               unregistered:NO];
        }
        return nil;
    }
    if (result.jsonValue.length == 0) {
        if (error) {
            *error = [self rpcDispatchError:@"Malformed response missing json value"
                                     detail:[result debugDescription]
                               unregistered:NO];
        }
        return nil;
    }
    NSError *internalError;
    NSData *data = [result.jsonValue dataUsingEncoding:NSUTF8StringEncoding];
    id returnedObject = [NSJSONSerialization JSONObjectWithData:data
                                                        options:NSJSONReadingAllowFragments
                                                          error:&internalError];
    if (internalError) {
        if (error) {
            *error = internalError;
        }
        return nil;
    }
    return returnedObject;
}

// Dispatches a well-formed proto buffer or gives an error if not connected.
- (void)dispatchServerOriginatedRPC:(ITMServerOriginatedRPC *)rpc
                         completion:(iTermServerOriginatedRPCCompletionBlock)completion {
    NSString *signature = rpc.it_stringRepresentation;
    NSDictionary<id, ITMNotificationRequest *> *subs = _serverOriginatedRPCSubscriptions[signature];

    id connectionKey = subs.allKeys.firstObject;
    if (!connectionKey) {
        NSString *reason = [NSString stringWithFormat:@"No function registered for invocation “%@”", signature];
        completion(nil, [self rpcDispatchError:reason detail:nil unregistered:YES]);
        return;
    }

    ITMNotificationRequest *notificationRequest = subs[connectionKey];
    [self dispatchRPC:rpc toHandler:notificationRequest connection:connectionKey completion:completion];
}

- (ITMServerOriginatedRPCResultRequest *)synchronousDispatchServerOriginatedRPC:(ITMServerOriginatedRPC *)rpc
                                                                        timeout:(NSTimeInterval)timeout
                                                                          error:(out NSError **)error {
    NSString *signature = rpc.it_stringRepresentation;
    NSDictionary<id, ITMNotificationRequest *> *subs = _serverOriginatedRPCSubscriptions[signature];

    id connectionKey = subs.allKeys.firstObject;
    if (!connectionKey) {
        NSString *reason = [NSString stringWithFormat:@"No function registered for invocation “%@”", signature];
        *error = [self rpcDispatchError:reason detail:nil unregistered:YES];
        return nil;
    }

    ITMNotificationRequest *notificationRequest = subs[connectionKey];
    return [self synchronousDispatchRPC:rpc
                              toHandler:notificationRequest
                             connection:connectionKey
                                timeout:timeout
                                  error:error];
}

// Constructs an error with an optional traceback in `detail`.
- (NSError *)rpcDispatchError:(NSString *)reason detail:(NSString *)detail unregistered:(BOOL)unregistered {
    if (reason == nil) {
        reason = @"Unknown reason";
    }
    NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: reason };
    if (detail) {
        userInfo = [userInfo dictionaryBySettingObject:detail forKey:NSLocalizedFailureReasonErrorKey];
    }
    return [NSError errorWithDomain:@"com.iterm2.api"
                               code:unregistered ? iTermAPIHelperFunctionCallUnregisteredErrorCode : iTermAPIHelperFunctionCallOtherErrorCode
                           userInfo:userInfo];
}

// Dispatches an RPC, assuming connected. Registers a timeout.
- (void)dispatchRPC:(ITMServerOriginatedRPC *)rpc
          toHandler:(ITMNotificationRequest * _Nonnull)handler
         connection:(id)connection
         completion:(iTermServerOriginatedRPCCompletionBlock)completion {
    ITMNotification *notification = [[ITMNotification alloc] init];
    notification.serverOriginatedRpcNotification.requestId = [self nextServerOriginatedRPCRequestIDWithCompletion:completion];
    NSMutableSet *outstanding = _outstandingRPCs[connection];
    if (!outstanding) {
        outstanding = [NSMutableSet set];
        _outstandingRPCs[connection] = outstanding;
    }
    [outstanding addObject:notification.serverOriginatedRpcNotification.requestId];
    notification.serverOriginatedRpcNotification.rpc = rpc;
    [self postAPINotification:notification toConnection:connection];

    __weak __typeof(self) weakSelf = self;
    const NSTimeInterval timeoutSeconds = handler.rpcRegistrationRequest.hasTimeout ? handler.rpcRegistrationRequest.timeout : 5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf checkForRPCTimeout:notification.serverOriginatedRpcNotification.requestId];
    });
}

- (ITMServerOriginatedRPCResultRequest *)synchronousDispatchRPC:(ITMServerOriginatedRPC *)rpc
                                                      toHandler:(ITMNotificationRequest * _Nonnull)handler
                                                     connection:(id)connection
                                                        timeout:(NSTimeInterval)callerTimeout
                                                          error:(out NSError **)error {
    ITMNotification *notification = [[ITMNotification alloc] init];
    notification.serverOriginatedRpcNotification.requestId = [self nextServerOriginatedRPCRequestIDWithCompletion:nil];
    NSMutableSet *outstanding = _outstandingRPCs[connection];
    if (!outstanding) {
        outstanding = [NSMutableSet set];
        _outstandingRPCs[connection] = outstanding;
    }
    [outstanding addObject:notification.serverOriginatedRpcNotification.requestId];
    notification.serverOriginatedRpcNotification.rpc = rpc;
    const NSTimeInterval timeoutSeconds = handler.rpcRegistrationRequest.hasTimeout ? handler.rpcRegistrationRequest.timeout : 5;
    return [_apiServer sendAndWaitForSynchronousRPC:notification
                                       toConnection:connection
                                            timeout:MIN(callerTimeout, timeoutSeconds)
                                              error:error];
}

// Calls the completion block if RPC timed out.
- (void)checkForRPCTimeout:(NSString *)requestID {
    iTermServerOriginatedRPCCompletionBlock completion = _serverOriginatedRPCCompletionBlocks[requestID];
    if (!completion) {
        return;
    }

    [_serverOriginatedRPCCompletionBlocks removeObjectForKey:requestID];
    completion(nil, [self rpcDispatchError:@"Timeout" detail:nil unregistered:NO]);
}

- (NSString *)nextServerOriginatedRPCRequestIDWithCompletion:(iTermServerOriginatedRPCCompletionBlock)completion {
    static NSInteger nextID;
    NSString *requestID = [NSString stringWithFormat:@"rpc-%@", @(nextID)];
    nextID++;
    if (completion) {
        _serverOriginatedRPCCompletionBlocks[requestID] = [completion copy];
    }
    return requestID;
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)registeredFunctionSignatureDictionary {
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *result = [NSMutableDictionary dictionary];
    for (NSString *stringSignature in _serverOriginatedRPCSubscriptions.allKeys) {
        ITMNotificationRequest *req = _serverOriginatedRPCSubscriptions[stringSignature].allValues.firstObject;
        if (!req) {
            continue;
        }
        ITMRPCRegistrationRequest *sig = req.rpcRegistrationRequest;
        NSString *functionName = sig.name;
        NSArray<NSString *> *args = [sig.argumentsArray mapWithBlock:^id(ITMRPCRegistrationRequest_RPCArgumentSignature *anObject) {
            return anObject.name;
        }];
        result[functionName] = args;
    }
    return result;
}

- (NSString *)invocationOfRegistrationRequest:(ITMRPCRegistrationRequest *)req {
    NSArray<NSString *> *defaults = [req.defaultsArray mapWithBlock:^id(ITMRPCRegistrationRequest_RPCArgument *def) {
        return [NSString stringWithFormat:@"%@:%@", def.name, def.path];
    }];
    defaults = [defaults sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"%@(%@)", req.name, [defaults componentsJoinedByString:@","]];
}

- (NSArray<iTermTuple<NSString *,NSString *> *> *)sessionTitleFunctions {
    return [_serverOriginatedRPCSubscriptions.allKeys mapWithBlock:^id(NSString *signature) {
        ITMNotificationRequest *req = self->_serverOriginatedRPCSubscriptions[signature].allValues.firstObject;
        if (!req) {
            return nil;
        }
        if (req.rpcRegistrationRequest.role != ITMRPCRegistrationRequest_Role_SessionTitle) {
            return nil;
        }
        NSString *invocation = [self invocationOfRegistrationRequest:req.rpcRegistrationRequest];
        return [iTermTuple tupleWithObject:req.rpcRegistrationRequest.displayName andObject:invocation];
    }];
}

- (BOOL)haveRegisteredFunctionWithName:(NSString *)name
                             arguments:(NSArray<NSString *> *)arguments {
    NSString *stringSignature = iTermFunctionSignatureFromNameAndArguments(name, arguments);
    return [self haveRegisteredFunctionWithSignature:stringSignature];
}

- (BOOL)haveRegisteredFunctionWithSignature:(NSString *)stringSignature {
    return _serverOriginatedRPCSubscriptions[stringSignature].allValues.firstObject != nil;
}

#pragma mark - iTermAPIServerDelegate

- (NSMenuItem *)menuItemWithTitleParts:(NSArray<NSString *> *)titleParts
                                inMenu:(NSMenu *)menu NS_DEPRECATED_MAC(10_10, 10_11, "Use menuItemWithIdentifier:") {
    NSString *head = titleParts.firstObject;
    NSArray<NSString *> *remainingTitleParts = [titleParts subarrayFromIndex:1];
    for (NSMenuItem *item in [menu itemArray]) {
        if ([item.title isEqualToString:head]) {
            if ([item hasSubmenu]) {
                return [self menuItemWithTitleParts:remainingTitleParts
                                             inMenu:item.submenu];
            } else if (remainingTitleParts.count == 0) {
                return item;
            }
        }
    }
    return nil;
}

- (NSMenuItem *)menuItemWithIdentifier:(NSString *)identifier
                                inMenu:(NSMenu *)menu NS_AVAILABLE_MAC(10_12) {
    for (NSMenuItem *item in [menu itemArray]) {
        if ([item hasSubmenu]) {
            NSMenuItem *result = [self menuItemWithIdentifier:identifier inMenu:item.submenu];
            if (result) {
                return result;
            }
        } else if (item.identifier && [identifier isEqualToString:item.identifier]) {
            NSLog(@"Found it");
            return item;
        }
    }
    NSLog(@"Didn't find it");
    return nil;
}

- (BOOL)askUserToGrantAuthForController:(iTermAPIAuthorizationController *)controller
                      isReauthorization:(BOOL)reauth
                               remember:(out BOOL *)remember {
    NSAlert *alert = [[NSAlert alloc] init];
    if (reauth) {
        alert.messageText = @"Reauthorize API Access";
        alert.informativeText = [NSString stringWithFormat:@"The application “%@” has API access, which grants it permission to see and control your activity. Would you like it to continue?",
                                 controller.humanReadableName];
    } else {
        alert.messageText = @"API Access Request";
        alert.informativeText = [NSString stringWithFormat:@"The application “%@” would like to control iTerm2. This exposes a significant amount of data in iTerm2 to %@. Allow this request?",
                                 controller.humanReadableName, controller.humanReadableName];
    }

    iTermDisclosableView *accessory = [[iTermDisclosableView alloc] initWithFrame:NSZeroRect
                                                                           prompt:@"Full Command"
                                                                          message:controller.fullCommandOrBundleID];
    accessory.frame = NSMakeRect(0, 0, accessory.intrinsicContentSize.width, accessory.intrinsicContentSize.height);
    accessory.textView.selectable = YES;
    accessory.requestLayout = ^{
        [alert layout];
    };
    alert.accessoryView = accessory;

    [alert addButtonWithTitle:@"Deny"];
    [alert addButtonWithTitle:@"Allow"];
    if (!reauth) {
        // Reauth is always persistent so don't show the button.
        alert.suppressionButton.title = @"Remember my selection";
        alert.showsSuppressionButton = YES;
    }
    NSModalResponse response = [alert runModal];
    *remember = (alert.suppressionButton.state == NSOnState);
    return (response == NSAlertSecondButtonReturn);
}

- (NSDictionary *)apiServerAuthorizeProcess:(pid_t)pid
                              preauthorized:(BOOL)preauthorized
                                     reason:(out NSString *__autoreleasing *)reason
                                displayName:(out NSString *__autoreleasing *)displayName {
    iTermAPIAuthorizationController *controller = [[iTermAPIAuthorizationController alloc] initWithProcessID:pid];
    *reason = [controller identificationFailureReason];
    if (*reason) {
        return nil;
    }
    *displayName = controller.humanReadableName;

    if (preauthorized) {
        *reason = @"Script launched by user action";
        return controller.identity;
    }


    BOOL reauth = NO;
    switch (controller.setting) {
        case iTermAPIAuthorizationSettingPermanentlyDenied:
            // Access permanently disallowed.
            *reason = [NSString stringWithFormat:@"Access permanently disallowed by user preference to %@",
                       controller.fullCommandOrBundleID];
            return nil;

        case iTermAPIAuthorizationSettingRecentConsent:
            // No need to reauth, allow it.
            *reason = [NSString stringWithFormat:@"Allowing continued API access to process id %d, name %@, bundle ID %@. User gave consent recently.",
                       pid, controller.humanReadableName, controller.fullCommandOrBundleID];
            return controller.identity;

        case iTermAPIAuthorizationSettingExpiredConsent:
            // It's been a month since API access was confirmed. Request it again.
            reauth = YES;
            break;

        case iTermAPIAuthorizationSettingUnknown:
            break;
    }

    BOOL remember = NO;
    BOOL allow = [self askUserToGrantAuthForController:controller isReauthorization:reauth remember:&remember];

    if (reauth || remember) {
        [controller setAllowed:allow];
    } else {
        [controller removeSetting];
    }

    if (allow) {
        *reason = [NSString stringWithFormat:@"User accepted connection by %@", controller.fullCommandOrBundleID];
        return controller.identity;
    } else {
        *reason = [NSString stringWithFormat:@"User rejected connection attempt by %@", controller.fullCommandOrBundleID];
        return nil;
    }
}

- (PTYSession *)sessionForAPIIdentifier:(NSString *)identifier includeBuriedSessions:(BOOL)includeBuriedSessions {
    if ([identifier isEqualToString:@"active"]) {
        return [[[iTermController sharedInstance] currentTerminal] currentSession];
    } else if (identifier) {
        for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
            for (PTYSession *session in term.allSessions) {
                if ([session.guid isEqualToString:identifier]) {
                    return session;
                }
            }
        }
        if (includeBuriedSessions) {
            for (PTYSession *session in [[iTermBuriedSessions sharedInstance] buriedSessions]) {
                if ([session.guid isEqualToString:identifier]) {
                    return session;
                }
            }
        }
    }
    return nil;
}

- (PTYTab *)tabWithID:(NSString *)tabID {
    if (tabID.length == 0) {
        return nil;
    }
    NSCharacterSet *nonNumericCharacterSet = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([tabID rangeOfCharacterFromSet:nonNumericCharacterSet].location != NSNotFound) {
        return nil;
    }

    int numericID = tabID.intValue;
    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        for (PTYTab *tab in term.tabs) {
            if (tab.uniqueId == numericID) {
                return tab;
            }
        }
    }
    return nil;
}

- (void)apiServerGetBuffer:(ITMGetBufferRequest *)request
                   handler:(void (^)(ITMGetBufferResponse *))handler {
    PTYSession *session = [self sessionForAPIIdentifier:request.session includeBuriedSessions:YES];
    if (!session) {
        ITMGetBufferResponse *response = [[ITMGetBufferResponse alloc] init];
        response.status = ITMGetBufferResponse_Status_SessionNotFound;
        handler(response);
    } else {
        handler([session handleGetBufferRequest:request]);
    }
}

- (void)apiServerGetPrompt:(ITMGetPromptRequest *)request
                   handler:(void (^)(ITMGetPromptResponse *))handler {
    PTYSession *session = [self sessionForAPIIdentifier:request.session includeBuriedSessions:YES];
    if (!session) {
        ITMGetPromptResponse *response = [[ITMGetPromptResponse alloc] init];
        response.status = ITMGetPromptResponse_Status_SessionNotFound;
        handler(response);
    } else {
        handler([session handleGetPromptRequest:request]);
    }
}

- (BOOL)rpcNotificationRequestIsValid:(ITMNotificationRequest *)request {
    if (request.argumentsOneOfCase != ITMNotificationRequest_Arguments_OneOfCase_RpcRegistrationRequest) {
        return NO;
    }
    return request.rpcRegistrationRequest.it_valid;
}

- (ITMNotificationResponse *)handleAPINotificationRequest:(ITMNotificationRequest *)request connection:(id)connection {
    ITMNotificationResponse *response = [[ITMNotificationResponse alloc] init];
    if (!request.hasSubscribe) {
        response.status = ITMNotificationResponse_Status_RequestMalformed;
        return response;
    }
    if (!_newSessionSubscriptions) {
        _newSessionSubscriptions = [[NSMutableDictionary alloc] init];
        _terminateSessionSubscriptions = [[NSMutableDictionary alloc] init];
        _layoutChangeSubscriptions = [[NSMutableDictionary alloc] init];
        _focusChangeSubscriptions = [[NSMutableDictionary alloc] init];
        _serverOriginatedRPCSubscriptions = [[NSMutableDictionary alloc] init];
    }
    BOOL didRegisterRPC = NO;
    NSMutableDictionary<id, ITMNotificationRequest *> *subscriptions;
    if (request.notificationType == ITMNotificationType_NotifyOnNewSession) {
        subscriptions = _newSessionSubscriptions;
    } else if (request.notificationType == ITMNotificationType_NotifyOnTerminateSession) {
        subscriptions = _terminateSessionSubscriptions;
    } else if (request.notificationType == ITMNotificationType_NotifyOnLayoutChange) {
        subscriptions = _layoutChangeSubscriptions;
    } else if (request.notificationType == ITMNotificationType_NotifyOnFocusChange) {
        subscriptions = _focusChangeSubscriptions;
    } else if (request.notificationType == ITMNotificationType_NotifyOnServerOriginatedRpc) {
        if (!request.rpcRegistrationRequest.it_valid) {
            XLog(@"RPC signature not valid: %@", request.rpcRegistrationRequest);
            response.status = ITMNotificationResponse_Status_RequestMalformed;
            return response;
        }

        if (![self rpcNotificationRequestIsValid:request]) {
            XLog(@"RPC notification request invalid: %@", request);
            response.status = ITMNotificationResponse_Status_RequestMalformed;
            return response;
        }

        NSString *signatureString = request.rpcRegistrationRequest.it_stringRepresentation;
        subscriptions = _serverOriginatedRPCSubscriptions[signatureString];
        if (request.subscribe) {
            if (subscriptions.count > 0) {
                response.status = ITMNotificationResponse_Status_DuplicateServerOriginatedRpc;
                return response;
            }
            if (!subscriptions) {
                subscriptions = [NSMutableDictionary dictionary];
                _serverOriginatedRPCSubscriptions[signatureString] = subscriptions;
            }
            didRegisterRPC = YES;
        }
    } else {
        assert(false);
    }
    if (request.subscribe) {
        if (subscriptions[connection]) {
            response.status = ITMNotificationResponse_Status_AlreadySubscribed;
            return response;
        }
        subscriptions[connection] = request;
        if (didRegisterRPC) {
            [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIRegisteredFunctionsDidChangeNotification
                                                                object:nil];
            if (request.rpcRegistrationRequest.role == ITMRPCRegistrationRequest_Role_SessionTitle) {
                [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIDidRegisterSessionTitleFunctionNotification
                                                                    object:request.rpcRegistrationRequest.name];
            }
        }
    } else {
        if (!subscriptions[connection]) {
            response.status = ITMNotificationResponse_Status_NotSubscribed;
            return response;
        }
        [subscriptions removeObjectForKey:connection];
    }

    response.status = ITMNotificationResponse_Status_Ok;
    return response;
}

- (void)performBlockWhenFunctionRegisteredWithName:(NSString *)name
                                         arguments:(NSArray<NSString *> *)arguments
                                           timeout:(NSTimeInterval)timeout
                                             block:(void (^)(BOOL))block {
    if ([self haveRegisteredFunctionWithName:name arguments:arguments]) {
        block(NO);
        return;
    }

    __block BOOL called = NO;
    __block id observer =
        [[NSNotificationCenter defaultCenter] addObserverForName:iTermAPIRegisteredFunctionsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull notification) {
            if (called) {
                return;
            }
            if ([self haveRegisteredFunctionWithName:name arguments:arguments]) {
                called = YES;
                [[NSNotificationCenter defaultCenter] removeObserver:observer];
                block(NO);
            }
        }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!called) {
            called = YES;
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
            block(YES);
        }
    });
}


- (NSArray<PTYSession *> *)allSessions {
    return [[[iTermController sharedInstance] terminals] flatMapWithBlock:^id(PseudoTerminal *windowController) {
        return windowController.allSessions;
    }];
}

- (void)apiServerNotification:(ITMNotificationRequest *)request
                   connection:(id)connection
                      handler:(void (^)(ITMNotificationResponse *))handler {
    if (request.notificationType == ITMNotificationType_NotifyOnNewSession ||
        request.notificationType == ITMNotificationType_NotifyOnTerminateSession ||
        request.notificationType == ITMNotificationType_NotifyOnLayoutChange ||
        request.notificationType == ITMNotificationType_NotifyOnFocusChange ||
        request.notificationType == ITMNotificationType_NotifyOnServerOriginatedRpc) {
        handler([self handleAPINotificationRequest:request connection:connection]);
    } else if ([request.session isEqualToString:@"all"]) {
        iTermAllSessionsSubscription *sub = [[iTermAllSessionsSubscription alloc] init];
        sub.request = [request copy];
        sub.connection = connection;

        for (PTYSession *session in [self allSessions]) {
            ITMNotificationResponse *response = [session handleAPINotificationRequest:request connection:connection];
            if (response.status != ITMNotificationResponse_Status_AlreadySubscribed &&
                response.status != ITMNotificationResponse_Status_NotSubscribed &&
                response.status != ITMNotificationResponse_Status_Ok) {
                handler(response);
                return;
            }
        }
        ITMNotificationResponse *response = [[ITMNotificationResponse alloc] init];
        response.status = ITMNotificationResponse_Status_Ok;
        handler(response);
    } else {
        PTYSession *session = [self sessionForAPIIdentifier:request.session includeBuriedSessions:YES];
        if (!session) {
            ITMNotificationResponse *response = [[ITMNotificationResponse alloc] init];
            response.status = ITMNotificationResponse_Status_SessionNotFound;
            handler(response);
        } else {
            handler([session handleAPINotificationRequest:request connection:connection]);
        }
    }
}

- (void)removeAllSubscriptionsForConnection:(id)connectionKey {
    // Remove all notification subscriptions.
    NSArray<NSMutableDictionary<id, ITMNotificationRequest *> *> *rpcSubs =
        [_serverOriginatedRPCSubscriptions.allKeys mapWithBlock:^id(NSString *key) {
            return self->_serverOriginatedRPCSubscriptions[key];
        }];
    NSMutableDictionary *empty = [NSMutableDictionary dictionary];
    NSArray<NSMutableDictionary<id, ITMNotificationRequest *> *> *dicts =
    @[ _newSessionSubscriptions ?: empty,
       _terminateSessionSubscriptions  ?: empty,
       _layoutChangeSubscriptions ?: empty,
       _focusChangeSubscriptions ?: empty ];
    dicts = [dicts arrayByAddingObjectsFromArray:rpcSubs];
    [dicts enumerateObjectsUsingBlock:^(NSMutableDictionary<id,ITMNotificationRequest *> * _Nonnull dict, NSUInteger idx, BOOL * _Nonnull stop) {
        [dict removeObjectForKey:connectionKey];
    }];
    [_allSessionsSubscriptions removeObjectsPassingTest:^BOOL(iTermAllSessionsSubscription *sub) {
        return [sub.connection isEqual:connectionKey];
    }];
    if (rpcSubs.count) {
        [[NSNotificationCenter defaultCenter] postNotificationName:iTermAPIRegisteredFunctionsDidChangeNotification
                                                            object:nil];
    }
}

- (void)apiServerDidCloseConnection:(id)connection {
    [[NSNotificationCenter defaultCenter] postNotificationName:iTermRemoveAPIServerSubscriptionsNotification object:connection];

    // Clean up outstanding iterm2->script RPCs.
    NSSet<NSString *> *requestIDs = _outstandingRPCs[connection];
    [_outstandingRPCs removeObjectForKey:connection];
    for (NSString *requestID in requestIDs) {
        iTermServerOriginatedRPCCompletionBlock completion = _serverOriginatedRPCCompletionBlocks[requestID];
        // completion will be nil if it already timed out
        if (completion) {
            [_serverOriginatedRPCCompletionBlocks removeObjectForKey:requestID];
            completion(nil, [self rpcDispatchError:@"Script terminated during function call"
                                            detail:nil
                                      unregistered:YES]);
        }
    }

    [self removeAllSubscriptionsForConnection:connection];
}

- (void)apiServerRegisterTool:(ITMRegisterToolRequest *)request
                 peerIdentity:(NSDictionary *)peerIdentity
                      handler:(void (^)(ITMRegisterToolResponse *))handler {
    ITMRegisterToolResponse *response = [[ITMRegisterToolResponse alloc] init];
    if (!request.hasName || !request.hasIdentifier || !request.hasURL) {
        response.status = ITMRegisterToolResponse_Status_RequestMalformed;
        handler(response);
        return;
    }
    NSURL *url = [NSURL URLWithString:request.URL];
    if (!url || !url.host) {
        response.status = ITMRegisterToolResponse_Status_RequestMalformed;
        handler(response);
        return;
    }

    if ([[iTermToolbeltView builtInToolNames] containsObject:request.name]) {
        response.status = ITMRegisterToolResponse_Status_PermissionDenied;
        handler(response);
        return;
    }

    [iTermToolbeltView registerDynamicToolWithIdentifier:request.identifier
                                                    name:request.name
                                                     URL:request.URL
                               revealIfAlreadyRegistered:request.revealIfAlreadyRegistered];
    response.status = ITMRegisterToolResponse_Status_Ok;
    handler(response);
}

- (void)apiServerSetProfileProperty:(ITMSetProfilePropertyRequest *)request
                            handler:(void (^)(ITMSetProfilePropertyResponse *))handler {
    ITMSetProfilePropertyResponse *response = [[ITMSetProfilePropertyResponse alloc] init];
    ITMSetProfilePropertyResponse_Status (^setter)(id object, NSString *key, id value) = nil;
    NSMutableArray *objects = [NSMutableArray array];

    switch (request.targetOneOfCase) {
        case ITMSetProfilePropertyRequest_Target_OneOfCase_GPBUnsetOneOfCase: {
            response.status = ITMSetProfilePropertyResponse_Status_RequestMalformed;
            handler(response);
            return;
        }

        case ITMSetProfilePropertyRequest_Target_OneOfCase_GuidList: {
            setter = ^ITMSetProfilePropertyResponse_Status(id object, NSString *key, id value) {
                Profile *profile = object;
                [iTermProfilePreferences setObject:value forKey:key inProfile:profile model:[ProfileModel sharedInstance]];
                return ITMSetProfilePropertyResponse_Status_Ok;
            };
            for (NSString *guid in request.guidList.guidsArray) {
                Profile *profile = [[ProfileModel sharedInstance] bookmarkWithGuid:guid];
                if (!profile) {
                    response.status = ITMSetProfilePropertyResponse_Status_BadGuid;
                    handler(response);
                    return;
                }
                [objects addObject:profile];
            }
            break;
        }

        case ITMSetProfilePropertyRequest_Target_OneOfCase_Session: {
            setter = ^ITMSetProfilePropertyResponse_Status(id object, NSString *key, id value) {
                return [(PTYSession *)object handleSetProfilePropertyForKey:request.key value:value];
            };
            if ([request.session isEqualToString:@"all"]) {
                [objects addObjectsFromArray:[self allSessions]];
            } else {
                PTYSession *session = [self sessionForAPIIdentifier:request.session includeBuriedSessions:YES];
                if (!session) {
                    ITMSetProfilePropertyResponse *response = [[ITMSetProfilePropertyResponse alloc] init];
                    response.status = ITMSetProfilePropertyResponse_Status_SessionNotFound;
                    handler(response);
                    return;
                }
                [objects addObject:session];
            }
            break;
        }
    }

    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:[request.jsonValue dataUsingEncoding:NSUTF8StringEncoding]
                                               options:NSJSONReadingAllowFragments
                                                 error:&error];
    if (!value || error) {
        XLog(@"JSON parsing error %@ for value in request %@", error, request);
        ITMSetProfilePropertyResponse *response = [[ITMSetProfilePropertyResponse alloc] init];
        response.status = ITMSetProfilePropertyResponse_Status_RequestMalformed;
        handler(response);
    }

    for (id object in objects) {
        response.status = setter(object, request.key, value);
        if (response.status != ITMSetProfilePropertyResponse_Status_Ok) {
            handler(response);
            return;
        }
    }

    response.status = ITMSetProfilePropertyResponse_Status_Ok;
    handler(response);
}

- (void)apiServerGetProfileProperty:(ITMGetProfilePropertyRequest *)request
                            handler:(void (^)(ITMGetProfilePropertyResponse *))handler {
    PTYSession *session = [self sessionForAPIIdentifier:request.session includeBuriedSessions:YES];
    if (!session) {
        ITMGetProfilePropertyResponse *response = [[ITMGetProfilePropertyResponse alloc] init];
        response.status = ITMGetProfilePropertyResponse_Status_SessionNotFound;
        handler(response);
        return;
    }

    handler([session handleGetProfilePropertyForKeys:request.keysArray]);
}

- (void)apiServerListSessions:(ITMListSessionsRequest *)request
                      handler:(void (^)(ITMListSessionsResponse *))handler {
    handler([self newListSessionsResponse]);
}

- (ITMListSessionsResponse *)newListSessionsResponse {
    ITMListSessionsResponse *response = [[ITMListSessionsResponse alloc] init];
    for (PseudoTerminal *window in [[iTermController sharedInstance] terminals]) {
        ITMListSessionsResponse_Window *windowMessage = [[ITMListSessionsResponse_Window alloc] init];
        windowMessage.windowId = window.terminalGuid;
        NSRect frame = window.window.frame;
        windowMessage.frame.origin.x = frame.origin.x;
        windowMessage.frame.origin.y = frame.origin.y;
        windowMessage.frame.size.width = frame.size.width;
        windowMessage.frame.size.height = frame.size.height;

        for (PTYTab *tab in window.tabs) {
            ITMListSessionsResponse_Tab *tabMessage = [[ITMListSessionsResponse_Tab alloc] init];
            tabMessage.tabId = [@(tab.uniqueId) stringValue];
            tabMessage.root = [tab rootSplitTreeNode];

            [windowMessage.tabsArray addObject:tabMessage];
        }

        [response.windowsArray addObject:windowMessage];
    }
    for (PTYSession *session in [[iTermBuriedSessions sharedInstance] buriedSessions]) {
        ITMSessionSummary *sessionSummary = [[ITMSessionSummary alloc] init];
        sessionSummary.uniqueIdentifier = session.guid;
        sessionSummary.title = session.name;
        [response.buriedSessionsArray addObject:sessionSummary];
    }
    return response;
}

- (void)apiServerSendText:(ITMSendTextRequest *)request handler:(void (^)(ITMSendTextResponse *))handler {
    NSArray<PTYSession *> *sessions;
    if ([request.session isEqualToString:@"all"]) {
        sessions = [self allSessions];
    } else {
        PTYSession *session = [self sessionForAPIIdentifier:request.session includeBuriedSessions:YES];
        if (!session || session.exited) {
            ITMSendTextResponse *response = [[ITMSendTextResponse alloc] init];
            response.status = ITMSendTextResponse_Status_SessionNotFound;
            handler(response);
            return;
        }
        sessions = @[ session ];
    }

    for (PTYSession *session in sessions) {
        [session writeTask:request.text];
    }
    ITMSendTextResponse *response = [[ITMSendTextResponse alloc] init];
    response.status = ITMSendTextResponse_Status_Ok;
    handler(response);
}

- (void)apiServerCreateTab:(ITMCreateTabRequest *)request handler:(void (^)(ITMCreateTabResponse *))handler {
    PseudoTerminal *term = nil;
    if (request.hasWindowId) {
        term = [[iTermController sharedInstance] terminalWithGuid:request.windowId];
        if (!term) {
            ITMCreateTabResponse *response = [[ITMCreateTabResponse alloc] init];
            response.status = ITMCreateTabResponse_Status_InvalidWindowId;
            handler(response);
            return;
        }
    }

    Profile *profile = [[ProfileModel sharedInstance] defaultBookmark];
    if (request.hasProfileName) {
        profile = [[ProfileModel sharedInstance] bookmarkWithName:request.profileName];
        if (!profile) {
            ITMCreateTabResponse *response = [[ITMCreateTabResponse alloc] init];
            response.status = ITMCreateTabResponse_Status_InvalidProfileName;
            handler(response);
            return;
        }
    }

    PTYSession *session = [[iTermController sharedInstance] launchBookmark:profile
                                                                inTerminal:term
                                                                   withURL:nil
                                                          hotkeyWindowType:iTermHotkeyWindowTypeNone
                                                                   makeKey:YES
                                                               canActivate:YES
                                                                   command:nil
                                                                     block:^PTYSession *(Profile *profile, PseudoTerminal *term) {
                                                                         profile = [self profileByCustomizing:profile withProperties:request.customProfilePropertiesArray];
                                                                         return [term createTabWithProfile:profile withCommand:nil environment:nil];
                                                                     }];

    if (!session) {
        ITMCreateTabResponse *response = [[ITMCreateTabResponse alloc] init];
        response.status = ITMCreateTabResponse_Status_MissingSubstitution;
        handler(response);
        return;
    }

    term = [[iTermController sharedInstance] terminalWithSession:session];
    PTYTab *tab = [term tabForSession:session];

    ITMCreateTabResponse_Status status = ITMCreateTabResponse_Status_Ok;

    if (request.hasTabIndex) {
        NSInteger sourceIndex = [term indexOfTab:tab];
        if (term.numberOfTabs > request.tabIndex && sourceIndex != NSNotFound) {
            [term.tabBarControl moveTabAtIndex:sourceIndex toIndex:request.tabIndex];
        } else {
            status = ITMCreateTabResponse_Status_InvalidTabIndex;
        }
    }

    ITMCreateTabResponse *response = [[ITMCreateTabResponse alloc] init];
    response.status = status;
    response.windowId = term.terminalGuid;
    response.tabId = tab.uniqueId;
    response.sessionId = session.guid;
    handler(response);
}

- (void)apiServerSplitPane:(ITMSplitPaneRequest *)request handler:(void (^)(ITMSplitPaneResponse *))handler {
    NSArray<PTYSession *> *sessions;
    if ([request.session isEqualToString:@"all"]) {
        sessions = [self allSessions];
    } else {
        PTYSession *session = [self sessionForAPIIdentifier:request.session includeBuriedSessions:YES];
        if (!session || session.exited) {
            ITMSplitPaneResponse *response = [[ITMSplitPaneResponse alloc] init];
            response.status = ITMSplitPaneResponse_Status_SessionNotFound;
            handler(response);
            return;
        }
        sessions = @[ session ];
    }

    for (PTYSession *session in sessions) {
        PseudoTerminal *term = [[iTermController sharedInstance] terminalWithSession:session];
        if (!term) {
            ITMSplitPaneResponse *response = [[ITMSplitPaneResponse alloc] init];
            response.status = ITMSplitPaneResponse_Status_SessionNotFound;
            handler(response);
            return;
        }
    }

    Profile *profile = [[ProfileModel sharedInstance] defaultBookmark];
    if (request.hasProfileName) {
        profile = [[ProfileModel sharedInstance] bookmarkWithName:request.profileName];
        if (!profile) {
            ITMSplitPaneResponse *response = [[ITMSplitPaneResponse alloc] init];
            response.status = ITMSplitPaneResponse_Status_InvalidProfileName;
            handler(response);
            return;
        }
    }

    profile = [self profileByCustomizing:profile withProperties:request.customProfilePropertiesArray];
    if (!profile) {
        ITMSplitPaneResponse *response = [[ITMSplitPaneResponse alloc] init];
        response.status = ITMSplitPaneResponse_Status_MalformedCustomProfileProperty;
        handler(response);
        return;
    }

    ITMSplitPaneResponse *response = [[ITMSplitPaneResponse alloc] init];
    response.status = ITMSplitPaneResponse_Status_Ok;
    for (PTYSession *session in sessions) {
        PseudoTerminal *term = [[iTermController sharedInstance] terminalWithSession:session];
        PTYSession *newSession = [term splitVertically:request.splitDirection == ITMSplitPaneRequest_SplitDirection_Vertical
                                                before:request.before
                                               profile:profile
                                         targetSession:session];
        if (newSession == nil && !session.isTmuxClient) {
            response.status = ITMSplitPaneResponse_Status_CannotSplit;
        } else {
            [response.sessionIdArray addObject:newSession.guid];
        }
    }

    handler(response);
}

- (Profile *)profileByCustomizing:(Profile *)profile withProperties:(NSArray<ITMProfileProperty*> *)customProfilePropertiesArray {
    for (ITMProfileProperty *property in customProfilePropertiesArray) {
        id value = [NSJSONSerialization it_objectForJsonString:property.jsonValue];
        if (!value) {
            return nil;
        }
        profile = [profile dictionaryBySettingObject:value forKey:property.key];
    }
    return profile;
}

- (void)apiServerSetProperty:(ITMSetPropertyRequest *)request handler:(void (^)(ITMSetPropertyResponse *))handler {
    ITMSetPropertyResponse *response = [[ITMSetPropertyResponse alloc] init];
    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:[request.jsonValue dataUsingEncoding:NSUTF8StringEncoding]
                                               options:NSJSONReadingAllowFragments
                                                 error:&error];
    if (!value || error) {
        XLog(@"JSON parsing error %@ for value in request %@", error, request);
        ITMSetPropertyResponse *response = [[ITMSetPropertyResponse alloc] init];
        response.status = ITMSetPropertyResponse_Status_InvalidValue;
        handler(response);
    }
    switch (request.identifierOneOfCase) {
        case ITMSetPropertyRequest_Identifier_OneOfCase_GPBUnsetOneOfCase:
            response.status = ITMSetPropertyResponse_Status_InvalidTarget;
            handler(response);
            return;

        case ITMSetPropertyRequest_Identifier_OneOfCase_WindowId: {
            PseudoTerminal *term = [[iTermController sharedInstance] terminalWithGuid:request.windowId];
            if (!term) {
                response.status = ITMSetPropertyResponse_Status_InvalidTarget;
                handler(response);
                return;
            }
            response.status = [self setPropertyInWindow:term name:request.name value:value];
            handler(response);
        }

        case ITMSetPropertyRequest_Identifier_OneOfCase_SessionId: {
            if ([request.sessionId isEqualToString:@"all"]) {
                for (PTYSession *session in [self allSessions]) {
                    response.status = [self setPropertyInSession:session name:request.name value:value];
                    handler(response);
                }
            } else {
                PTYSession *session = [self sessionForAPIIdentifier:request.sessionId includeBuriedSessions:YES];
                if (!session) {
                    response.status = ITMSetPropertyResponse_Status_InvalidTarget;
                    handler(response);
                    return;
                }
                response.status = [self setPropertyInSession:session name:request.name value:value];
                handler(response);
            }
        }
    }
}

- (ITMSetPropertyResponse_Status)setPropertyInWindow:(PseudoTerminal *)term name:(NSString *)name value:(id)value {
    typedef ITMSetPropertyResponse_Status (^SetWindowPropertyBlock)(void);
    SetWindowPropertyBlock setFrame = ^ITMSetPropertyResponse_Status {
        NSDictionary *dict = [NSDictionary castFrom:value];
        NSDictionary *origin = dict[@"origin"];
        NSDictionary *size = dict[@"size"];
        NSNumber *x = origin[@"x"];
        NSNumber *y = origin[@"y"];
        NSNumber *width = size[@"width"];
        NSNumber *height = size[@"height"];
        if (!x || !y || !width || !height) {
            return ITMSetPropertyResponse_Status_InvalidValue;
        }
        NSRect rect = NSMakeRect(x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue);
        [term.window setFrame:rect display:YES];
        return ITMSetPropertyResponse_Status_Ok;
    };

    SetWindowPropertyBlock setFullScreen = ^ITMSetPropertyResponse_Status {
        NSNumber *number = [NSNumber castFrom:value];
        if (!number) {
            return ITMSetPropertyResponse_Status_InvalidValue;
        }
        BOOL fullscreen = number.boolValue;
        if (!!term.anyFullScreen == !!fullscreen) {
            return ITMSetPropertyResponse_Status_Ok;
        } else {
            [term toggleFullScreenMode:nil];
        }
        return ITMSetPropertyResponse_Status_Ok;
    };
    NSDictionary<NSString *, SetWindowPropertyBlock> *handlers =
        @{ @"frame": setFrame,
           @"fullscreen": setFullScreen };
    SetWindowPropertyBlock block = handlers[name];
    if (block) {
        return block();
    } else {
        return ITMSetPropertyResponse_Status_UnrecognizedName;
    }
}

- (ITMSetPropertyResponse_Status)setPropertyInSession:(PTYSession *)session name:(NSString *)name value:(id)value {
    typedef ITMSetPropertyResponse_Status (^SetSessionPropertyBlock)(void);
    SetSessionPropertyBlock setGridSize = ^ITMSetPropertyResponse_Status {
        NSDictionary *size = [NSDictionary castFrom:value];
        NSNumber *width = size[@"width"];
        NSNumber *height = size[@"height"];
        if (!width || !height) {
            return ITMSetPropertyResponse_Status_InvalidValue;
        }
        id<WindowControllerInterface> controller = session.delegate.parentWindow;
        BOOL ok = [controller sessionInitiatedResize:session width:width.integerValue height:height.integerValue];
        if (ok) {
            if ([controller isKindOfClass:[PseudoTerminal class]]) {
                return ITMSetPropertyResponse_Status_Ok;
            } else {
                return ITMSetPropertyResponse_Status_Deferred;
            }
        } else {
            return ITMSetPropertyResponse_Status_Impossible;
        }
    };
    SetSessionPropertyBlock setBuried = ^ITMSetPropertyResponse_Status {
        NSNumber *number = [NSNumber castFrom:value];
        if (!number) {
            return ITMSetPropertyResponse_Status_InvalidValue;
        }
        const BOOL shouldBeBuried = number.boolValue;
        const BOOL isBuried = [[[iTermBuriedSessions sharedInstance] buriedSessions] containsObject:session];
        if (shouldBeBuried == isBuried) {
            return ITMSetPropertyResponse_Status_Ok;
        }
        if (shouldBeBuried) {
            [session bury];
        } else {
            [[iTermBuriedSessions sharedInstance] restoreSession:session];
        }
        return ITMSetPropertyResponse_Status_Ok;
    };
    NSDictionary<NSString *, SetSessionPropertyBlock> *handlers =
        @{ @"grid_size": setGridSize,
           @"buried": setBuried,
         };
    SetSessionPropertyBlock block = handlers[name];
    if (block) {
        return block();
    } else {
        return ITMSetPropertyResponse_Status_UnrecognizedName;
    }
}

- (void)apiServerGetProperty:(ITMGetPropertyRequest *)request handler:(void (^)(ITMGetPropertyResponse *))handler {
    ITMGetPropertyResponse *response = [[ITMGetPropertyResponse alloc] init];
    switch (request.identifierOneOfCase) {
        case ITMGetPropertyRequest_Identifier_OneOfCase_GPBUnsetOneOfCase:
            response.status = ITMGetPropertyResponse_Status_InvalidTarget;
            handler(response);
            return;

        case ITMGetPropertyRequest_Identifier_OneOfCase_WindowId: {
            PseudoTerminal *term = [[iTermController sharedInstance] terminalWithGuid:request.windowId];
            if (!term) {
                response.status = ITMGetPropertyResponse_Status_InvalidTarget;
                handler(response);
                return;
            }
            NSString *jsonValue = [self getPropertyFromWindow:term name:request.name];
            if (jsonValue) {
                response.jsonValue = jsonValue;
                response.status = ITMGetPropertyResponse_Status_Ok;
            } else {
                response.status = ITMGetPropertyResponse_Status_UnrecognizedName;
            }
            handler(response);
        }

        case ITMGetPropertyRequest_Identifier_OneOfCase_SessionId: {
            PTYSession *session = [self sessionForAPIIdentifier:request.sessionId includeBuriedSessions:YES];
            if (!session) {
                response.status = ITMGetPropertyResponse_Status_InvalidTarget;
                handler(response);
                return;
            }
            NSString *jsonValue = [self getPropertyFromSession:session name:request.name];
            if (jsonValue) {
                response.jsonValue = jsonValue;
                response.status = ITMGetPropertyResponse_Status_Ok;
            } else {
                response.status = ITMGetPropertyResponse_Status_UnrecognizedName;
            }
            handler(response);
        }
    }
}

- (NSString *)getPropertyFromWindow:(PseudoTerminal *)term name:(NSString *)name {
    typedef NSString * (^GetWindowPropertyBlock)(void);

    GetWindowPropertyBlock getFrame = ^NSString * {
        NSRect frame = term.window.frame;
        NSDictionary *dict =
            @{ @"origin": @{ @"x": @(frame.origin.x),
                             @"y": @(frame.origin.y) },
               @"size": @{ @"width": @(frame.size.width),
                           @"height": @(frame.size.height) } };
        return [NSJSONSerialization it_jsonStringForObject:dict];
    };

    GetWindowPropertyBlock getFullScreen = ^NSString * {
        return term.anyFullScreen ? @"true" : @"false";
    };

    NSDictionary<NSString *, GetWindowPropertyBlock> *handlers =
        @{ @"frame": getFrame,
           @"fullscreen": getFullScreen };

    GetWindowPropertyBlock block = handlers[name];
    if (block) {
        return block();
    } else {
        return nil;
    }
}

- (NSString *)getPropertyFromSession:(PTYSession *)session name:(NSString *)name {
    typedef NSString * (^GetSessionPropertyBlock)(void);

    GetSessionPropertyBlock getGridSize = ^NSString * {
        NSDictionary *dict =
            @{ @"width": @(session.screen.width - 1),
               @"height": @(session.screen.height - 1) };
        return [NSJSONSerialization it_jsonStringForObject:dict];
    };
    GetSessionPropertyBlock getBuried = ^NSString * {
        BOOL isBuried = [[[iTermBuriedSessions sharedInstance] buriedSessions] containsObject:session];
        return [NSJSONSerialization it_jsonStringForObject:@(isBuried)];
    };

    NSDictionary<NSString *, GetSessionPropertyBlock> *handlers =
        @{ @"grid_size": getGridSize,
           @"buried": getBuried,
         };

    GetSessionPropertyBlock block = handlers[name];
    if (block) {
        return block();
    } else {
        return nil;
    }
}

- (void)apiServerInject:(ITMInjectRequest *)request handler:(void (^)(ITMInjectResponse *))handler {
    ITMInjectResponse *response = [[ITMInjectResponse alloc] init];
    for (NSString *sessionID in request.sessionIdArray) {
        if ([sessionID isEqualToString:@"all"]) {
            for (PTYSession *session in [self allSessions]) {
                [self inject:request.data_p into:session];
            }
            [response.statusArray addValue:ITMInjectResponse_Status_Ok];
        } else {
            PTYSession *session = [self sessionForAPIIdentifier:sessionID includeBuriedSessions:YES];
            if (session) {
                [self inject:request.data_p into:session];
                [response.statusArray addValue:ITMInjectResponse_Status_Ok];
            } else {
                [response.statusArray addValue:ITMInjectResponse_Status_SessionNotFound];
            }
        }
    }
    handler(response);
}

- (void)inject:(NSData *)data into:(PTYSession *)session {
    [session injectData:data];
}

- (void)apiServerActivate:(ITMActivateRequest *)request handler:(void (^)(ITMActivateResponse *))handler {
    ITMActivateResponse *response = [[ITMActivateResponse alloc] init];
    PTYSession *session;
    PTYTab *tab;
    PseudoTerminal *windowController;
    if (request.identifierOneOfCase == ITMActivateRequest_Identifier_OneOfCase_TabId) {
        for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
            tab = [term tabWithUniqueId:request.tabId.intValue];
            if (tab) {
                windowController = term;
                break;
            }
        }
        if (!tab) {
            response.status = ITMActivateResponse_Status_BadIdentifier;
            handler(response);
            return;
        }
    } else if (request.identifierOneOfCase == ITMActivateRequest_Identifier_OneOfCase_WindowId) {
        windowController = [[[iTermController sharedInstance] terminals] objectPassingTest:^BOOL(PseudoTerminal *element, NSUInteger index, BOOL *stop) {
            return [element.terminalGuid isEqual:request.windowId];
        }];
        if (!windowController) {
            response.status = ITMActivateResponse_Status_BadIdentifier;
            handler(response);
            return;
        }
    } else if (request.identifierOneOfCase == ITMActivateRequest_Identifier_OneOfCase_SessionId) {
        session = [self sessionForAPIIdentifier:request.sessionId includeBuriedSessions:YES];
        if (!session) {
            response.status = ITMActivateResponse_Status_BadIdentifier;
            handler(response);
            return;
        }
        if ([[[iTermBuriedSessions sharedInstance] buriedSessions] containsObject:session]) {
            [[iTermBuriedSessions sharedInstance] restoreSession:session];
        }
        tab = [session.delegate.realParentWindow tabForSession:session];
        if (!tab) {
            response.status = ITMActivateResponse_Status_BadIdentifier;
            handler(response);
            return;
        }
        windowController = [PseudoTerminal castFrom:tab.realParentWindow];
    }

    if (request.selectSession) {
        if (!session) {
            response.status = ITMActivateResponse_Status_InvalidOption;
            handler(response);
            return;
        }
        [tab setActiveSession:session];
        response.status = ITMActivateResponse_Status_Ok;
        handler(response);
    }

    if (request.selectTab) {
        if (!tab) {
            response.status = ITMActivateResponse_Status_InvalidOption;
            handler(response);
            return;
        }
        [windowController.tabView selectTabViewItemWithIdentifier:tab];
    }

    if (request.orderWindowFront) {
        if (!windowController) {
            response.status = ITMActivateResponse_Status_InvalidOption;
            handler(response);
            return;
        }
        [windowController.window makeKeyAndOrderFront:nil];
    }

    if (request.hasActivateApp) {
        NSApplicationActivationOptions options = 0;
        if (request.activateApp.raiseAllWindows) {
            options |= NSApplicationActivateAllWindows;
        }
        if (request.activateApp.ignoringOtherApps) {
            options |= NSApplicationActivateIgnoringOtherApps;
        }
        [[NSRunningApplication currentApplication] activateWithOptions:options];
    }

    response.status = ITMActivateResponse_Status_Ok;
    handler(response);
}

- (void)apiServerVariable:(ITMVariableRequest *)request handler:(void (^)(ITMVariableResponse *))handler {
    ITMVariableResponse *response = [[ITMVariableResponse alloc] init];
    const BOOL allSetNamesLegal = [request.setArray allWithBlock:^BOOL(ITMVariableRequest_Set *setRequest) {
        return [setRequest.name hasPrefix:@"user."];
    }];
    if (!allSetNamesLegal) {
        response.status = ITMVariableResponse_Status_InvalidName;
        handler(response);
        return;
    }
    if ([request.sessionId isEqualToString:@"all"]) {
        if (request.getArray_Count > 0) {
            response.status = ITMVariableResponse_Status_SessionNotFound;
            handler(response);
            return;
        }
        for (PTYSession *session in [self allSessions]) {
            [request.setArray enumerateObjectsUsingBlock:^(ITMVariableRequest_Set * _Nonnull setRequest, NSUInteger idx, BOOL * _Nonnull stop) {
                id value;
                if ([setRequest.value isEqual:@"null"]) {
                    value = nil;
                } else {
                    value = [NSJSONSerialization it_objectForJsonString:setRequest.value];
                }
                [session setVariableNamed:setRequest.name toValue:value];
            }];
        }
        response.status = ITMVariableResponse_Status_Ok;
        handler(response);
        return;
    }

    PTYSession *session = [self sessionForAPIIdentifier:request.sessionId includeBuriedSessions:YES];
    if (!session) {
        response.status = ITMVariableResponse_Status_SessionNotFound;
        handler(response);
        return;
    }

    [request.setArray enumerateObjectsUsingBlock:^(ITMVariableRequest_Set * _Nonnull setRequest, NSUInteger idx, BOOL * _Nonnull stop) {
        id value;
        if ([setRequest.value isEqual:@"null"]) {
            value = nil;
        } else {
            value = [NSJSONSerialization it_objectForJsonString:setRequest.value];
        }
        [session setVariableNamed:setRequest.name
                          toValue:value];
    }];
    [request.getArray enumerateObjectsUsingBlock:^(NSString * _Nonnull name, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([name isEqualToString:@"*"]) {
            [response.valuesArray addObject:[NSJSONSerialization it_jsonStringForObject:session.variables.legacyDictionaryExcludingGlobals]];
        } else {
            id obj = [NSJSONSerialization it_jsonStringForObject:[session.variables valueForVariableName:name]];
            NSString *value = obj ?: @"null";
            [response.valuesArray addObject:value];
        }
    }];
    handler(response);
}

- (void)apiServerSavedArrangement:(ITMSavedArrangementRequest *)request handler:(void (^)(ITMSavedArrangementResponse *))handler {
    switch (request.action) {
        case ITMSavedArrangementRequest_Action_Save:
            [self saveArrangementNamed:request.name windowID:request.windowId handler:handler];
            return;

        case ITMSavedArrangementRequest_Action_Restore:
            [self restoreArrangementNamed:request.name windowID:request.windowId handler:handler];
            return;
    }
    ITMSavedArrangementResponse *response = [[ITMSavedArrangementResponse alloc] init];
    response.status = ITMSavedArrangementResponse_Status_RequestMalformed;
    handler(response);
}

- (void)saveArrangementNamed:(NSString *)name
                    windowID:(NSString *)windowID
                     handler:(void (^)(ITMSavedArrangementResponse *))handler {
    ITMSavedArrangementResponse *response = [[ITMSavedArrangementResponse alloc] init];
    if (windowID.length) {
        PseudoTerminal *term = [[iTermController sharedInstance] terminalWithGuid:windowID];
        if (!term) {
            response.status = ITMSavedArrangementResponse_Status_WindowNotFound;
            handler(response);
            return;
        }

        [[iTermController sharedInstance] saveWindowArrangementForWindow:term name:name];
    } else {
        [[iTermController sharedInstance] saveWindowArrangmentForAllWindows:YES name:name];
    }
    response.status = ITMSavedArrangementResponse_Status_Ok;
    handler(response);
}

- (void)restoreArrangementNamed:(NSString *)name
                       windowID:(NSString *)windowID
                        handler:(void (^)(ITMSavedArrangementResponse *))handler {
    ITMSavedArrangementResponse *response = [[ITMSavedArrangementResponse alloc] init];
    PseudoTerminal *term = nil;
    if (windowID.length) {
        term = [[iTermController sharedInstance] terminalWithGuid:windowID];
        if (!term) {
            response.status = ITMSavedArrangementResponse_Status_WindowNotFound;
            handler(response);
            return;
        }
    }
    BOOL ok = [[iTermController sharedInstance] loadWindowArrangementWithName:name asTabsInTerminal:term];
    if (ok) {
        response.status = ITMSavedArrangementResponse_Status_Ok;
    } else {
        response.status = ITMSavedArrangementResponse_Status_ArrangementNotFound;
    }
    handler(response);
}

- (void)apiServerFocus:(ITMFocusRequest *)request handler:(void (^)(ITMFocusResponse *))handler {
    ITMFocusResponse *response = [[ITMFocusResponse alloc] init];

    ITMFocusChangedNotification *focusChange = [[ITMFocusChangedNotification alloc] init];
    focusChange.applicationActive = [NSApp isActive];
    [response.notificationsArray addObject:focusChange];

    focusChange = [[ITMFocusChangedNotification alloc] init];
    PseudoTerminal *term = [[iTermController sharedInstance] currentTerminal];
    focusChange.window = [[ITMFocusChangedNotification_Window alloc] init];
    if (term && term.window == NSApp.keyWindow) {
        focusChange.window.windowStatus = ITMFocusChangedNotification_Window_WindowStatus_TerminalWindowBecameKey;
    } else if (term) {
        focusChange.window.windowStatus = ITMFocusChangedNotification_Window_WindowStatus_TerminalWindowIsCurrent;
    } else {
        focusChange.window.windowStatus = ITMFocusChangedNotification_Window_WindowStatus_TerminalWindowResignedKey;
    }
    focusChange.window.windowId = term.terminalGuid;
    [response.notificationsArray addObject:focusChange];

    for (PseudoTerminal *term in [[iTermController sharedInstance] terminals]) {
        focusChange = [[ITMFocusChangedNotification alloc] init];
        PTYTab *tab = term.currentTab;
        focusChange.selectedTab = [@(tab.uniqueId) stringValue];
        [response.notificationsArray addObject:focusChange];

        for (PTYTab *tab in term.tabs) {
            focusChange = [[ITMFocusChangedNotification alloc] init];
            focusChange.session = tab.activeSession.guid;
            [response.notificationsArray addObject:focusChange];
        }
    }
    handler(response);
}

- (void)apiServerListProfiles:(ITMListProfilesRequest *)request handler:(void (^)(ITMListProfilesResponse *))handler {
    ITMListProfilesResponse *response = [[ITMListProfilesResponse alloc] init];
    NSArray<NSString *> *desiredProperties = nil;
    if (request.propertiesArray_Count > 0) {
        desiredProperties = request.propertiesArray;
    }
    NSSet<NSString *> *desiredGuids = nil;
    if (request.guidsArray_Count > 0) {
        desiredGuids = [NSSet setWithArray:request.guidsArray];
    }
    for (Profile *profile in [[ProfileModel sharedInstance] bookmarks]) {
        BOOL matches = NO;
        if (desiredGuids) {
            if ([desiredGuids containsObject:profile[KEY_GUID]]) {
                matches = YES;
            }
        } else {
            matches = YES;
        }
        if (matches) {
            ITMListProfilesResponse_Profile *responseProfile = [[ITMListProfilesResponse_Profile alloc] init];
            NSArray<NSString *> *keys = nil;
            if (desiredProperties == nil) {
                keys = [iTermProfilePreferences allKeys];
            } else {
                keys = desiredProperties;
            }
            for (NSString *key in keys) {
                id value = [iTermProfilePreferences objectForKey:key inProfile:profile];
                if (value) {
                    NSString *jsonString = [iTermProfilePreferences jsonEncodedValueForKey:key inProfile:profile];
                    if (jsonString) {
                        ITMProfileProperty *property = [[ITMProfileProperty alloc] init];
                        property.key = key;
                        property.jsonValue = jsonString;
                        [responseProfile.propertiesArray addObject:property];
                    }
                }
            }
            [response.profilesArray addObject:responseProfile];
        }
    }
    handler(response);
}

- (void)handleServerOriginatedRPCResult:(ITMServerOriginatedRPCResultRequest *)result {
    NSString *key = result.requestId;
    if (!key) {
        DLog(@"Bogus key %@", key);
        return;
    }

    iTermServerOriginatedRPCCompletionBlock block = _serverOriginatedRPCCompletionBlocks[key];
    if (!block) {
        // Could be a timeout already occurred.
        DLog(@"Key %@ doesn't match a pending RPC", key);
        return;
    }
    [_serverOriginatedRPCCompletionBlocks removeObjectForKey:key];

    id value = nil;
    NSDictionary *exception = nil;
    NSError *error = nil;

    switch (result.resultOneOfCase) {
        case ITMServerOriginatedRPCResultRequest_Result_OneOfCase_JsonValue:
            value = [NSJSONSerialization JSONObjectWithData:[result.jsonValue dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:NSJSONReadingAllowFragments
                                                      error:&error];
            if (!value || error) {
                value = nil;
                exception = @{ @"reason": [NSString stringWithFormat:@"Undecodable value: %@", error.localizedDescription] };
            }
            break;

        case ITMServerOriginatedRPCResultRequest_Result_OneOfCase_JsonException:
            exception = [NSJSONSerialization JSONObjectWithData:[result.jsonException dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:NSJSONReadingAllowFragments
                                                          error:&error];
            if (error) {
                exception = @{ @"reason": [NSString stringWithFormat:@"Undecodable exception: %@", error.localizedDescription] };
            } else {
                exception = [NSDictionary castFrom:exception] ?: @{ @"reason": @"Malformed exception" };
            }
            break;

        case ITMServerOriginatedRPCResultRequest_Result_OneOfCase_GPBUnsetOneOfCase:
            exception = @{ @"reason": @"Malformed result." };
            break;
    }

    if (exception) {
        block(nil, [self rpcDispatchError:exception[@"reason"]
                                   detail:exception[@"traceback"]
                             unregistered:NO]);
    } else {
        if ([NSNull castFrom:value]) {
            value = nil;
        }
        block(value, nil);
    }
}

- (void)apiServerServerOriginatedRPCResult:(ITMServerOriginatedRPCResultRequest *)request
                                   handler:(void (^)(ITMServerOriginatedRPCResultResponse *))handler {
    [self handleServerOriginatedRPCResult:request];
    ITMServerOriginatedRPCResultResponse *response = [[ITMServerOriginatedRPCResultResponse alloc] init];
    handler(response);

}

- (void)apiServerRestartSession:(ITMRestartSessionRequest *)request handler:(void (^)(ITMRestartSessionResponse *))handler {
    PTYSession *session = [self sessionForAPIIdentifier:request.sessionId includeBuriedSessions:YES];
    ITMRestartSessionResponse *response = [[ITMRestartSessionResponse alloc] init];
    if (!session) {
        response.status = ITMRestartSessionResponse_Status_SessionNotFound;
        handler(response);
        return;
    }

    if (!session.isRestartable) {
        response.status = ITMRestartSessionResponse_Status_SessionNotRestartable;
        handler(response);
        return;
    }

    if (request.onlyIfExited && !session.exited) {
        response.status = ITMRestartSessionResponse_Status_SessionNotRestartable;
        handler(response);
        return;
    }

    [session restartSession];
    response.status = ITMRestartSessionResponse_Status_Ok;
    handler(response);
    return;
}

- (void)apiServerMenuItem:(ITMMenuItemRequest *)request handler:(void (^)(ITMMenuItemResponse *))handler {
    ITMMenuItemResponse *response = [[ITMMenuItemResponse alloc] init];
    NSMenuItem *menuItem = nil;
    if (@available(macOS 10.12, *)) {
        menuItem = [self menuItemWithIdentifier:request.identifier inMenu:[NSApp mainMenu]];
    } else {
        menuItem = [self menuItemWithTitleParts:[request.identifier componentsSeparatedByString:@"."]
                                         inMenu:[NSApp mainMenu]];
    }
    if (!menuItem) {
        response.status = ITMMenuItemResponse_Status_BadIdentifier;
        handler(response);
        return;
    }
    if (!menuItem.enabled && !request.queryOnly) {
        response.status = ITMMenuItemResponse_Status_Disabled;
        handler(response);
        return;
    }
    response.checked = menuItem.state == NSOnState;
    response.enabled = menuItem.isEnabled;
    if (!request.queryOnly) {
        [NSApp sendAction:menuItem.action
                       to:menuItem.target
                     from:menuItem];
    }
    response.status = ITMMenuItemResponse_Status_Ok;
    handler(response);
}

static BOOL iTermCheckSplitTreesIsomorphic(ITMSplitTreeNode *node1, ITMSplitTreeNode *node2) {
    if (node1.vertical != node2.vertical) {
        return NO;
    }
    if (node1.linksArray_Count != node2.linksArray_Count) {
        return NO;
    }
    for (NSInteger i = 0; i < node1.linksArray_Count; i++) {
        ITMSplitTreeNode_SplitTreeLink *link1 = node1.linksArray[i];
        ITMSplitTreeNode_SplitTreeLink *link2 = node2.linksArray[i];
        if (link1.childOneOfCase == ITMSplitTreeNode_SplitTreeLink_Child_OneOfCase_GPBUnsetOneOfCase) {
            return NO;
        }
        if (link1.childOneOfCase != link2.childOneOfCase) {
            return NO;
        }
        if (link1.childOneOfCase == ITMSplitTreeNode_SplitTreeLink_Child_OneOfCase_Node) {
            if (!iTermCheckSplitTreesIsomorphic(link1.node, link2.node)) {
                return NO;
            }
        }
    }
    return YES;
}

- (void)apiServerSetTabLayout:(ITMSetTabLayoutRequest *)request handler:(void (^)(ITMSetTabLayoutResponse *))handler {
    ITMSetTabLayoutResponse *response = [[ITMSetTabLayoutResponse alloc] init];
    PTYTab *tab = [self tabWithID:request.tabId];
    if (!tab) {
        response.status = ITMSetTabLayoutResponse_Status_BadTabId;
        handler(response);
        return;
    }

    ITMSplitTreeNode *before = [tab rootSplitTreeNode];
    ITMSplitTreeNode *requested = request.root;

    if (!iTermCheckSplitTreesIsomorphic(before, requested)) {
        response.status = ITMSetTabLayoutResponse_Status_WrongTree;
        handler(response);
        return;
    }
    [tab setSizesFromSplitTreeNode:requested];

    response.status = ITMSetTabLayoutResponse_Status_Ok;
    handler(response);
}

@end
