//
//  OAMeasurementToolLayer.m
//  OsmAnd
//
//  Created by Paul on 22.10.2020.
//  Copyright © 2020 OsmAnd. All rights reserved.
//

#import "OAMeasurementToolLayer.h"
#import "OAMapLayersConfiguration.h"
#import "OARootViewController.h"
#import "OAMapViewController.h"
#import "OAMapRendererView.h"
#import "OARoutingHelper.h"
#import "OARouteCalculationResult.h"
#import "OAUtilities.h"
#import "OANativeUtilities.h"
#import "OAColors.h"
#import "OAAutoObserverProxy.h"

#import "OAGPXDocument.h"
#import "OAGPXDocumentPrimitives.h"
#import "OAMeasurementEditingContext.h"

#include <OsmAndCore.h>
#include <OsmAndCore/Utilities.h>
#include <OsmAndCore/GeoInfoDocument.h>
#include <OsmAndCore/Map/VectorLine.h>
#include <OsmAndCore/Map/VectorLineBuilder.h>
#include <OsmAndCore/Map/VectorLinesCollection.h>
#include <OsmAndCore/Map/MapMarker.h>
#include <OsmAndCore/Map/MapMarkerBuilder.h>
#include <OsmAndCore/Map/MapMarkersCollection.h>
#include <OsmAndCore/SkiaUtilities.h>
#include <SkCGUtils.h>


@implementation OAMeasurementToolLayer
{
    OARoutingHelper *_routingHelper;

    std::shared_ptr<OsmAnd::VectorLinesCollection> _collection;
    std::shared_ptr<OsmAnd::VectorLinesCollection> _lastLineCollection;
    
    std::shared_ptr<OsmAnd::MapMarkersCollection> _pointMarkers;
    std::shared_ptr<OsmAnd::MapMarkersCollection> _selectedMarkerCollection;
    
    std::shared_ptr<SkBitmap> _pointMarkerIcon;
    std::shared_ptr<SkBitmap> _selectedMarkerIcon;
    
    OsmAnd::PointI _cachedCenter;
    BOOL _isInMovingMode;
    
    BOOL _initDone;
}

- (NSString *) layerId
{
    return kRoutePlanningLayerId;
}

- (void) initLayer
{
    _routingHelper = [OARoutingHelper sharedInstance];
    
    _collection = std::make_shared<OsmAnd::VectorLinesCollection>();
    _lastLineCollection = std::make_shared<OsmAnd::VectorLinesCollection>();
    _pointMarkers = std::make_shared<OsmAnd::MapMarkersCollection>();
    _selectedMarkerCollection = std::make_shared<OsmAnd::MapMarkersCollection>();
    
    _pointMarkerIcon = [OANativeUtilities skBitmapFromPngResource:@"map_plan_route_point_normal"];
    _selectedMarkerIcon = [OANativeUtilities skBitmapFromPngResource:@"map_plan_route_point_movable"];
    
    _initDone = YES;
    
    [self.mapView addKeyedSymbolsProvider:_collection];
    [self.mapView addKeyedSymbolsProvider:_lastLineCollection];
    [self.mapView addKeyedSymbolsProvider:_pointMarkers];
    [self.mapView addKeyedSymbolsProvider:_selectedMarkerCollection];
}

- (void)updateDistAndBearing
{
    if (_delegate)
    {
        double distance = 0, bearing = 0;
        if (_editingCtx.getPointsCount > 0)
        {
            OAGpxTrkPt *lastPoint = _editingCtx.getPoints[_editingCtx.getPointsCount - 1];
            OsmAnd::LatLon centerLatLon = OsmAnd::Utilities::convert31ToLatLon(self.mapView.target31);
            distance = getDistance(lastPoint.getLatitude, lastPoint.getLongitude, centerLatLon.latitude, centerLatLon.longitude);
            CLLocation *loc1 = [[CLLocation alloc] initWithLatitude:lastPoint.getLatitude longitude:lastPoint.getLongitude];
            CLLocation *loc2 = [[CLLocation alloc] initWithLatitude:centerLatLon.latitude longitude:centerLatLon.longitude];
            bearing = [loc1 bearingTo:loc2];
        }
        [_delegate onMeasue:distance bearing:bearing];
    }
}

- (void)onMapFrameRendered
{
    [self updateLastPointToCenter];
    [self updateDistAndBearing];
}

- (void)buildLine:(OsmAnd::VectorLineBuilder &)builder collection:(std::shared_ptr<OsmAnd::VectorLinesCollection> &)collection linePoints:(const QVector<OsmAnd::PointI> &)linePoints {
    builder.setPoints(linePoints);
    const auto line = builder.buildAndAddToCollection(collection);
}

- (void)drawLines:(const QVector<OsmAnd::PointI> &)points collection:(std::shared_ptr<OsmAnd::VectorLinesCollection>&)collection
{
    if (points.size() < 2)
        return;
    
    OsmAnd::ColorARGB lineColor = _editingCtx.getLineColor;
    
    OsmAnd::VectorLineBuilder builder;
    builder.setBaseOrder(self.baseOrder)
    .setIsHidden(points.size() == 0)
    .setLineId(collection->getLines().size())
    .setLineWidth(30);
    
    builder.setFillColor(lineColor);

    [self buildLine:builder collection:collection linePoints:points];
}

- (std::shared_ptr<OsmAnd::MapMarker>) drawMarker:(const OsmAnd::PointI &)position collection:(std::shared_ptr<OsmAnd::MapMarkersCollection> &)collection bitmap:(std::shared_ptr<SkBitmap>&)bitmap
{
    OsmAnd::MapMarkerBuilder pointMarkerBuilder;
    pointMarkerBuilder.setIsAccuracyCircleSupported(false);
    pointMarkerBuilder.setBaseOrder(self.baseOrder - 15);
    pointMarkerBuilder.setIsHidden(false);
    pointMarkerBuilder.setPinIconHorisontalAlignment(OsmAnd::MapMarker::CenterHorizontal);
    pointMarkerBuilder.setPinIconVerticalAlignment(OsmAnd::MapMarker::CenterVertical);
    pointMarkerBuilder.setPinIcon(bitmap);
    pointMarkerBuilder.setMarkerId(collection->getMarkers().count());
    
    auto marker = pointMarkerBuilder.buildAndAddToCollection(collection);
    marker->setPosition(position);
    return marker;
}

- (std::shared_ptr<OsmAnd::MapMarker>) drawMarker:(const OsmAnd::PointI &)position collection:(std::shared_ptr<OsmAnd::MapMarkersCollection> &)collection
{
    return [self drawMarker:position collection:collection bitmap:_pointMarkerIcon];
}

- (void) updateLastPointToCenter
{
    [self.mapViewController runWithRenderSync:^{
        [self drawBeforeAfterPath];
    }];
}

- (void) resetLayer
{
    [self.mapView removeKeyedSymbolsProvider:_collection];
    [self.mapView removeKeyedSymbolsProvider:_lastLineCollection];
    [self.mapView removeKeyedSymbolsProvider:_pointMarkers];
    [self.mapView removeKeyedSymbolsProvider:_selectedMarkerCollection];
    
    _collection = std::make_shared<OsmAnd::VectorLinesCollection>();
    _lastLineCollection = std::make_shared<OsmAnd::VectorLinesCollection>();
    _pointMarkers = std::make_shared<OsmAnd::MapMarkersCollection>();
    _selectedMarkerCollection = std::make_shared<OsmAnd::MapMarkersCollection>();
    
    _cachedCenter = OsmAnd::PointI(0, 0);
}

- (BOOL) updateLayer
{
    [super updateLayer];

    const auto points = [self calculatePointsToDraw];
    [self resetLayer];
    [self drawRouteSegment:points];
    return YES;
}

- (void) enterMovingPointMode
{
    _isInMovingMode = YES;
//    moveMapToPoint(editingCtx.getSelectedPointPosition());
    OAGpxTrkPt *pt = [_editingCtx removePoint:_editingCtx.selectedPointPosition updateSnapToRoad:NO];
    _editingCtx.originalPointToMove = pt;
    [_editingCtx splitSegments:_editingCtx.selectedPointPosition];
    [self updateLayer];
}

- (void) exitMovingMode
{
    _isInMovingMode = NO;
}

- (OAGpxTrkPt *) getMovedPointToApply
{
    const auto latLon = OsmAnd::Utilities::convert31ToLatLon(self.mapViewController.mapView.target31);
    
    OAGpxTrkPt *originalPoint = _editingCtx.originalPointToMove;
    OAGpxTrkPt *point = [[OAGpxTrkPt alloc] initWithPoint:originalPoint];
    point.position = CLLocationCoordinate2DMake(latLon.latitude, latLon.longitude);
    [point copyExtensions:originalPoint];
    return point;
}

// TODO: implement map interaction events
//- (OAGpxTrkPt *) addPoint:(BOOL)addPointBefore
//{
//    if (pressedPointLatLon != null) {
//        WptPt pt = new WptPt();
//        double lat = pressedPointLatLon.getLatitude();
//        double lon = pressedPointLatLon.getLongitude();
//        pt.lat = lat;
//        pt.lon = lon;
//        pressedPointLatLon = null;
//        boolean allowed = editingCtx.getPointsCount() == 0 || !editingCtx.getPoints().get(editingCtx.getPointsCount() - 1).equals(pt);
//        if (allowed) {
//            editingCtx.addPoint(pt, addPointBefore ? AdditionMode.ADD_BEFORE : AdditionMode.ADD_AFTER);
//            moveMapToLatLon(lat, lon);
//            return pt;
//        }
//    }
//    return null;
//}

- (OAGpxTrkPt *) addCenterPoint:(BOOL)addPointBefore
{
    const auto center = self.mapViewController.mapView.target31;
    const auto latLon = OsmAnd::Utilities::convert31ToLatLon(center);
    
    OAGpxTrkPt *pt = [[OAGpxTrkPt alloc] init];
    [pt setPosition:CLLocationCoordinate2DMake(latLon.latitude, latLon.longitude)];
    BOOL allowed = _editingCtx.getPointsCount == 0 || ![_editingCtx.getAllPoints containsObject:pt];
    if (allowed) {
        [_editingCtx addPoint:pt mode:addPointBefore ? EOAAddPointModeBefore : EOAAddPointModeAfter];
        return pt;
    }
    return nil;
}

- (void)addPointMarkers:(const QVector<OsmAnd::PointI>&)points collection:(std::shared_ptr<OsmAnd::MapMarkersCollection> &)collection
{
    OsmAnd::MapMarkerBuilder pointMarkerBuilder;
    pointMarkerBuilder.setIsAccuracyCircleSupported(false);
    pointMarkerBuilder.setBaseOrder(self.baseOrder - 15);
    pointMarkerBuilder.setIsHidden(false);
    pointMarkerBuilder.setPinIconHorisontalAlignment(OsmAnd::MapMarker::CenterHorizontal);
    pointMarkerBuilder.setPinIconVerticalAlignment(OsmAnd::MapMarker::CenterVertical);
    pointMarkerBuilder.setPinIcon(_pointMarkerIcon);
    
    for (int i = 0; i < points.size(); i++)
    {
        const auto& point = points[i];
        auto marker = pointMarkerBuilder.buildAndAddToCollection(collection);
        marker->setPosition(point);
        pointMarkerBuilder.setMarkerId(collection->getMarkers().count());
    }
}

- (QVector<OsmAnd::PointI>) calculatePointsToDraw
{
    QVector<OsmAnd::PointI> points;
    
    OAGpxRtePt *lastBeforePoint = nil;
    NSMutableArray<OAGpxRtePt *> *beforePoints = [NSMutableArray arrayWithArray:_editingCtx.getBeforePoints];
    if (beforePoints.count > 0)
        lastBeforePoint = beforePoints[beforePoints.count - 1];
    OAGpxRtePt *firstAfterPoint = nil;
    NSMutableArray<OAGpxRtePt *> *afterPoints = [NSMutableArray arrayWithArray:_editingCtx.getAfterPoints];
    if (afterPoints.count > 0)
        firstAfterPoint = afterPoints.firstObject;
    
    [beforePoints addObjectsFromArray:afterPoints];

    for (int i = 0; i < beforePoints.count; i++)
    {
        OAGpxRtePt *pt = beforePoints[i];
        points.append(OsmAnd::Utilities::convertLatLonTo31(OsmAnd::LatLon(pt.getLatitude, pt.getLongitude)));
    }
    
    return points;
}

- (void) drawBeforeAfterPath
{
    NSArray<OAGpxTrkSeg *> *before = _editingCtx.getBeforeSegments;
    NSArray<OAGpxTrkSeg *> *after = _editingCtx.getAfterSegments;
    const auto& center = self.mapViewController.mapView.target31;
    if (center == _cachedCenter)
        return;
    _cachedCenter = center;
    QVector<OsmAnd::PointI> points;
    if (before.count > 0 || after.count > 0)
    {
        BOOL hasPointsBefore = NO;
        BOOL hasGapBefore = NO;
        if (before.count > 0)
        {
            OAGpxTrkSeg *segment = before.lastObject;
            if (segment.points.count > 0)
            {
                hasPointsBefore = YES;
                OAGpxTrkPt *pt = segment.points.lastObject;
                hasGapBefore = pt.isGap;
                if (!pt.isGap || (_editingCtx.isInAddPointMode && _editingCtx.addPointMode != EOAAddPointModeBefore))
                {
                    points.push_back(OsmAnd::Utilities::convertLatLonTo31(OsmAnd::LatLon(pt.getLatitude, pt.getLongitude)));
                }
                points.push_back(center);
            }
        }
        if (after.count > 0)
        {
            OAGpxTrkSeg *segment = after.firstObject;
            if (segment.points.count > 0)
            {
                if (!hasPointsBefore)
                {
                    points.push_back(center);
                }
                if (!hasGapBefore || (_editingCtx.isInAddPointMode && _editingCtx.addPointMode != EOAAddPointModeBefore))
                {
                    OAGpxTrkPt *pt = segment.points.firstObject;
                    points.push_back(OsmAnd::Utilities::convertLatLonTo31(OsmAnd::LatLon(pt.getLatitude, pt.getLongitude)));
                }
            }
        }
        
        if (_lastLineCollection->getLines().size() != 0)
        {
            const auto lastLine = _lastLineCollection->getLines().last();
            lastLine->setPoints(points);
        }
        else
        {
            [self drawLines:points collection:_lastLineCollection];
            [self.mapView addKeyedSymbolsProvider:_lastLineCollection];
        }
        
        if (_isInMovingMode || _editingCtx.isInAddPointMode)
        {
            if (_selectedMarkerCollection->getMarkers().isEmpty())
            {
                [self drawMarker:center collection:_selectedMarkerCollection bitmap:_selectedMarkerIcon];
                [self.mapView addKeyedSymbolsProvider:_selectedMarkerCollection];
            }
            else
            {
                _selectedMarkerCollection->getMarkers().first()->setPosition(center);
            }
        }
    }
}

- (void)drawRouteSegments
{
    QVector<OsmAnd::PointI> beforePoints;
    QVector<OsmAnd::PointI> afterPoints;
    NSArray<OAGpxTrkSeg *> *beforeSegs = _editingCtx.getBeforeTrkSegmentLine;
    NSArray<OAGpxTrkSeg *> *afterSegs = _editingCtx.getAfterTrkSegmentLine;
    for (OAGpxTrkSeg *seg in beforeSegs)
    {
        for (OAGpxTrkPt *pt in seg.points)
        {
            beforePoints.push_back(OsmAnd::Utilities::convertLatLonTo31(OsmAnd::LatLon(pt.getLatitude, pt.getLongitude)));
        }
    }
    [self drawLines:beforePoints collection:_collection];
    
    for (OAGpxTrkSeg *seg in afterSegs)
    {
        for (OAGpxTrkPt *pt in seg.points)
        {
            afterPoints.push_back(OsmAnd::Utilities::convertLatLonTo31(OsmAnd::LatLon(pt.getLatitude, pt.getLongitude)));
        }
    }
    [self drawLines:afterPoints collection:_collection];
}

- (void) drawRouteSegment:(const QVector<OsmAnd::PointI> &)points {
    [self.mapViewController runWithRenderSync:^{
        [self drawRouteSegments];
        [self addPointMarkers:points collection:_pointMarkers];
        
        [self.mapView addKeyedSymbolsProvider:_collection];
        [self.mapView addKeyedSymbolsProvider:_pointMarkers];
    }];
}

@end
