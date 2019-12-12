//
//  OARoutingHelper.m
//  OsmAnd
//
//  Created by Alexey Kulish on 09/07/2017.
//  Copyright © 2017 OsmAnd. All rights reserved.
//

#import "OARoutingHelper.h"
#import "OsmAndApp.h"
#import "OARouteProvider.h"
#import "OARouteCalculationResult.h"
#import "OAAppSettings.h"
#import "OAVoiceRouter.h"
#import "OAMapUtils.h"
#import "Localization.h"
#import "OATargetPointsHelper.h"
#import "OARouteCalculationParams.h"
#import "OAWaypointHelper.h"
#import "OARouteDirectionInfo.h"
#import "OATTSCommandPlayerImpl.h"
#import "OAGPXUIHelper.h"
#import "OAGPXTrackAnalysis.h"
#import "OAGPXDocument.h"

#import <Reachability.h>

#define POSITION_TOLERANCE 60
#define RECALCULATE_THRESHOLD_COUNT_CAUSING_FULL_RECALCULATE 3
#define RECALCULATE_THRESHOLD_CAUSING_FULL_RECALCULATE_INTERVAL 2 * 60

@interface OARoutingHelper()

@property (nonatomic) OARouteCalculationResult *route;

@property (nonatomic) NSThread *currentRunningJob;
@property (nonatomic) OARouteProvider *provider;
@property (nonatomic) OAVoiceRouter *voiceRouter;

@property (nonatomic) NSTimeInterval lastTimeEvaluatedRoute;
@property (nonatomic) NSString *lastRouteCalcError;
@property (nonatomic) NSString *lastRouteCalcErrorShort;
@property (nonatomic) long recalculateCountInInterval;
@property (nonatomic) NSTimeInterval evalWaitInterval;
@property (nonatomic) BOOL waitingNextJob;

- (void) showMessage:(NSString *)msg;
- (void) setNewRoute:(OARouteCalculationResult *)prevRoute res:(OARouteCalculationResult *)res start:(CLLocation *)start;

@end

@interface OARouteRecalculationThread : NSThread

@property (nonatomic) OARouteCalculationParams *params;
@property (nonatomic, readonly) BOOL paramsChanged;
@property (nonatomic) NSThread *prevRunningJob;

- (void) stopCalculation;
- (void) setWaitPrevJob:(NSThread *)prevRunningJob;

@end

@implementation OARouteRecalculationThread
{
    OARoutingHelper *_helper;
    OAAppSettings *_settings;
    OsmAndAppInstance _app;
}

- (instancetype)initWithName:(NSString *)name params:(OARouteCalculationParams *)params paramsChanged:(BOOL)paramsChanged helper:(OARoutingHelper *)helper
{
    self = [super init];
    if (self)
    {
        self.qualityOfService = NSQualityOfServiceUtility;
        
        self.name = name;
        _app = [OsmAndApp instance];
        _helper = helper;
        _settings = [OAAppSettings sharedManager];
        _params = params;
        _paramsChanged = paramsChanged;
        if (!params.calculationProgress)
        {
            params.calculationProgress = std::make_shared<RouteCalculationProgress>();
        }
    }
    return self;
}

- (void) stopCalculation
{
    _params.calculationProgress->cancelled = true;
}

- (void) setWaitPrevJob:(NSThread *)prevRunningJob
{
    _prevRunningJob = prevRunningJob;
}

- (void) main
{
    @synchronized (_helper)
    {
        _helper.currentRunningJob = self;
        _helper.waitingNextJob = _prevRunningJob != nil;
    }
    
    if (_prevRunningJob)
    {
        while (_prevRunningJob.executing)
        {
            [NSThread sleepForTimeInterval:.05];
        }
        @synchronized (_helper)
        {
            _helper.currentRunningJob = self;
            _helper.waitingNextJob = false;
        }
    }
    _helper.lastRouteCalcError = nil;
    _helper.lastRouteCalcErrorShort = nil;
    OARouteCalculationResult *res = [_helper.provider calculateRouteImpl:_params];
    if (_params.calculationProgress->isCancelled())
    {
        @synchronized (_helper)
        {
            _helper.currentRunningJob = nil;
        }
        return;
    }
    BOOL onlineSourceWithoutInternet = ![res isCalculated] && [OARouteService isOnline:_params.type] && [Reachability reachabilityForInternetConnection].currentReachabilityStatus == NotReachable;
    if (onlineSourceWithoutInternet && _settings.gpxRouteCalcOsmandParts)
    {
        if (_params.previousToRecalculate && [_params.previousToRecalculate isCalculated])
        {
            res = [_helper.provider recalculatePartOfflineRoute:res params:_params];
        }
    }
    OARouteCalculationResult *prev = _helper.route;
    @synchronized (_helper)
    {
        if ([res isCalculated])
        {
            _helper.route = res;
        }
        else
        {
            _helper.evalWaitInterval = MAX(3, _helper.evalWaitInterval * 3 / 2); // for Issue #3899
            _helper.evalWaitInterval = MIN(_helper.evalWaitInterval, 120);
        }
        _helper.currentRunningJob = nil;
    }
    if ([res isCalculated])
    {
        [_helper setNewRoute:prev res:res start:_params.start];
    }
    else if (onlineSourceWithoutInternet)
    {
        _helper.lastRouteCalcError = [NSString stringWithFormat:@"%@:\n%@", OALocalizedString(@"error_calculating_route"), OALocalizedString(@"internet_connection_required_for_online_route")];
        _helper.lastRouteCalcErrorShort = OALocalizedString(@"error_calculating_route");
        [_helper showMessage:_helper.lastRouteCalcError];
    }
    else
    {
        if (res.errorMessage)
        {
            _helper.lastRouteCalcError = [NSString stringWithFormat:@"%@:\n%@", OALocalizedString(@"error_calculating_route"), res.errorMessage];
            _helper.lastRouteCalcErrorShort = OALocalizedString(@"error_calculating_route");
            [_helper showMessage:_helper.lastRouteCalcError];
        }
        else
        {
            _helper.lastRouteCalcError = OALocalizedString(@"empty_route_calculated");
            _helper.lastRouteCalcErrorShort = OALocalizedString(@"empty_route_calculated");
            [_helper showMessage:_helper.lastRouteCalcError];
        }
    }
    //app.getNotificationHelper().refreshNotification(NAVIGATION); TODO notification
    _helper.lastTimeEvaluatedRoute = [[NSDate date] timeIntervalSince1970];
}

@end

@implementation OARoutingHelper
{
    NSMutableArray<id<OARouteInformationListener>> *_listeners;

    OsmAndAppInstance _app;
    OAAppSettings *_settings;
    
    BOOL _isFollowingMode;
    BOOL _isRoutePlanningMode;
    BOOL _isPauseNavigation;
    
    OAGPXRouteParamsBuilder *_currentGPXRoute;
    
    CLLocation *_finalLocation;
    NSMutableArray<CLLocation *> *_intermediatePoints;
    CLLocation *_lastProjection;
    CLLocation *_lastFixedLocation;
    
    OAApplicationMode *_mode;
    
    NSTimeInterval _deviateFromRouteDetected;
    //long _wrongMovementDetected;
    BOOL _voiceRouterStopped;
    
    NSMutableArray<id<OARouteCalculationProgressCallback>> *_progressRoutes;
}

static BOOL _isDeviatedFromRoute = false;

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _app = [OsmAndApp instance];
        _settings = [OAAppSettings sharedManager];

        _listeners = [NSMutableArray array];
        _route = [[OARouteCalculationResult alloc] initWithErrorMessage:@""];
        
        _voiceRouter = [[OAVoiceRouter alloc] initWithHelper:self];
        [_voiceRouter setPlayer:[[OATTSCommandPlayerImpl alloc] initWithVoiceRouter:_voiceRouter voiceProvider:_settings.voiceProvider]];
        _provider = [[OARouteProvider alloc] init];
        [self setAppMode:_settings.applicationMode];
        _progressRoutes = [NSMutableArray new];
    }
    return self;
}

+ (OARoutingHelper *) sharedInstance
{
    static OARoutingHelper *_sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[OARoutingHelper alloc] init];
    });
    return _sharedInstance;
}

- (void) setAppMode:(OAApplicationMode *)mode
{
    _mode = mode;
    [_voiceRouter updateAppMode];
}

- (OAApplicationMode *) getAppMode
{
    return _mode;
}

- (BOOL) isFollowingMode
{
    return _isFollowingMode;
}

- (OAVoiceRouter *) getVoiceRouter
{
    return _voiceRouter;
}

- (NSString *) getLastRouteCalcError
{
    return _lastRouteCalcError;
}

- (NSString *) getLastRouteCalcErrorShort
{
    return _lastRouteCalcErrorShort;
}

- (void) setPauseNaviation:(BOOL) b
{
    _isPauseNavigation = b;
    if (b)
    {
        // TODO notifications
        //app.getNotificationHelper().updateTopNotification();
        //app.getNotificationHelper().refreshNotifications();
    }
}

- (BOOL) isPauseNavigation
{
    return _isPauseNavigation;
}

- (void) setFollowingMode:(BOOL)follow
{
    _isFollowingMode = follow;
    _isPauseNavigation = false;
    if (!follow)
    {
        // TODO notifications
        //app.getNotificationHelper().updateTopNotification();
        //app.getNotificationHelper().refreshNotifications();
    }
}

- (BOOL) isRoutePlanningMode
{
    return _isRoutePlanningMode;
}

- (void) setRoutePlanningMode:(BOOL)isRoutePlanningMode
{
    _isRoutePlanningMode = isRoutePlanningMode;
}

- (BOOL) isRouteCalculated
{
    return [_route isCalculated];
}

- (BOOL) isRouteBeingCalculated
{
    return [_currentRunningJob isKindOfClass:[OARouteRecalculationThread class]] || _waitingNextJob;
}

- (void) addListener:(id<OARouteInformationListener>)l
{
    @synchronized (_listeners)
    {
        if (![_listeners containsObject:l])
            [_listeners addObject:l];
    }
}

- (OABBox) getBBox
{
    double left = DBL_MAX;
    double top = DBL_MAX;
    double right = DBL_MAX;
    double bottom = DBL_MAX;
    if ([self isRouteCalculated])
    {
        NSArray<CLLocation *> *locations = [_route getImmutableAllLocations];
        
        for (CLLocation *loc : locations)
        {
            if (left == DBL_MAX)
            {
                left = loc.coordinate.longitude;
                right = loc.coordinate.longitude;
                top = loc.coordinate.latitude;
                bottom = loc.coordinate.latitude;
            }
            else
            {
                left = MIN(left, loc.coordinate.longitude);
                right = MAX(right, loc.coordinate.longitude);
                top = MAX(top, loc.coordinate.latitude);
                bottom = MIN(bottom, loc.coordinate.latitude);
            }
        }
    }
    OABBox result;
    result.bottom = bottom;
    result.top = top;
    result.left = left;
    result.right = right;
    return result;
}

- (BOOL) removeListener:(id<OARouteInformationListener>)lt
{
    @synchronized (_listeners)
    {
        BOOL result = NO;
        NSMutableArray<id<OARouteInformationListener>> *inactiveListeners = [NSMutableArray array];
        for (id<OARouteInformationListener> l in _listeners)
        {
            if (!l || lt == l)
            {
                [inactiveListeners addObject:l];
                result = YES;
            }
        }
        [_listeners removeObjectsInArray:inactiveListeners];
        
        return result;
    }
}

- (void) addProgressBar:(id<OARouteCalculationProgressCallback>)progressRoute
{
    [_progressRoutes addObject:progressRoute];
}

+ (int) lookAheadFindMinOrthogonalDistance:(CLLocation *)currentLocation routeNodes:(NSArray<CLLocation *> *)routeNodes currentRoute:(int)currentRoute iterations:(int)iterations
{
    double newDist;
    double dist = DBL_MAX;
    int index = currentRoute;
    while (iterations > 0 && currentRoute + 1 < routeNodes.count)
    {
        newDist = [OAMapUtils getOrthogonalDistance:currentLocation fromLocation:routeNodes[currentRoute] toLocation:routeNodes[currentRoute + 1]];
        if (newDist < dist)
        {
            index = currentRoute;
            dist = newDist;
        }
        currentRoute++;
        iterations--;
    }
    return index;
}

- (void) setNewRoute:(OARouteCalculationResult *)prevRoute res:(OARouteCalculationResult *)res start:(CLLocation *)start
{
    BOOL newRoute = ![prevRoute isCalculated];
    if (_isFollowingMode)
    {
        if (_lastFixedLocation)
            start = _lastFixedLocation;
        
        // try remove false route-recalculated prompts by checking direction to second route node
        BOOL wrongMovementDirection = false;
        NSArray<CLLocation *> *routeNodes = [res getImmutableAllLocations];
        if (routeNodes && routeNodes.count > 0)
        {
            int newCurrentRoute = [self.class lookAheadFindMinOrthogonalDistance:start routeNodes:routeNodes currentRoute:res.currentRoute iterations:15];
            if (newCurrentRoute + 1 < routeNodes.count)
            {
                // This check is valid for Online/GPX services (offline routing is aware of route direction)
                wrongMovementDirection = [self checkWrongMovementDirection:start nextRouteLocation:routeNodes[newCurrentRoute + 1]];
                // set/reset evalWaitInterval only if new route is in forward direction
                if (wrongMovementDirection)
                {
                    _evalWaitInterval = 3;
                }
                else
                {
                    _evalWaitInterval = MAX(3, _evalWaitInterval * 3 / 2);
                    _evalWaitInterval = MIN(_evalWaitInterval, 120);
                }
            }
        }
        // trigger voice prompt only if new route is in forward direction
        // If route is in wrong direction after one more setLocation it will be recalculated
        if (!wrongMovementDirection || newRoute)
            [_voiceRouter newRouteIsCalculated:newRoute];
    }
    
    [[OAWaypointHelper sharedInstance] setNewRoute:res];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized (_listeners)
        {
            NSMutableArray<id<OARouteInformationListener>> *inactiveListeners = [NSMutableArray array];
            for (id<OARouteInformationListener> l in _listeners)
            {
                if (l)
                    [l newRouteIsCalculated:newRoute];
                else
                    [inactiveListeners addObject:l];
            }
            [_listeners removeObjectsInArray:inactiveListeners];
        }
    });
}

- (void) setFinalAndCurrentLocation:(CLLocation *)finalLocation intermediatePoints:(NSArray<CLLocation *> *)intermediatePoints currentLocation:(CLLocation *)currentLocation
{
    @synchronized (self)
    {
        OARouteCalculationResult *previousRoute = _route;
        [self clearCurrentRoute:finalLocation newIntermediatePoints:intermediatePoints];
        // to update route
        [self setCurrentLocation:currentLocation returnUpdatedLocation:NO previousRoute:previousRoute targetPointsChanged:YES];
    }
}

- (float) getArrivalDistance
{
    return (double)_settings.applicationMode.arrivalDistance * [_settings.arrivalDistanceFactor get];
}

- (void) showMessage:(NSString *)msg
{
    dispatch_async(dispatch_get_main_queue(), ^{
        // TODO toast
        // show message
    });
}

- (double) getRouteDeviation
{
    @synchronized(self)
    {
        if (!_route || [_route getImmutableAllDirections].count < 2 || _route.currentRoute == 0 || _route.currentRoute >= [_route getImmutableAllDirections].count)
            return 0;
        
        NSArray<CLLocation *> *routeNodes = [_route getImmutableAllLocations];
        return [OAMapUtils getOrthogonalDistance:_lastFixedLocation fromLocation:routeNodes[_route.currentRoute - 1] toLocation:routeNodes[_route.currentRoute]];
    }
}

- (OANextDirectionInfo *) getNextRouteDirectionInfo:(OANextDirectionInfo *)info toSpeak:(BOOL)toSpeak
{
    @synchronized(self)
    {
        OANextDirectionInfo *i = [_route getNextRouteDirectionInfo:info fromLoc:_lastProjection toSpeak:toSpeak];
        if (i)
            i.imminent = [_voiceRouter calculateImminent:i.distanceTo loc:_lastProjection];
        
        return i;
    }
}

- (OANextDirectionInfo *) getNextRouteDirectionInfoAfter:(OANextDirectionInfo *)previous to:(OANextDirectionInfo *)to toSpeak:(BOOL)toSpeak
{
    @synchronized(self)
    {
        OANextDirectionInfo *i = [_route getNextRouteDirectionInfoAfter:previous next:to toSpeak:toSpeak];
        if (i)
            i.imminent = [_voiceRouter calculateImminent:i.distanceTo loc:nil];

        return i;
    }
}

- (std::shared_ptr<RouteSegmentResult>) getCurrentSegmentResult
{
    return [_route getCurrentSegmentResult];
}


/**
 * Wrong movement direction is considered when between
 * current location bearing (determines by 2 last fixed position or provided)
 * and bearing from currentLocation to next (current) point
 * the difference is more than 60 degrees
 */
- (BOOL) checkWrongMovementDirection:(CLLocation *)currentLocation nextRouteLocation:(CLLocation *)nextRouteLocation
{
    // measuring without bearing could be really error prone (with last fixed location)
    // this code has an effect on route recalculation which should be detected without mistakes
    if (currentLocation.course >= 0 && nextRouteLocation)
    {
        float bearingMotion = currentLocation.course;
        float bearingToRoute = [currentLocation bearingTo:nextRouteLocation];
        double diff = degreesDiff(bearingMotion, bearingToRoute);
        if (ABS(diff) > 60.0)
        {
            // require delay interval since first detection, to avoid false positive
            //but leave out for now, as late detection is worse than false positive (it may reset voice router then cause bogus turn and u-turn prompting)
            //if (wrongMovementDetected == 0) {
            //	wrongMovementDetected = System.currentTimeMillis();
            //} else if ((System.currentTimeMillis() - wrongMovementDetected > 500)) {
            return true;
            //}
        }
        else
        {
            //wrongMovementDetected = 0;
            return false;
        }
    }
    //wrongMovementDetected = 0;
    return false;
}

- (BOOL) identifyUTurnIsNeeded:(CLLocation *)currentLocation posTolerance:(float)posTolerance
{
    if (!_finalLocation || !currentLocation || ![_route isCalculated])
        return false;
    
    BOOL isOffRoute = false;
    if (currentLocation.course >= 0)
    {
        auto bearingMotion = currentLocation.course;
        CLLocation *nextRoutePosition = [_route getNextRouteLocation];
        float bearingToRoute = [currentLocation bearingTo:nextRoutePosition];
        double diff = degreesDiff(bearingMotion, bearingToRoute);
        // 7. Check if you left the route and an unscheduled U-turn would bring you back (also Issue 863)
        // This prompt is an interim advice and does only sound if a new route in forward direction could not be found in x seconds
        if (ABS(diff) > 135.0)
        {
            float d = [currentLocation distanceFromLocation:nextRoutePosition];
            // 60m tolerance to allow for GPS inaccuracy
            if (d > posTolerance)
            {
                // require x sec continuous since first detection
                if (_deviateFromRouteDetected == 0)
                {
                    _deviateFromRouteDetected = [[NSDate date] timeIntervalSince1970];
                }
                else if ([[NSDate date] timeIntervalSince1970] - _deviateFromRouteDetected > 10)
                {
                    isOffRoute = true;
                    //log.info("bearingMotion is opposite to bearingRoute"); //$NON-NLS-1$
                }
            }
        }
        else
        {
            _deviateFromRouteDetected = 0;
        }
    }
    return isOffRoute;
}

- (void) updateProgress:(OARouteCalculationParams *)params
{
    if (_progressRoutes.count > 0)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            
            auto calculationProgress = params.calculationProgress;
            if ([self isRouteBeingCalculated])
            {
                float p = MAX(calculationProgress->distanceFromBegin, calculationProgress->distanceFromEnd);
                float all = calculationProgress->totalEstimatedDistance * 1.35f;
                if (all > 0)
                {
                    int t = (int) MIN(p * p / (all * all) * 100.0, 99);
                    for (id<OARouteCalculationProgressCallback> progressRoute in _progressRoutes)
                        [progressRoute updateProgress:t];
                }
                NSThread *t = _currentRunningJob;
                if ([t isKindOfClass:[OARouteRecalculationThread class]] && ((OARouteRecalculationThread *) t).params != params)
                {
                    // different calculation started
                    return;
                }
                else
                {
                    /* TODO
                    if (calculationProgress->requestPrivateAccessRouting)
                    {
                        [_progressRoute requestPrivateAccessRouting];
                    }
                     */
                    [self updateProgress:params];
                }
            }
            else
            {
                /* TODO
                if (calculationProgress->requestPrivateAccessRouting)
                {
                    [_progressRoute requestPrivateAccessRouting];
                }
                 */
                for (id<OARouteCalculationProgressCallback> progressRoute in _progressRoutes)
                    [progressRoute finish];
            }
        });
    }
}

- (void) recalculateRouteInBackground:(CLLocation *)start end:(CLLocation *)end intermediates:(NSArray<CLLocation *> *)intermediates gpxRoute:(OAGPXRouteParamsBuilder *)gpxRoute previousRoute:(OARouteCalculationResult *)previousRoute paramsChanged:(BOOL)paramsChanged onlyStartPointChanged:(BOOL)onlyStartPointChanged
{
    if (!start || !end)
        return;
    
    // do not evaluate very often
    if ((!_currentRunningJob && [[NSDate date] timeIntervalSince1970] - _lastTimeEvaluatedRoute > _evalWaitInterval)
        || paramsChanged || !onlyStartPointChanged)
    {
        if ([[NSDate date] timeIntervalSince1970] - _lastTimeEvaluatedRoute < RECALCULATE_THRESHOLD_CAUSING_FULL_RECALCULATE_INTERVAL)
        {
            _recalculateCountInInterval ++;
        }
        
        OARouteCalculationParams *params = [[OARouteCalculationParams alloc] init];
        params.start = start;
        params.end = end;
        params.intermediates = intermediates;
        params.gpxRoute = gpxRoute == nil ? nil : [gpxRoute build:start];
        params.onlyStartPointChanged = onlyStartPointChanged;
        if (_recalculateCountInInterval < RECALCULATE_THRESHOLD_COUNT_CAUSING_FULL_RECALCULATE || (gpxRoute && gpxRoute.passWholeRoute && _isDeviatedFromRoute))
        {
            params.previousToRecalculate = previousRoute;
        }
        else
        {
            _recalculateCountInInterval = 0;
        }
        params.leftSide = [OADrivingRegion isLeftHandDriving:_settings.drivingRegion];
        params.fast = [_settings.fastRouteMode get:_mode];
        params.type = (EOARouteService)[_settings.routerService get:_mode];
        params.mode = _mode;
        if (params.type == OSMAND)
        {
            params.calculationProgress = std::make_shared<RouteCalculationProgress>();
            [self updateProgress:params];
        }
        @synchronized (self)
        {
            NSThread *prevRunningJob = _currentRunningJob;
            OARouteRecalculationThread *newThread = [[OARouteRecalculationThread alloc] initWithName:@"Calculating route" params:params paramsChanged:paramsChanged helper:self];
            _currentRunningJob = newThread;
            if (prevRunningJob)
            {
                [newThread setWaitPrevJob:prevRunningJob];
            }
            [_currentRunningJob start];
        }
    }
}

- (BOOL) updateCurrentRouteStatus:(CLLocation *)currentLocation posTolerance:(float)posTolerance
{
    NSArray<CLLocation *> *routeNodes = [_route getImmutableAllLocations];
    int currentRoute = _route.currentRoute;
    // 1. Try to proceed to next point using orthogonal distance (finding minimum orthogonal dist)
    while (currentRoute + 1 < routeNodes.count)
    {
        double dist = [currentLocation distanceFromLocation:routeNodes[currentRoute]];
        if (currentRoute > 0)
            dist = [OAMapUtils getOrthogonalDistance:currentLocation fromLocation:routeNodes[currentRoute - 1] toLocation:routeNodes[currentRoute]];
        
        BOOL processed = false;
        // if we are still too far try to proceed many points
        // if not then look ahead only 3 in order to catch sharp turns
        BOOL longDistance = dist >= 250;
        int newCurrentRoute = [self.class lookAheadFindMinOrthogonalDistance:currentLocation routeNodes:routeNodes currentRoute:currentRoute iterations:longDistance ? 15 : 8];
        double newDist = [OAMapUtils getOrthogonalDistance:currentLocation fromLocation:routeNodes[newCurrentRoute] toLocation:routeNodes[newCurrentRoute + 1]];
        if (longDistance)
        {
            if (newDist < dist)
            {
                NSLog(@"Processed by distance : (new) %f (old) %f", newDist, dist);
                processed = true;
            }
        }
        else if (newDist < dist || newDist < 10)
        {
            // newDist < 10 (avoid distance 0 till next turn)
            if (dist > posTolerance)
            {
                processed = true;
                NSLog(@"Processed by distance : %f %f", newDist, dist);
            }
            else
            {
                // case if you are getting close to the next point after turn
                // but you have not yet turned (could be checked bearing)
                if (currentLocation.course >= 0 || _lastFixedLocation)
                {
                    float bearingToRoute = [currentLocation bearingTo:routeNodes[currentRoute]];
                    float bearingRouteNext = [routeNodes[newCurrentRoute] bearingTo:routeNodes[newCurrentRoute + 1]];
                    float bearingMotion = currentLocation.course >= 0 ? currentLocation.course : [_lastFixedLocation bearingTo:currentLocation];
                    double diff = ABS(degreesDiff(bearingMotion, bearingToRoute));
                    double diffToNext = ABS(degreesDiff(bearingMotion, bearingRouteNext));
                    if (diff > diffToNext)
                    {
                        NSLog(@"Processed point bearing deltas : %f %f", diff, diffToNext);
                        processed = true;
                    }
                }
            }
        }
        if (processed)
        {
            // that node already passed
            [_route updateCurrentRoute:newCurrentRoute + 1];
            currentRoute = newCurrentRoute + 1;
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @synchronized (_listeners)
                {
                    NSMutableArray<id<OARouteInformationListener>> *inactiveListeners = [NSMutableArray array];
                    for (id<OARouteInformationListener> l in _listeners)
                    {
                        if (l)
                            [l routeWasUpdated];
                        else
                            [inactiveListeners addObject:l];
                    }
                    [_listeners removeObjectsInArray:inactiveListeners];
                }
            });
            
            // TODO notifications
            //app.getNotificationHelper().refreshNotification(NotificationType.NAVIGATION);
        }
        else
        {
            break;
        }
    }
    
    // 2. check if intermediate found
    if ([_route getIntermediatePointsToPass]  > 0
        && [_route getDistanceToNextIntermediate:_lastFixedLocation] < [self getArrivalDistance] * 2.0 && !_isRoutePlanningMode)
    {
        [self showMessage:OALocalizedString(@"arrived_at_intermediate_point")];
        [_route passIntermediatePoint];
        OATargetPointsHelper *targets = [OATargetPointsHelper sharedInstance];
        NSString *name = @"";
        if (_intermediatePoints && _intermediatePoints.count > 0)
        {
            CLLocation *rm = _intermediatePoints[0];
            [_intermediatePoints removeObjectAtIndex:0];
            NSArray<OARTargetPoint *> *ll = [targets getIntermediatePointsNavigation];
            int ind = -1;
            for (int i = 0; i < ll.count; i++)
            {
                if (ll[i].point && [ll[i].point distanceFromLocation:rm] < 5)
                {
                    name = [ll[i] getOnlyName];
                    ind = i;
                    break;
                }
            }
            if (ind >= 0)
                [targets removeWayPoint:false index:ind];
        }
        if (_isFollowingMode)
            [_voiceRouter arrivedIntermediatePoint:name];
        
        // double check
        while (_intermediatePoints && [_route getIntermediatePointsToPass] < _intermediatePoints.count)
        {
            [_intermediatePoints removeObjectAtIndex:0];
        }
    }
    
    // 3. check if destination found
    CLLocation *lastPoint = routeNodes[routeNodes.count - 1];
    if (currentRoute > routeNodes.count - 3
        && [currentLocation distanceFromLocation:lastPoint] < [self getArrivalDistance]
        && !_isRoutePlanningMode)
    {
        //showMessage(app.getString(R.string.arrived_at_destination));
        OATargetPointsHelper *targets = [OATargetPointsHelper sharedInstance];
        OARTargetPoint *tp = [targets getPointToNavigate];
        NSString *description = tp == nil ? @"" : [tp getOnlyName];
        if (_isFollowingMode)
            [_voiceRouter arrivedDestinationPoint:description];
        
        BOOL onDestinationReached = true; //OsmandPlugin.onDestinationReached();
        //onDestinationReached &= app.getAppCustomization().onDestinationReached();
        if (onDestinationReached)
        {
            [self clearCurrentRoute:nil newIntermediatePoints:nil];
            [self setRoutePlanningMode:false];
            dispatch_async(dispatch_get_main_queue(), ^{
                /* TODO
                settings.LAST_ROUTING_APPLICATION_MODE = settings.APPLICATION_MODE.get();
                settings.APPLICATION_MODE.set(settings.DEFAULT_APPLICATION_MODE.get());
                 */
            });
            [self finishCurrentRoute];
            // targets.clearPointToNavigate(false);
            return true;
        }
        
    }
    return false;
}

- (CLLocation *) setCurrentLocation:(CLLocation *)currentLocation returnUpdatedLocation:(BOOL)returnUpdatedLocation previousRoute:(OARouteCalculationResult *)previousRoute targetPointsChanged:(BOOL)targetPointsChanged
{
    CLLocation *locationProjection = currentLocation;
    if (!_finalLocation || !currentLocation)
    {
        _isDeviatedFromRoute = false;
        return locationProjection;
    }
    float posTolerance = POSITION_TOLERANCE;
    if (currentLocation.horizontalAccuracy > 0)
        posTolerance = POSITION_TOLERANCE / 2 + currentLocation.horizontalAccuracy;
    
    BOOL calculateRoute = false;
    @synchronized (self)
    {
        _isDeviatedFromRoute = false;
        double distOrth = 0;
        
        // 0. Route empty or needs to be extended? Then re-calculate route.
        if ([_route isEmpty])
        {
            calculateRoute = true;
        }
        else
        {
            // 1. Update current route position status according to latest received location
            BOOL finished = [self updateCurrentRouteStatus:currentLocation posTolerance:posTolerance];
            if (finished)
                return nil;
            
            NSArray<CLLocation *> *routeNodes = [_route getImmutableAllLocations];
            int currentRoute = _route.currentRoute;
            
            // 2. Analyze if we need to recalculate route
            // >100m off current route (sideways)
            if (currentRoute > 0)
            {
                distOrth = [OAMapUtils getOrthogonalDistance:currentLocation fromLocation:routeNodes[currentRoute - 1] toLocation:routeNodes[currentRoute]];
                if (!_settings.disableOffrouteRecalc && (distOrth > (1.7 * posTolerance)))
                {
                    NSLog(@"Recalculate route, because correlation  : %f", distOrth);
                    _isDeviatedFromRoute = true;
                    calculateRoute = true;
                }
            }
            // 3. Identify wrong movement direction
            CLLocation *next = [_route getNextRouteLocation];
            BOOL wrongMovementDirection = [self checkWrongMovementDirection:currentLocation nextRouteLocation:next];
            if (!_settings.disableWrongDirectionRecalc && wrongMovementDirection && [currentLocation distanceFromLocation:routeNodes[currentRoute]] > (2 * posTolerance))
            {
                NSLog(@"Recalculate route, because wrong movement direction: %f", [currentLocation distanceFromLocation:routeNodes[currentRoute]]);
                _isDeviatedFromRoute = true;
                calculateRoute = true;
            }
            // 4. Identify if UTurn is needed
            if ([self identifyUTurnIsNeeded:currentLocation posTolerance:posTolerance])
                _isDeviatedFromRoute = true;
            
            // 5. Update Voice router
            // Do not update in route planning mode
            if (_isFollowingMode)
            {
                BOOL inRecalc = calculateRoute || [self isRouteBeingCalculated];
                if (!inRecalc && !wrongMovementDirection)
                {
                    [_voiceRouter updateStatus:currentLocation repeat:false];
                    _voiceRouterStopped = false;
                }
                else if (_isDeviatedFromRoute && !_voiceRouterStopped)
                {
                    [_voiceRouter interruptRouteCommands];
                    _voiceRouterStopped = true; // Prevents excessive execution of stop() code
                }
                if (distOrth > 350)
                {
                    [_voiceRouter announceOffRoute:distOrth];
                }
            }
            
            // calculate projection of current location
            if (currentRoute > 0)
            {
                CLLocation *nextLocation = routeNodes[currentRoute];
                CLLocation *project = [OAMapUtils getProjection:currentLocation fromLocation:routeNodes[currentRoute - 1] toLocation:routeNodes[currentRoute]];
                // we need to update bearing too
                float bearingTo = [OAMapUtils adjustBearing:[project bearingTo:nextLocation]];
                locationProjection = [[CLLocation alloc] initWithCoordinate:project.coordinate altitude:currentLocation.altitude horizontalAccuracy:0 verticalAccuracy:currentLocation.verticalAccuracy course:bearingTo speed:currentLocation.speed timestamp:[NSDate date]];
            }
        }
        _lastFixedLocation = currentLocation;
        _lastProjection = locationProjection;
    }
    
    if (calculateRoute)
    {
        [self recalculateRouteInBackground:currentLocation end:_finalLocation intermediates:_intermediatePoints gpxRoute:_currentGPXRoute previousRoute:[previousRoute isCalculated] ? previousRoute : nil paramsChanged:false onlyStartPointChanged:!targetPointsChanged];
    }
    else
    {
        NSThread *job = _currentRunningJob;
        if ([job isKindOfClass:[OARouteRecalculationThread class]])
        {
            OARouteRecalculationThread *thread = (OARouteRecalculationThread *) job;
            if (!thread.paramsChanged)
                [thread stopCalculation];
            
            if (_isFollowingMode)
                [_voiceRouter announceBackOnRoute];
        }
    }
    
    double projectDist = _mode.hasFastSpeed ? posTolerance : posTolerance / 2;
    if (returnUpdatedLocation && locationProjection && [currentLocation distanceFromLocation:locationProjection] < projectDist)
        return locationProjection;
    else
        return currentLocation;

    return nil;
}

- (CLLocation *) setCurrentLocation:(CLLocation *)currentLocation returnUpdatedLocation:(BOOL)returnUpdatedLocation
{
    return [self setCurrentLocation:currentLocation returnUpdatedLocation:returnUpdatedLocation previousRoute:_route targetPointsChanged:false];
}

- (NSString *) getCurrentName:(std::vector<std::shared_ptr<TurnType>>&)next
{
    @synchronized (self)
    {
        OANextDirectionInfo *n = [self getNextRouteDirectionInfo:[[OANextDirectionInfo alloc] init] toSpeak:true];
        CLLocation *l = _lastFixedLocation;
        float speed = 0;
        if (l && l.speed >=0)
            speed = l.speed;
        
        if (n.distanceTo > 0  && n.directionInfo && !n.directionInfo.turnType->isSkipToSpeak() &&
            [_voiceRouter isDistanceLess:speed dist:n.distanceTo etalon:_voiceRouter.PREPARE_DISTANCE * 0.75f defSpeed:0.f])
        {
            NSString *nm = n.directionInfo.streetName;
            NSString *rf = n.directionInfo.ref;
            NSString *dn = n.directionInfo.destinationName;
            if (!next.empty())
                next[0] = n.directionInfo.turnType;
            
            return [self.class formatStreetName:nm ref:rf destination:dn towards:@"»"];
        }
        auto rs = [_route getCurrentSegmentResult];
        if (rs)
        {
            NSString *name = [self getRouteSegmentStreetName:rs];
            if (name.length > 0)
                return name;
        }
        rs = [_route getNextStreetSegmentResult];
        if (rs)
        {
            NSString *name = [self getRouteSegmentStreetName:rs];
            if (name.length > 0)
            {
                if (!next.empty())
                    next[0] = TurnType::ptrValueOf(TurnType::C, false);

                return name;
            }
        }
        return nil;
    }
}


- (NSString *) getRouteSegmentStreetName:(std::shared_ptr<RouteSegmentResult>)rs
{
    string locale = _settings.settingPrefMapLanguage ? [_settings.settingPrefMapLanguage UTF8String] : "";
    BOOL transliterate = _settings.settingMapLanguageTranslit;
    NSString *nm = [NSString stringWithUTF8String:rs->object->getName(locale, transliterate).c_str()];
    NSString *rf = [NSString stringWithUTF8String:rs->object->getRef(locale, transliterate, rs->isForwardDirection()).c_str()];
    NSString *dn = [NSString stringWithUTF8String:rs->object->getDestinationName(locale, transliterate, rs->isForwardDirection()).c_str()];
    return [self.class formatStreetName:nm ref:rf destination:dn towards:@"»"];
}

- (std::vector<std::shared_ptr<RouteSegmentResult>>) getUpcomingTunnel:(float)distToStart
{
    return [_route getUpcomingTunnel:distToStart];
}

- (NSArray<CLLocation *> *) getCurrentCalculatedRoute
{
    return [_route getImmutableAllLocations];
}

- (OARouteCalculationResult *) getRoute
{
    return _route;
}

- (OAGPXTrackAnalysis *) getTrackAnalysis
{
    OAGPXDocument *gpx = [OAGPXUIHelper makeGpxFromRoute:_route];
    return [gpx getAnalysis:0];
}

- (int) getLeftDistance
{
    return [_route getDistanceToFinish:_lastFixedLocation];
}

- (int) getLeftDistanceNextIntermediate
{
    return [_route getDistanceToNextIntermediate:_lastFixedLocation];
}

- (int) getLeftTime
{
    return [_route getLeftTime:_lastFixedLocation];
}

- (int) getLeftTimeNextIntermediate
{
    return [_route getLeftTimeToNextIntermediate:_lastFixedLocation];
}

- (NSArray<OARouteDirectionInfo *> *) getRouteDirections
{
    return [_route getRouteDirections];
}

- (CLLocation *) getLocationFromRouteDirection:(OARouteDirectionInfo *)i
{
    return [_route getLocationFromRouteDirection:i];
}

+ (BOOL) isDeviatedFromRoute
{
    return _isDeviatedFromRoute;
}

- (void) clearCurrentRoute:(CLLocation *)newFinalLocation newIntermediatePoints:(NSArray<CLLocation *> *)newIntermediatePoints
{
    @synchronized (self)
    {
        _route = [[OARouteCalculationResult alloc] initWithErrorMessage:@""];
        _isDeviatedFromRoute = false;
        _evalWaitInterval = 0;

        [[OAWaypointHelper sharedInstance] setNewRoute:_route];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @synchronized (_listeners)
            {
                NSMutableArray<id<OARouteInformationListener>> *inactiveListeners = [NSMutableArray array];
                for (id<OARouteInformationListener> l in _listeners)
                {
                    if (l)
                        [l routeWasCancelled];
                    else
                        [inactiveListeners addObject:l];
                }
                [_listeners removeObjectsInArray:inactiveListeners];
            }
        });
        _finalLocation = newFinalLocation;
        _intermediatePoints = newIntermediatePoints ? [NSMutableArray arrayWithArray:newIntermediatePoints] : nil;
        if ([_currentRunningJob isKindOfClass:[OARouteRecalculationThread class]])
            [((OARouteRecalculationThread *) _currentRunningJob) stopCalculation];
        
        if (!newFinalLocation)
        {
            _settings.followTheRoute = false;
            _settings.followTheGpxRoute = nil;
            // clear last fixed location
            _lastProjection = nil;
            [self setFollowingMode:NO];
        }
    }
}

- (void) finishCurrentRoute
{
    @synchronized (self)
    {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @synchronized (_listeners)
            {
                NSMutableArray<id<OARouteInformationListener>> *inactiveListeners = [NSMutableArray array];
                for (id<OARouteInformationListener> l in _listeners)
                {
                    if (l)
                        [l routeWasFinished];
                    else
                        [inactiveListeners addObject:l];
                }
                [_listeners removeObjectsInArray:inactiveListeners];
            }
        });
    }
}

- (float) getCurrentMaxSpeed
{
    return [_route getCurrentMaxSpeed];
}

+ (NSString *) formatStreetName:(NSString *)name ref:(NSString *)ref destination:(NSString *)destination towards:(NSString *)towards
{
    //Hardy, 2016-08-05:
    //Now returns: (ref) + ((" ")+name) + ((" ")+"toward "+dest) or ""
    
    NSString *formattedStreetName = @"";
    if (ref && ref.length > 0)
        formattedStreetName = ref;
    
    if (name && name.length > 0)
    {
        if (formattedStreetName.length > 0)
            formattedStreetName = [formattedStreetName stringByAppendingString:@" "];
        
        formattedStreetName = [formattedStreetName stringByAppendingString:name];
    }
    if (destination && destination.length > 0)
    {
        if (formattedStreetName.length > 0)
            formattedStreetName = [formattedStreetName stringByAppendingString:@" "];
        
        formattedStreetName = [formattedStreetName stringByAppendingString:[NSString stringWithFormat:@"%@ %@",towards, destination]];
    }
    return [formattedStreetName stringByReplacingOccurrencesOfString:@";" withString:@", "];
}

- (CLLocation *) getLastProjection
{
    return _lastProjection;
}

- (OAGPXRouteParamsBuilder *) getCurrentGPXRoute
{
    return _currentGPXRoute;
}

- (void) setGpxParams:(OAGPXRouteParamsBuilder *)params
{
    _currentGPXRoute = params;
}

- (CLLocation *) getFinalLocation
{
    return _finalLocation;
}

- (void) recalculateRouteDueToSettingsChange
{
    [self clearCurrentRoute:_finalLocation newIntermediatePoints:_intermediatePoints];
    [self recalculateRouteInBackground:_lastFixedLocation end:_finalLocation intermediates:_intermediatePoints gpxRoute:_currentGPXRoute previousRoute:_route paramsChanged:YES onlyStartPointChanged:NO];
}

- (void) notifyIfRouteIsCalculated
{
    if ([_route isCalculated])
        [_voiceRouter newRouteIsCalculated:true];
}

@end
