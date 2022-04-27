/********* CDVbroadcaster.m Cordova Plugin Implementation *******/

#import "BEMTransitionNotifier.h"
#import "TripDiaryStateMachine.h"
#import "APPLocalNotification.h"
#import "BEMBuiltinUserCache.h"
#import "DataUtils.h"
#import "LocalNotificationManager.h"
#import "SimpleLocation.h"
#import "Transition.h"
#import "StatsEvent.h"

#define TRIP_STARTED @"trip_started"
#define TRIP_ENDED @"trip_ended"
#define TRACKING_STARTED @"tracking_started"
#define TRACKING_STOPPED @"tracking_stopped"

#define CONFIG_LIST_KEY @"config_list"
#define MUTED_LIST_KEY @"muted_list"

#define isNSNull(value) [value isKindOfClass:[NSNull class]]

@interface BEMTransitionNotifier () {
  // Member variables go here.
}

@property (nonatomic,strong) NSMutableDictionary *observerMap;
- (void)pluginInitialize;
- (void)fireGenericTransitionFor:(NSString*) transition withUserInfo:(NSDictionary*) userInfo;
- (void)notifyEvent:(NSString *)eventName data:(NSDictionary*)data;
- (void)addEventListener:(CDVInvokedUrlCommand*)command;
- (void)removeEventListener:(CDVInvokedUrlCommand*)command;

@end


@implementation BEMTransitionNotifier

- (void)pluginInitialize
{
    // TODO: We should consider adding a create statement to the init, similar
    // to android - then it doesn't matter if the pre-populated database is not
    // copied over.
    NSLog(@"BEMTransitionNotifier:pluginInitialize singleton -> initialize statemachine and delegate");
    __typeof(self) __weak weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:CFCTransitionNotificationName object:nil queue:nil
                                                  usingBlock:^(NSNotification* note) {
                                                      __typeof(self) __strong strongSelf = weakSelf;
                                                      [strongSelf fireGenericTransitionFor:(NSString*)note.object withUserInfo:note.userInfo];
                                                  }];
}

- (void)fireGenericTransitionFor:(NSString*) transition withUserInfo:(NSDictionary*) userInfo {
    [LocalNotificationManager addNotification:[NSString stringWithFormat:@"Received platform-specific notification %@", transition] showUI:FALSE];

    if (([transition isEqualToString:CFCTransitionExitedGeofence] ||
             [transition isEqualToString:CFCTransitionVisitEnded])) {
                NSDictionary* autogenData = [self getTripStartData];
                return [self postNativeAndNotify:TRIP_STARTED withData:autogenData];
    }
    
    // We want to generate the event on trip end detected because we transition from
    // trip end detected -> trip ended after the geofence creation is complete.
    // Even if geofence creation failed, the trip still ended.
    // and once the trip is ended we start pushing data right way
    // which means that we can't reliably read local data since it is being
    // actively pushed to the server.
    // This is still somewhat unreliable - if this is slow and the geofence creation is fast, we may still race. In that case, we will just skip the trip end notification for now. Also, need to check whether iOS notification processing is serial or parallel. If serial, we are saved.
    if ([transition isEqualToString:CFCTransitionTripEndDetected])
        //  || [transition isEqualToString:CFCTransitionTripEnded])
    {
        NSDictionary* autogenData = [self getTripStartEndData];
        if (autogenData != NULL) {
            return [self postNativeAndNotify:TRIP_ENDED withData:autogenData];
        } else {
            [LocalNotificationManager addNotification:[NSString stringWithFormat:@"autogenData == NULL, skipping generic transition"] showUI:FALSE];
        }
    }
    
    if ([transition isEqualToString:CFCTransitionTrackingStopped]) {
        return [self postNativeAndNotify:TRACKING_STOPPED withData:NULL];
}

    if ([transition isEqualToString:CFCTransitionStartTracking]) {
        return [self postNativeAndNotify:TRACKING_STARTED withData:NULL];
    }
}
    
- (void)postNativeAndNotify:(NSString*)genericTransition withData:(NSDictionary*)autogenData
{
    [LocalNotificationManager addNotification:[NSString stringWithFormat:@"Broadcasting generic transition %@ and generating notification", genericTransition] showUI:FALSE];

    [[NSNotificationCenter defaultCenter] postNotificationName:genericTransition
                                                        object:self
                                                      userInfo:autogenData];
    [self notifyEvent:genericTransition data:autogenData];
    return;
}

- (void)notifyEvent:(NSString *)eventName data:(NSDictionary*)autogenData
{
    [LocalNotificationManager addNotification:[NSString stringWithFormat:@"Generating all notifications for generic %@", eventName] showUI:FALSE];
    
    NSDictionary* notifyConfigWrapper = [[BuiltinUserCache database] getLocalStorage:eventName
                                                                        withMetadata:NO];
    if (notifyConfigWrapper == NULL) {
        [LocalNotificationManager addNotification:[NSString stringWithFormat:@"no configurations found for event %@, skipping notification", eventName] showUI:FALSE];
        return;
    }
    
    NSArray* notifyConfigs = notifyConfigWrapper[CONFIG_LIST_KEY];
    NSArray* mutedConfigs = notifyConfigWrapper[MUTED_LIST_KEY];
    
    for(int i=0; i < [notifyConfigs count]; i++) {
        NSMutableDictionary* currNotifyConfig = [notifyConfigs objectAtIndex:i];
        NSUInteger mutedIndex = [self findIndex:currNotifyConfig fromList:mutedConfigs];
        
        if (mutedIndex == NSNotFound) {
            [LocalNotificationManager addNotification:[NSString stringWithFormat:@"notification for event %@ and id %@ not muted, generate ", eventName, currNotifyConfig[@"id"]] showUI:FALSE];
            if (autogenData != NULL) { // we need to merge in the autogenerated data
                NSMutableDictionary *currData = currNotifyConfig[@"data"];
                if (currData == NULL) {
                    currData = [NSMutableDictionary new];
                    currNotifyConfig[@"data"] = currData;
                }
                [currData addEntriesFromDictionary:autogenData];
            }
            NSString* currNotifyString = [DataUtils saveToJSONString:currNotifyConfig];
            NSString *func = [NSString stringWithFormat:@"window.cordova.plugins.BEMTransitionNotification.dispatchIOSLocalNotification(%@);", currNotifyString];
            [LocalNotificationManager addNotification:[NSString stringWithFormat:@"generating notification for event %@ and id %@", eventName, currNotifyConfig[@"id"]] showUI:FALSE];
            
            [self.commandDelegate evalJs:func];
        } else {
            [LocalNotificationManager addNotification:[NSString stringWithFormat:@"notification for event %@ and id %@ muted, skip ", eventName, currNotifyConfig[@"id"]] showUI:FALSE];
        }
    }
}

- (NSDictionary*) getTripStartData
{
    NSMutableDictionary* retData = [NSMutableDictionary new];
    double currTime = [BuiltinUserCache getCurrentTimeSecs];
    NSArray* lastLocArray = [DataUtils getLastPoints:1];
    if ([lastLocArray count] == 0) {
        [LocalNotificationManager addNotification:[NSString stringWithFormat:@"lastLocArray.length = %lu while generating trip start event", [lastLocArray count]]];
        retData[@"start_ts"] = @(currTime);
    } else {
        SimpleLocation* lastLoc = lastLocArray[0];
        retData[@"start_ts"] = @(lastLoc.ts);
        retData[@"start_lat"] = @(lastLoc.latitude);
        retData[@"start_lng"] = @(lastLoc.longitude);
    }
    return retData;
}

- (NSDictionary*) getTripStartEndData
{
    NSMutableDictionary* retData = [NSMutableDictionary new];
    NSArray* lastLocArray = [DataUtils getLastPoints:1];
    if ([lastLocArray count] == 0) {
        StatsEvent* se = [[StatsEvent alloc] initForEvent:@"no_locations_while_ending_trip"];
        [[BuiltinUserCache database] putMessage:@"key.usercache.client_error" value:se];
        return NULL;
    }
    
    SimpleLocation* lastLoc = lastLocArray[0];
    retData[@"end_ts"] = @(lastLoc.ts);
    retData[@"end_lat"] = @(lastLoc.latitude);
    retData[@"end_lng"] = @(lastLoc.longitude);
    
    NSArray* lastFiveTransitions = [[BuiltinUserCache database] getLastMessage:@"key.usercache.transition" nEntries:5 wrapperClass:[Transition class]];
    Transition* endTransition = lastFiveTransitions[0];
    if (![endTransition.transition isEqualToString:CFCTransitionTripEndDetected]) {
        [LocalNotificationManager addNotification:[NSString stringWithFormat:@"endTransition = %@, notified before save?", endTransition.transition]];
    }

    if (![endTransition.transition isEqualToString:CFCTransitionTripEndDetected]) {
        StatsEvent* se = [[StatsEvent alloc] initForEvent:@"last_transition_is_not_trip_end_detected"];
        [[BuiltinUserCache database] putMessage:@"key.usercache.client_error" value:se];
        return NULL;
    }
    
    Transition* startTransition;
    Transition* beforeStartTransition;
    [self getStartBeforeStartTransitions:lastFiveTransitions
                               searchFor:CFCTransitionTripStarted
                  startTransitionPointer:&startTransition
            beforeStartTransitionPointer:&beforeStartTransition];

    SimpleLocation* firstLoc = [self getFirstPoint:startTransition];
    if (firstLoc == NULL) {
        StatsEvent* se = [[StatsEvent alloc] initForEvent:@"first_loc_null"];
        [[BuiltinUserCache database] putMessage:@"key.usercache.client_error" value:se];
        return NULL;
    }
    retData[@"start_ts"] = @(firstLoc.ts);
    retData[@"start_lat"] = @(firstLoc.latitude);
    retData[@"start_lng"] = @(firstLoc.longitude);
    return retData;
}

- (SimpleLocation*) getFirstPoint:(Transition*)startTransition
{
    // Handle the case that the startTransition has already been pushed (due to races)
    // or was never created (due to turning on geofencing)
    if (startTransition == NULL) {
        // No start transition, return oldest location
        NSArray* firstLocArray = [[BuiltinUserCache database]
                                  getFirstSensorData:@"key.usercache.filtered_location"
                                  nEntries:1
                                  wrapperClass:[SimpleLocation class]];
        if ([firstLocArray count] == 0) {
            StatsEvent* se = [[StatsEvent alloc] initForEvent:@"no_locations_while_ending_trip"];
            [[BuiltinUserCache database] putMessage:@"key.usercache.client_error" value:se];
            return NULL;
        }
        return firstLocArray[0];
    } else {
        // Find points around the start transition
        TimeQuery* tq = [TimeQuery new];
        tq.key = [[BuiltinUserCache database] getStatName:@"metadata.usercache.write_ts"];
        tq.startTs = startTransition.ts - 5 * 60; // 5 minutes before
        tq.endTs = startTransition.ts + 5 * 60; // 5 minutes after

        NSArray* firstLocArray = [[BuiltinUserCache database]
                                 getSensorDataForInterval:@"key.usercache.filtered_location"
                                 tq:tq
                                 wrapperClass:[SimpleLocation class]];
        if ([firstLocArray count] == 0) {
            // No points before the start transition - let's just fallback to the first
            // point in the database (which must then be after the startTransition)
            firstLocArray = [[BuiltinUserCache database]
                    getFirstSensorData:@"key.usercache.filtered_location"
                    nEntries:1
                    wrapperClass:[SimpleLocation class]];
            if ([firstLocArray count] == 0) {
                StatsEvent* se = [[StatsEvent alloc] initForEvent:@"no_locations_while_ending_trip"];
                [[BuiltinUserCache database] putMessage:@"key.usercache.client_error" value:se];
                return NULL;
            }
            SimpleLocation* firstLoc = firstLocArray[0];
            if (firstLoc.ts <= startTransition.ts) {
                StatsEvent* se = [[StatsEvent alloc] initForReading:@"first_loc_before_start_transition"
                    withReading:(firstLoc.ts - startTransition.ts)];
                [[BuiltinUserCache database] putMessage:@"key.usercache.client_error" value:se];
                return NULL;
            }
            return firstLoc;
        } else {
            // There are points around the start transition.
            // Return the last point before (preferable) or the first point after
            NSMutableArray* beforePoints = [NSMutableArray new];
            NSMutableArray* equalOrAfterPoints = [NSMutableArray new];
            [self splitArray:firstLocArray
                               atTs:startTransition.ts
                       beforePoints:beforePoints
                        afterPoints:equalOrAfterPoints];
            
            if ([beforePoints count] <= 0 && [equalOrAfterPoints count] <= 0) {
                StatsEvent* se = [[StatsEvent alloc] initForEvent:@"before_and_after_point_count_zero"];
                [[BuiltinUserCache database] putMessage:@"key.usercache.client_error" value:se];
                return NULL;
            }
            // Interval queries return points sorted in ascending order
            // So we either return the last point before or the first point after
            long beforeCount = [beforePoints count];
            if (beforeCount > 0) { // last point before
                return beforePoints[beforeCount - 1];
            } else { // first point after
                return equalOrAfterPoints[0];
            }
        }
    }
}

- (void) splitArray:(NSArray*)inArray atTs:(double)ts
           beforePoints:(NSMutableArray*)beforePoints afterPoints:(NSMutableArray*)equalOrAfterPoints
{
    for (int i = 0; i < [inArray count]; i++) {
        SimpleLocation* currLoc = inArray[i];
        if (currLoc.ts < ts) {
            [beforePoints addObject:currLoc];
        } else {
            [equalOrAfterPoints addObject:currLoc];
        }
    }
}

- (void) getStartBeforeStartTransitions:(NSArray*)lastFiveTransitions searchFor:(NSString*)startTransitionName startTransitionPointer:(Transition**)startTransition beforeStartTransitionPointer:(Transition**)beforeStartTransition
{
    for(int i=1; i < [lastFiveTransitions count]; i++) {
        Transition* currTransition = lastFiveTransitions[i];
        if ([currTransition.transition isEqualToString:startTransitionName]) {
            [LocalNotificationManager addNotification:[NSString stringWithFormat:@"found first geofence transition at index %d, setting it to the start", i]];
            *startTransition = currTransition;
            /*
             * We can't use the beforeStartTransition naively like this because before we get the
             * TRIP_STARTED transition, we get EXITED_GEOFENCE, maybe a couple of times, etc.
             * We really need to get the past "n" points and find the last TRIP_END_DETECTED.
             * Not sure that complexity is worth it, since on iOS we pretty much push as soon
             * as the trip is done. Let us revisit if we change that behavior.
             *
             
            if (i+1 < [lastFiveTransitions count]) {
                [LocalNotificationManager addNotification:[NSString stringWithFormat:@"found transition before that at index %d, setting it to the beforeStart", i]];
                *beforeStartTransition = lastFiveTransitions[i+1];
            } else {
                *beforeStartTransition = NULL;
            }
             */
            // Break here so that we don't end up with the start of the previous trip
            break;
        }
    }
}

-(NSUInteger)findIndex:(NSDictionary*)localNotifyConfig fromList:(NSArray*)currList
{
    // This handles the muted list case. muted list could be null if the event had never been muted
    if (currList == NULL) {
        return NSNotFound;
    }
    NSUInteger existingIndex = [currList indexOfObjectPassingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        // Note that the id is a long so == works. If we assume that it is a string, we would need to use isEqualToString
        return [obj[@"id"] isEqualToNumber:localNotifyConfig[@"id"]];
    }];
    return existingIndex;
}

-(void)addOrReplaceEntry:(NSDictionary*)localNotifyConfig
                forEvent:(NSString*)eventName
               withLabel:(NSString*)listName
{
    NSMutableDictionary* configWrapper = [[BuiltinUserCache database] getLocalStorage:eventName
                                                                         withMetadata:NO];

    NSMutableArray* currList;
    
    if (configWrapper == NULL) {
        configWrapper = [NSMutableDictionary new];
        currList = [NSMutableArray new];
        configWrapper[listName] = currList;
    } else {
        currList = configWrapper[listName];
        if (currList == NULL) {
            currList = [NSMutableArray new];
            configWrapper[listName] = currList;
        }
    }
    
    // Checking for the invariant
    assert(configWrapper != NULL && currList != NULL && configWrapper[listName] == currList);
    
    NSUInteger existingIndex = [self findIndex:localNotifyConfig fromList:currList];
    
    BOOL modified = YES;
    if (existingIndex == NSNotFound) {
        [LocalNotificationManager addNotification:[NSString stringWithFormat:@"new configuration, adding object with id %@", localNotifyConfig[@"id"]]];
        [currList addObject:localNotifyConfig];
    } else {
        if ([localNotifyConfig isEqualToDictionary:currList[existingIndex]]) {
            [LocalNotificationManager addNotification:[NSString stringWithFormat:@"configuration unchanged, skipping list modify"]];
            modified = NO;
        } else {
            [LocalNotificationManager addNotification:[NSString stringWithFormat:@"configuration changed, changing object at index %lu", existingIndex]];
            [currList setObject:localNotifyConfig atIndexedSubscript:existingIndex];
        }
    }

    if (modified) {
        [[BuiltinUserCache database] putLocalStorage:eventName jsonValue:configWrapper];
    }
}

- (void)removeEntry:(NSDictionary*)localNotifyConfig
           forEvent:(NSString*)eventName
          withLabel:(NSString*)listName
{
    NSMutableDictionary* configWrapper = [[BuiltinUserCache database] getLocalStorage:eventName
                                                                         withMetadata:NO];

    if (configWrapper != NULL) { // There is an existing entry for this event
        NSMutableArray* currList = configWrapper[listName];
        NSUInteger existingIndex = [self findIndex:localNotifyConfig fromList:currList];
        if (existingIndex != NSNotFound) { // There is an existing entry for this ID
            [LocalNotificationManager addNotification:[NSString stringWithFormat:@"removed obsolete notification at %lu", existingIndex]];
            [currList removeObjectAtIndex:existingIndex];
            if ([currList count] == 0) { // list size is now zero
                // Let us think about what we want to happen here. One thought might be that we want to
                // remove the entry iff both lists are empty. But then you could run into situations in which
                // there was a notification, it was muted, and then it was removed. Because the muted list still
                // had an entry, we would keep the (zombie) entry around.
                // So it seems like we should actually look at the list and treat the config list and the muted list
                // differently. Alternatively, we could document that you always need to unmute a list before deleting it
                // but that places additional (unnecessary) burden on the user.
                // So let's treat them separately for now and fix later if it is a problem
                if ([listName isEqualToString:CONFIG_LIST_KEY]) {
                    [LocalNotificationManager addNotification:[NSString stringWithFormat:@"config list size is now 0, removing entry for event %@", eventName]];
                    [[BuiltinUserCache database] removeLocalStorage:eventName];
                } else {
                    assert([listName isEqualToString:MUTED_LIST_KEY]);
                    [LocalNotificationManager addNotification:[NSString stringWithFormat:@"muted list size is now 0, removing list %@ for event %@", listName, eventName]];
                    [configWrapper removeObjectForKey:listName];
                    [[BuiltinUserCache database] putLocalStorage:eventName jsonValue:configWrapper];
                }
            } else {
                [LocalNotificationManager addNotification:[NSString stringWithFormat:@"saving list with size %lu", [currList count]]];
                [[BuiltinUserCache database] putLocalStorage:eventName jsonValue:configWrapper];
            }
        }
    }
}


- (void)addEventListener:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult;
    
    __block NSString* eventName = command.arguments[0];
    
    if (isNSNull(eventName)|| [eventName length] == 0) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"eventName is null or empty"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    __block NSDictionary* localNotifyConfig = command.arguments[1];
        
    if (isNSNull(localNotifyConfig) || [localNotifyConfig count] == 0) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"localNotifyConfig is null or empty"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
                                                                     
    [self addOrReplaceEntry:localNotifyConfig
                                   forEvent:eventName
                                  withLabel:CONFIG_LIST_KEY];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}



- (void)removeEventListener:(CDVInvokedUrlCommand*)command
{

    CDVPluginResult* pluginResult;

    __block NSString* eventName = command.arguments[0];
    
    if (isNSNull(eventName) || [eventName length] == 0) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"eventName is null or empty"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    __block NSDictionary* localNotifyConfig = command.arguments[1];
    
    if (isNSNull(localNotifyConfig) || [localNotifyConfig count] == 0) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"localNotifyConfig is null or empty"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
        
    [self removeEntry:localNotifyConfig forEvent:eventName withLabel:CONFIG_LIST_KEY];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    
}

- (void)enableEventListener:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult;
    
    __block NSString* eventName = command.arguments[0];
    
    if (isNSNull(eventName) || [eventName length] == 0) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"eventName is null or empty"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    __block NSDictionary* localNotifyConfig = command.arguments[1];
    
    if (isNSNull(localNotifyConfig) || [localNotifyConfig count] == 0) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"localNotifyConfig is null or empty"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    // enabling the listener means removing an entry from the muted list
    [self removeEntry:localNotifyConfig
                   forEvent:eventName
                  withLabel:MUTED_LIST_KEY];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)disableEventListener:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult;
    
    __block NSString* eventName = command.arguments[0];
    
    if (isNSNull(eventName) || eventName == nil || [eventName length] == 0) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"eventName is null"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    __block NSDictionary* localNotifyConfig = command.arguments[1];
    
    if (isNSNull(localNotifyConfig) || localNotifyConfig == nil || [localNotifyConfig count] == 0) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"localNotifyConfig is null or empty"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }
    
    // disabling the listener means adding an entry to the muted list
    [self addOrReplaceEntry:localNotifyConfig
             forEvent:eventName
            withLabel:MUTED_LIST_KEY];
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}


@end
