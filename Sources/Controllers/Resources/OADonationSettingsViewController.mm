//
//  OADonationSettingsViewController.m
//  OsmAnd
//
//  Created by Alexey Kulish on 07/09/2017.
//  Copyright © 2017 OsmAnd. All rights reserved.
//

#import "OADonationSettingsViewController.h"
#import "OASettingsTableViewCell.h"
#import "OASettingsTitleTableViewCell.h"
#import "OASwitchTableViewCell.h"
#import "OATextInputCell.h"
#import "OAAppSettings.h"
#import "Localization.h"
#import "OAUtilities.h"
#import "OsmAndApp.h"
#import "OAColors.h"
#import "OAWorldRegion.h"

#include <OsmAndCore/WorldRegions.h>

#define kCellTypeSwitch @"switch"
#define kCellTypeSingleSelectionList @"single_selection_list"
#define kCellTypeTextInput @"text_input_cell"
#define kCellTypeCheck @"check"

@interface OADonationSettingsViewController ()

@property (nonatomic) NSDictionary *settingItem;

@end


static const NSInteger settingsIndex = 1;
static const NSInteger lastSectionIndex = 3;

@implementation OADonationSettingsViewController
{
    NSArray *_data;
    NSArray *_lastSection;
    
    OAAppSettings *_settings;
}

- (id) init
{
    self = [super init];
    if (self)
    {
        _settingsType = EDonationSettingsScreenMain;
        _settings = [OAAppSettings sharedManager];
    }
    return self;
}

- (id) initWithSettingsType:(EDonationSettingsScreen)settingsType
{
    self = [super init];
    if (self)
    {
        _settingsType = settingsType;
        _settings = [OAAppSettings sharedManager];
    }
    return self;
}

-(void) applyLocalization
{
    _titleView.text = OALocalizedString(@"osmand_live_donations");
    [_backButton setTitle:OALocalizedString(@"shared_string_back") forState:UIControlStateNormal];
}

- (void) viewDidLoad
{
    [super viewDidLoad];

    self.tableView.dataSource = self;
    self.tableView.delegate = self;
}

- (void) didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self setupView];
}

-(UIView *) getTopView
{
    return _navBarView;
}

-(UIView *) getMiddleView
{
    return _tableView;
}

- (void) setupView
{
    [self applySafeAreaMargins];
    NSMutableArray *dataArr = [NSMutableArray array];
    switch (_settingsType) {
        case EDonationSettingsScreenMain: {
            NSMutableArray *lastSectionArr = [NSMutableArray array];
            NSString *countryName = _settings.billingUserCountry;
            [dataArr addObject:
             @{
               @"name" : @"donation_switch",
               @"title" : OALocalizedString(@"osmand_live_donation_switch_title"),
               @"description" : OALocalizedString(@"osmand_live_donation_switch_descr"),
               @"value" : @(countryName != nil),
               @"type" : kCellTypeSwitch }
             ];
            
            countryName = countryName ? countryName : OALocalizedString(@"map_settings_none");
            [dataArr addObject:
             @{
               @"name" : @"support_region",
               @"title" : OALocalizedString(@"osmand_live_support_reg_title"),
               @"description" : OALocalizedString(@"osmand_live_support_reg_descr"),
               @"value" : countryName,
               @"img" : @"menu_cell_pointer",
               @"type" : kCellTypeSingleSelectionList }
             ];
            
            [dataArr addObject:
             @{
               @"name" : @"email_input",
               @"value" : _settings.billingUserEmail ? _settings.billingUserEmail : @"",
               @"placeholder" : OALocalizedString(@"osmand_live_donations_enter_email"),
               @"description" : OALocalizedString(@"osmand_live_donations_email_descr"),
               @"type" : kCellTypeTextInput }
             ];
            
            [lastSectionArr addObject:
             @{
               @"name" : @"public_name",
               @"value" : _settings.billingUserName ? _settings.billingUserName : @"",
               @"placeholder" : OALocalizedString(@"osmand_live_public_name"),
               @"type" : kCellTypeTextInput }
             ];
            
            [lastSectionArr addObject:
             @{
               @"name" : @"hide_name_switch",
               @"title" : @"Do not show my name in reports",
               @"value" : @(_settings.billingHideUserName),
               @"type" : kCellTypeSwitch }
             ];
            _lastSection = [NSArray arrayWithArray:lastSectionArr];
            break;
        }
        case EDonationSettingsScreenRegion: {
            OsmAndAppInstance app = [OsmAndApp instance];
            OAWorldRegion *root = app.worldRegion;
            NSMutableArray<OAWorldRegion *> *groups = [NSMutableArray new];
            [self processGroups:root nameList:groups];
            [groups sortUsingComparator:^NSComparisonResult(OAWorldRegion *  _Nonnull obj1, OAWorldRegion *  _Nonnull obj2) {
                if (obj1 == root) {
                    return NSOrderedAscending;
                }
                if (obj2 == root) {
                    return NSOrderedDescending;
                }
                return [[self getHumanReadableName:obj1] compare:[self getHumanReadableName:obj2]];
            }];
            for (OAWorldRegion *region in groups)
            {
                [dataArr addObject:
                 @{
                   @"local_name" : [self getHumanReadableName:region],
                   @"download_name" : region == root ? @"" : region.regionId,
                   @"img" : [_settings.billingUserCountryDownloadName isEqualToString:region.regionId] ? @"menu_cell_selected.png" : @"",
                   @"type" : kCellTypeCheck }
                 ];
            }
            break;
        }
        case EDonationSettingsScreenUndefined:
            break;
    }
    
    _data = [NSArray arrayWithArray:dataArr];
    
    [self.tableView reloadData];
}

- (IBAction) backButtonClicked:(id)sender
{
    [super backButtonClicked:sender];
}

- (void) processGroups:(OAWorldRegion *)group nameList:(NSMutableArray<OAWorldRegion *> *)nameList
{
    if ([group.resourceTypes containsObject:@((int)OsmAnd::ResourcesManager::ResourceType::MapRegion)])
        [nameList addObject:group];
    
    if (group.subregions)
    {
        for (OAWorldRegion *subregion in group.subregions)
        {
            [self processGroups:subregion nameList:nameList];
        }
    }
}

- (NSString *)getHumanReadableName:(OAWorldRegion *)region
{
    OAWorldRegion *worldRegion = [OsmAndApp instance].worldRegion;
    NSString *name = @"";
    if (region == worldRegion)
        name = OALocalizedString(@"res_world_region");
    else if ([region getLevel] > 2 || ([region getLevel] == 2
                                      && [region.superregion.regionId isEqualToString:OsmAnd::WorldRegions::RussiaRegionId.toNSString()]))
    {
        OAWorldRegion *parent = region.superregion;
        OAWorldRegion *parentsParent = region.superregion.superregion;
        if ([region getLevel] == 3)
        {
            if ([parentsParent.regionId isEqualToString:OsmAnd::WorldRegions::RussiaRegionId.toNSString()])
                name = [NSString stringWithFormat:@"%@ %@", parentsParent.name, region.name];
            else
                name = [NSString stringWithFormat:@"%@ %@", parent.name, region.name];
        }
        else
            name = [NSString stringWithFormat:@"%@ %@", parent.name, region.name];
    }
    else
        name = region.name;
    
    if (!name)
        name = @"";
    
    return name;
}

- (NSDictionary *) getItem:(NSIndexPath *)indexPath
{
    if (_settingsType == EDonationSettingsScreenMain)
        return indexPath.section == lastSectionIndex ? _lastSection[indexPath.row] : _data[indexPath.section];
    
    return _data[indexPath.row];
}

- (void) applyParameter:(id)sender
{
    if ([sender isKindOfClass:[UISwitch class]])
    {
        UISwitch *sw = (UISwitch *) sender;
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sw.tag & 0x3FF inSection:sw.tag >> 10];
        NSDictionary *item = [self getItem:indexPath];
        
        BOOL isChecked = ((UISwitch *) sender).on;
        NSString *name = item[@"name"];
        id v = item[@"value"];
        if ([name isEqualToString:@"donation_switch"])
        {
            if (!isChecked)
            {
                [_settings setBillingUserCountry:nil];
                [_settings setBillingUserCountryDownloadName:nil];
            }
        }
        else if ([name isEqualToString:@"hide_name_switch"])
        {
            [_settings setBillingHideUserName:isChecked];
        }
    }
}

-(void) viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [_tableView reloadData];
    } completion:nil];
}

#pragma mark - UITableViewDataSource

 - (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView
{
    if (_settingsType == EDonationSettingsScreenMain)
    {
        return _data.count + 1;
    }
    return 1;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_settingsType == EDonationSettingsScreenMain)
        return section == lastSectionIndex ? [_lastSection count] : 1;
    
    return _data.count;
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *item = [self getItem:indexPath];
    NSString *type = item[@"type"];

    if ([type isEqualToString:kCellTypeSwitch])
    {
        static NSString* const identifierCell = @"OASwitchTableViewCell";
        OASwitchTableViewCell* cell = nil;
        
        cell = [tableView dequeueReusableCellWithIdentifier:identifierCell];
        if (cell == nil)
        {
            NSArray *nib = [[NSBundle mainBundle] loadNibNamed:@"OASwitchCell" owner:self options:nil];
            cell = (OASwitchTableViewCell *)[nib objectAtIndex:0];
            cell.textView.numberOfLines = 0;
        }
        
        if (cell)
        {
            [cell.textView setText: item[@"title"]];
            id v = item[@"value"];
            cell.switchView.on = [v boolValue];
            cell.switchView.tag = indexPath.section << 10 | indexPath.row;
            [cell.switchView addTarget:self action:@selector(applyParameter:) forControlEvents:UIControlEventValueChanged];
        }
        return cell;
    }
    else if ([type isEqualToString:kCellTypeSingleSelectionList])
    {
        static NSString* const identifierCell = @"OASettingsTableViewCell";
        OASettingsTableViewCell* cell = nil;
        
        cell = [tableView dequeueReusableCellWithIdentifier:identifierCell];
        if (cell == nil)
        {
            NSArray *nib = [[NSBundle mainBundle] loadNibNamed:@"OASettingsCell" owner:self options:nil];
            cell = (OASettingsTableViewCell *)[nib objectAtIndex:0];
        }
        
        if (cell)
        {
            [cell.textView setText: item[@"title"]];
            [cell.descriptionView setText: item[@"value"]];
            [cell.iconView setImage:[UIImage imageNamed:item[@"img"]]];
        }
        return cell;
    }
    else if ([type isEqualToString:kCellTypeTextInput])
    {
        static NSString* const identifierCell = @"OATextInputCell";
        OATextInputCell* cell = nil;
        
        cell = [tableView dequeueReusableCellWithIdentifier:identifierCell];
        if (cell == nil)
        {
            NSArray *nib = [[NSBundle mainBundle] loadNibNamed:@"OATextInputCell" owner:self options:nil];
            cell = (OATextInputCell *)[nib objectAtIndex:0];
        }
        
        if (cell)
        {
            NSString *value = item[@"value"];
            NSString *placeholder = item[@"placeholder"];
            placeholder = placeholder ? placeholder : @"";
            if (value && [value length] > 0)
                [cell.inputField setText:value];
            else
                cell.inputField.placeholder = placeholder;
        }
        return cell;
    }
    else if ([type isEqualToString:kCellTypeCheck])
    {
        static NSString* const identifierCell = @"OASettingsTitleTableViewCell";
        OASettingsTitleTableViewCell* cell = nil;
        
        cell = [tableView dequeueReusableCellWithIdentifier:identifierCell];
        if (cell == nil)
        {
            NSArray *nib = [[NSBundle mainBundle] loadNibNamed:@"OASettingsTitleCell" owner:self options:nil];
            cell = (OASettingsTitleTableViewCell *)[nib objectAtIndex:0];
        }
        
        if (cell)
        {
            [cell.textView setText: item[@"local_name"]];
            [cell.iconView setImage:[UIImage imageNamed:item[@"img"]]];
        }
        return cell;
    }
    return nil;
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *item = [self getItem:indexPath];
    NSString *type = item[@"type"];
    
    if ([type isEqualToString:kCellTypeSwitch])
    {
        return [OASwitchTableViewCell getHeight:item[@"title"] cellWidth:tableView.bounds.size.width];
    }
    else if ([type isEqualToString:kCellTypeSingleSelectionList] || [type isEqualToString:kCellTypeSwitch])
    {
        return [OASettingsTableViewCell getHeight:item[@"title"] value:item[@"value"] cellWidth:tableView.bounds.size.width];
    }
    else if ([type isEqualToString:kCellTypeTextInput])
    {
        return [OATextInputCell getHeight:item[@"title"] desc:nil cellWidth:100.0];
    }
    else
    {
        return 44.0;
    }
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_settingsType == EDonationSettingsScreenMain && section == settingsIndex)
        return OALocalizedString(@"osmand_live_donation_header");
    
    return nil;
}

- (NSString *) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section != lastSectionIndex)
    {
        NSDictionary *item = _data[section];
        return item[@"description"];
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    if (section == lastSectionIndex)
        return 55.0f;
    
    return -1;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
    if(section == lastSectionIndex)
    {
        UIView *footerView = [[UIView alloc]initWithFrame:CGRectMake(0, 0, DeviceScreenWidth, 55.0)];
        NSDictionary *attrs = @{NSFontAttributeName : [UIFont systemFontOfSize:16.0],
                                NSForegroundColorAttributeName : [UIColor whiteColor]
                                };
        NSAttributedString *text = [[NSAttributedString alloc] initWithString:OALocalizedString(@"shared_string_save") attributes:attrs];
        UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
        saveButton.userInteractionEnabled = YES;
        [saveButton setAttributedTitle:text forState:UIControlStateNormal];
        [saveButton addTarget:self action:@selector(applyParameter:) forControlEvents:UIControlEventTouchUpInside];
        saveButton.backgroundColor = UIColorFromRGB(color_active_light);
        saveButton.layer.cornerRadius = 5;
        saveButton.frame = CGRectMake(10 + [OAUtilities getLeftMargin], 10, DeviceScreenWidth - 20.0 - [OAUtilities getLeftMargin] * 2, 44.0);
        [footerView addSubview:saveButton];
        return footerView;
    }
    return nil;
}

#pragma mark - UITableViewDelegate

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *item = [self getItem:indexPath];
    // TODO Add functionality
    if ([item[@"name"] isEqualToString:@"support_region"])
    {
        OADonationSettingsViewController *regionsScreen = [[OADonationSettingsViewController alloc] initWithSettingsType:EDonationSettingsScreenRegion];
        [self.navigationController pushViewController:regionsScreen animated:YES];
    }
    else if ([item[@"type"] isEqualToString:kCellTypeCheck])
    {
        [_settings setBillingUserCountry:item[@"local_name"]];
        [_settings setBillingUserCountryDownloadName:item[@"download_name"]];
        [self.navigationController popViewControllerAnimated:YES];
    }
    
    [_tableView reloadData];
}

@end
