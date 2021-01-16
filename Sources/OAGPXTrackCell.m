//
//  OAGPXTrackCell.m
//  OsmAnd
//
//  Created by Anna Bibyk on 15.01.2021.
//  Copyright © 2021 OsmAnd. All rights reserved.
//

#import "OAGPXTrackCell.h"
#import "OAUtilities.h"
#import "OAColors.h"

@implementation OAGPXTrackCell

- (void)awakeFromNib
{
    [super awakeFromNib];
    
    _leftIconImageView.image = [[UIImage imageNamed:@"ic_custom_trip"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _distanceImageView.image = [[UIImage imageNamed:@"ic_small_distance"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _timeImageView.image = [[UIImage imageNamed:@"ic_small_time_start"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _wptImageView.image = [[UIImage imageNamed:@"ic_small_waypoints"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    
    _leftIconImageView.tintColor = UIColorFromRGB(color_chart_orange);
    _distanceImageView.tintColor = UIColorFromRGB(color_tint_gray);
    _timeImageView.tintColor = UIColorFromRGB(color_tint_gray);
    _wptImageView.tintColor = UIColorFromRGB(color_tint_gray);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated
{
    [super setSelected:selected animated:animated];
}

@end
