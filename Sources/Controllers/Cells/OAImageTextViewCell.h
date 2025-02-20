//
//  OAImageDescBTableViewCell.h
//  OsmAnd
//
//  Created by igor on 24.03.2020.
//  Copyright © 2020 OsmAnd. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface OAImageTextViewCell : UITableViewCell

@property (weak, nonatomic) IBOutlet UITextView *descView;
@property (weak, nonatomic) IBOutlet UITextView *extraDescView;
@property (weak, nonatomic) IBOutlet UIImageView *iconView;

@property (strong, nonatomic) IBOutlet NSLayoutConstraint *iconViewHeight;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *descExtraTrailingConstraint;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *descNoExtraTrailingConstraint;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *extraDescEqualDescWidth;

- (void)showExtraDesc:(BOOL)show;

@end

