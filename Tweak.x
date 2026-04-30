#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// YouTube Settings Headers
@interface YTSettingsCell : UITableViewCell
@end

@interface YTSettingsSectionItem : NSObject
+ (instancetype)itemWithTitle:(NSString *)title
             titleDescription:(NSString *)titleDescription
      accessibilityIdentifier:(NSString *)accessibilityIdentifier
              detailTextBlock:(NSString *(^)(void))detailTextBlock
                  selectBlock:(BOOL (^)(YTSettingsCell *cell, NSUInteger arg))selectBlock;
@end

@interface YTSettingsViewController : UIViewController
- (void)setSectionItems:(NSMutableArray<YTSettingsSectionItem *> *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
       titleDescription:(NSString *)titleDescription
           headerHidden:(BOOL)headerHidden;
- (void)setSectionItems:(NSMutableArray<YTSettingsSectionItem *> *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
                   icon:(id)icon
       titleDescription:(NSString *)titleDescription
           headerHidden:(BOOL)headerHidden;
@end

@interface YTSettingsGroupData : NSObject
@property(nonatomic, assign) NSInteger type;
- (NSArray<NSNumber *> *)orderedCategories;
@end

@interface YTAppSettingsPresentationData : NSObject
+ (NSArray<NSNumber *> *)settingsCategoryOrder;
@end

@interface YTSettingsSectionItemManager : NSObject
- (void)updateYTGesturesSectionWithEntry:(id)entry;
@end

// Unique Section ID
static const NSInteger YTGestureSection = 'ytgs';

// Accessibility identifiers — used as keys in layoutSubviews hook
static NSString *const kRightSegmentID = @"ytgRightEdgeSegment";
static NSString *const kLeftSegmentID  = @"ytgLeftEdgeSegment";

// Segment tag values to find existing controls on reuse
static const NSInteger kTagRightSegment = 778801;
static const NSInteger kTagLeftSegment  = 778802;

// Mode values: 0 = Off, 1 = Volume, 2 = Brightness
static NSString *const kYTGesturesRightModeKey = @"YTGesturesRightMode";
static NSString *const kYTGesturesLeftModeKey  = @"YTGesturesLeftMode";

// Global defaults — set in %ctor, matches YTweaks pattern
static NSUserDefaults *defaults;

// -----------------------------------------------------------
// System Volume
// -----------------------------------------------------------
static UISlider *GetSystemVolumeSlider() {
    static UISlider *volumeSlider = nil;
    if (!volumeSlider) {
        MPVolumeView *volumeView = [[MPVolumeView alloc] initWithFrame:CGRectZero];
        for (UIView *view in [volumeView subviews]) {
            if ([NSStringFromClass([view class]) isEqualToString:@"MPVolumeSlider"]) {
                volumeSlider = (UISlider *)view;
                break;
            }
        }
    }
    return volumeSlider;
}
static float GetCurrentSystemVolume() {
    return [[AVAudioSession sharedInstance] outputVolume];
}
static void SetSystemVolume(float level) {
    level = MAX(0.0f, MIN(1.0f, level));
    UISlider *slider = GetSystemVolumeSlider();
    [slider setValue:level animated:NO];
    [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
}

// -----------------------------------------------------------
// Brightness
// -----------------------------------------------------------
static float GetCurrentBrightness() {
    return (float)[UIScreen mainScreen].brightness;
}
static void SetBrightness(float level) {
    [[UIScreen mainScreen] setBrightness:MAX(0.0f, MIN(1.0f, level))];
}

// -----------------------------------------------------------
// Adjust helper (mode: 0=off, 1=volume, 2=brightness)
// -----------------------------------------------------------
static void AdjustControl(NSInteger mode, float startValue, CGFloat translationY) {
    if (mode == 0) return;
    float newValue = startValue + (-(float)translationY / 300.0f);
    if (mode == 1) SetSystemVolume(newValue);
    else           SetBrightness(newValue);
}

// -----------------------------------------------------------
// Gesture state
// -----------------------------------------------------------
static const CGFloat kEdgeZone                 = 25.0f;
static const CGFloat kSwipeCommitThreshold     = 15.0f;
static const CGFloat kVerticalAbandonThreshold = 20.0f;

static float   gestureStartValueRight = 0.0f;
static BOOL    possibleGestureRight   = NO;
static BOOL    isTrackingGestureRight = NO;
static CGPoint initialTouchPointRight;

static float   gestureStartValueLeft  = 0.0f;
static BOOL    possibleGestureLeft    = NO;
static BOOL    isTrackingGestureLeft  = NO;
static CGPoint initialTouchPointLeft;

// -----------------------------------------------------------
// UIWindow hook
// -----------------------------------------------------------
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    NSInteger rightMode = [defaults integerForKey:kYTGesturesRightModeKey];
    NSInteger leftMode  = [defaults integerForKey:kYTGesturesLeftModeKey];

    if (rightMode == 0 && leftMode == 0) { %orig(event); return; }

    UITouch *touch = [[event allTouches] anyObject];
    if (!touch) { %orig(event); return; }

    CGPoint location    = [touch locationInView:self];
    CGFloat screenWidth = self.bounds.size.width;

    switch (touch.phase) {

        case UITouchPhaseBegan: {
            if (rightMode != 0 && location.x >= screenWidth - kEdgeZone) {
                possibleGestureRight   = YES;
                isTrackingGestureRight = NO;
                initialTouchPointRight = location;
                return;
            }
            if (leftMode != 0 && location.x <= kEdgeZone) {
                possibleGestureLeft   = YES;
                isTrackingGestureLeft = NO;
                initialTouchPointLeft = location;
                return;
            }
            break;
        }

        case UITouchPhaseMoved: {
            // Right edge
            if (possibleGestureRight) {
                CGFloat dx = initialTouchPointRight.x - location.x; // positive = swiped inward
                CGFloat dy = fabs(location.y - initialTouchPointRight.y);
                if (dx > kSwipeCommitThreshold && dx > dy) {
                    isTrackingGestureRight = YES;
                    possibleGestureRight   = NO;
                    initialTouchPointRight = location;
                    gestureStartValueRight = (rightMode == 1) ? GetCurrentSystemVolume() : GetCurrentBrightness();
                    return;
                } else if (dy > kVerticalAbandonThreshold) {
                    possibleGestureRight = NO;
                }
            }
            if (isTrackingGestureRight) {
                AdjustControl(rightMode, gestureStartValueRight, location.y - initialTouchPointRight.y);
                return;
            }

            // Left edge
            if (possibleGestureLeft) {
                CGFloat dx = location.x - initialTouchPointLeft.x; // positive = swiped inward
                CGFloat dy = fabs(location.y - initialTouchPointLeft.y);
                if (dx > kSwipeCommitThreshold && dx > dy) {
                    isTrackingGestureLeft = YES;
                    possibleGestureLeft   = NO;
                    initialTouchPointLeft = location;
                    gestureStartValueLeft = (leftMode == 1) ? GetCurrentSystemVolume() : GetCurrentBrightness();
                    return;
                } else if (dy > kVerticalAbandonThreshold) {
                    possibleGestureLeft = NO;
                }
            }
            if (isTrackingGestureLeft) {
                AdjustControl(leftMode, gestureStartValueLeft, location.y - initialTouchPointLeft.y);
                return;
            }

            break;
        }

        case UITouchPhaseEnded:
        case UITouchPhaseCancelled: {
            possibleGestureRight   = NO;
            isTrackingGestureRight = NO;
            possibleGestureLeft    = NO;
            isTrackingGestureLeft  = NO;
            break;
        }

        default: break;
    }

    %orig(event);
}
%end

// -----------------------------------------------------------
// YouTube In-App Settings
// -----------------------------------------------------------

%hook YTSettingsGroupData
- (NSArray<NSNumber *> *)orderedCategories {
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
        return %orig;
    NSMutableArray *cats = %orig.mutableCopy;
    if (![cats containsObject:@(YTGestureSection)])
        [cats insertObject:@(YTGestureSection) atIndex:0];
    return cats.copy;
}
+ (NSMutableArray<NSNumber *> *)tweaks {
    NSMutableArray *tweaks = %orig;
    if (tweaks && ![tweaks containsObject:@(YTGestureSection)])
        [tweaks addObject:@(YTGestureSection)];
    return tweaks;
}
%end

%hook YTAppSettingsPresentationData
+ (NSArray<NSNumber *> *)settingsCategoryOrder {
    NSArray *order = %orig;
    NSUInteger idx = [order indexOfObject:@(1)];
    if (idx != NSNotFound) {
        NSMutableArray *m = [order mutableCopy];
        if (![m containsObject:@(YTGestureSection)])
            [m insertObject:@(YTGestureSection) atIndex:idx + 1];
        return m.copy;
    }
    return order;
}
%end

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateYTGesturesSectionWithEntry:(id)entry {
    NSMutableArray *items = [NSMutableArray array];
    Class ItemClass = %c(YTSettingsSectionItem);
    if (!ItemClass) return;

    YTSettingsViewController *vc = [self valueForKey:@"_settingsViewControllerDelegate"];

    // Right Edge row — title + segmented control below via layoutSubviews hook
    YTSettingsSectionItem *rightEdge = [ItemClass
          itemWithTitle:@"Right Edge Gesture"
       titleDescription:@"Swipe in from the right edge to adjust volume or brightness."
accessibilityIdentifier:kRightSegmentID
        detailTextBlock:nil
            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg) {
                return NO; // segmented control handles interaction
            }];
    [items addObject:rightEdge];

    // Left Edge row
    YTSettingsSectionItem *leftEdge = [ItemClass
          itemWithTitle:@"Left Edge Gesture"
       titleDescription:@"Swipe in from the left edge to adjust volume or brightness."
accessibilityIdentifier:kLeftSegmentID
        detailTextBlock:nil
            selectBlock:^BOOL(YTSettingsCell *cell, NSUInteger arg) {
                return NO;
            }];
    [items addObject:leftEdge];

    if ([vc respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        [vc setSectionItems:items forCategory:YTGestureSection title:@"YTGestures" icon:nil titleDescription:nil headerHidden:NO];
    } else if ([vc respondsToSelector:@selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)]) {
        [vc setSectionItems:items forCategory:YTGestureSection title:@"YTGestures" titleDescription:nil headerHidden:NO];
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == YTGestureSection) {
        [self updateYTGesturesSectionWithEntry:entry];
        return;
    }
    %orig;
}
%end

// -----------------------------------------------------------
// YTSettingsCell — inject segmented controls via layoutSubviews
// Mirrors the exact pattern from YTweaks/Settings.x
// -----------------------------------------------------------
%hook YTSettingsCell

- (void)layoutSubviews {
    %orig;

    // --- Right Edge segmented control ---
    if ([self.accessibilityIdentifier isEqualToString:kRightSegmentID]) {
        UISegmentedControl *segment = [self.contentView viewWithTag:kTagRightSegment];
        if (!segment) {
            segment = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Volume", @"Brightness"]];
            segment.tag = kTagRightSegment;
            segment.selectedSegmentIndex = [defaults integerForKey:kYTGesturesRightModeKey];
            [segment addTarget:self action:@selector(ytg_rightSegmentChanged:) forControlEvents:UIControlEventValueChanged];

            segment.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0];
            if (@available(iOS 13.0, *)) {
                segment.selectedSegmentTintColor = [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0];
            }
            UIFont *font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
            [segment setTitleTextAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
            [segment setTitleTextAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];

            segment.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:segment];

            // Enforce enough cell height to show title + segment without overlap
            NSLayoutConstraint *heightConstraint = [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:72];
            heightConstraint.priority = UILayoutPriorityRequired - 1;
            [NSLayoutConstraint activateConstraints:@[
                heightConstraint,
                [segment.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
                [segment.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
                [segment.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:40],
                [segment.heightAnchor constraintEqualToConstant:32]
            ]];
        } else {
            NSInteger current = [defaults integerForKey:kYTGesturesRightModeKey];
            if (segment.selectedSegmentIndex != current)
                segment.selectedSegmentIndex = current;
        }
        return;
    }

    // --- Left Edge segmented control ---
    if ([self.accessibilityIdentifier isEqualToString:kLeftSegmentID]) {
        UISegmentedControl *segment = [self.contentView viewWithTag:kTagLeftSegment];
        if (!segment) {
            segment = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Volume", @"Brightness"]];
            segment.tag = kTagLeftSegment;
            segment.selectedSegmentIndex = [defaults integerForKey:kYTGesturesLeftModeKey];
            [segment addTarget:self action:@selector(ytg_leftSegmentChanged:) forControlEvents:UIControlEventValueChanged];

            segment.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0];
            if (@available(iOS 13.0, *)) {
                segment.selectedSegmentTintColor = [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0];
            }
            UIFont *font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
            [segment setTitleTextAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
            [segment setTitleTextAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];

            segment.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:segment];

            NSLayoutConstraint *heightConstraint = [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:72];
            heightConstraint.priority = UILayoutPriorityRequired - 1;
            [NSLayoutConstraint activateConstraints:@[
                heightConstraint,
                [segment.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
                [segment.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
                [segment.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:40],
                [segment.heightAnchor constraintEqualToConstant:32]
            ]];
        } else {
            NSInteger current = [defaults integerForKey:kYTGesturesLeftModeKey];
            if (segment.selectedSegmentIndex != current)
                segment.selectedSegmentIndex = current;
        }
        return;
    }
}

%new
- (void)ytg_rightSegmentChanged:(UISegmentedControl *)sender {
    [defaults setInteger:sender.selectedSegmentIndex forKey:kYTGesturesRightModeKey];
    [defaults synchronize];
}

%new
- (void)ytg_leftSegmentChanged:(UISegmentedControl *)sender {
    [defaults setInteger:sender.selectedSegmentIndex forKey:kYTGesturesLeftModeKey];
    [defaults synchronize];
}

%end

%ctor {
    defaults = [NSUserDefaults standardUserDefaults];

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.apple.springboard"]) return;

    %init;
}
