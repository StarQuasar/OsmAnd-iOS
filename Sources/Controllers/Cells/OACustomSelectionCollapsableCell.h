//
//  OACustomSelectionCollapsableCell.h
//  OsmAnd
//
//  Created by Paul on 03.26.2021.
//  Copyright © 2020 OsmAnd. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface OACustomSelectionCollapsableCell : UITableViewCell

@property (weak, nonatomic) IBOutlet UILabel *textView;
@property (weak, nonatomic) IBOutlet UILabel *descriptionView;
@property (weak, nonatomic) IBOutlet UIImageView *iconView;
@property (weak, nonatomic) IBOutlet UIButton *openCloseGroupButton;
@property (weak, nonatomic) IBOutlet UIView *selectionButtonContainer;
@property (weak, nonatomic) IBOutlet UIButton *selectionButton;
@property (weak, nonatomic) IBOutlet UIButton *selectionGroupButton;

@property (strong, nonatomic) IBOutlet NSLayoutConstraint *checkboxHeightContainer;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *checkboxWidthContainer;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *textTopConstraint;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *textTopNoDescConstraint;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *textBottomConstraint;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *textBottomNoDescConstraint;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *textLeftConstraint;
@property (strong, nonatomic) IBOutlet NSLayoutConstraint *textLeftNoSelectConstraint;

- (void)makeSelectable:(BOOL)selectable;

@end
