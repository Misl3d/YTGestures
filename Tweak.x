#import "YTVolumeHUD.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// YouTube Settings Headers
@interface YTSettingsCell : UITableViewCell
@end

@interface YTSettingsSectionItem : NSObject
+ (instancetype)switchItemWithTitle:(NSString *)title
                   titleDescription:(NSString *)titleDescription
            accessibilityIdentifier:(NSString *)accessibilityIdentifier
                           switchOn:(BOOL)switchOn
                        switchBlock:(BOOL (^)(YTSettingsCell *cell,
                                              BOOL enabled))switchBlock
                      settingItemId:(int)settingItemId;
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
- (void)updateVolumeBoostYTSectionWithEntry:(id)entry;
@end

static const NSInteger TweakSection = 'ndyt';
static NSString *const kVolumeBoostYTEnabledKey = @"VolumeBoostYTEnabled";

static BOOL IsVolumeBoostYTEnabled() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:kVolumeBoostYTEnabledKey] ? [defaults boolForKey:kVolumeBoostYTEnabledKey] : YES;
}

// -----------------------------------------------------
// SYSTEM VOLUME HELPER
// -----------------------------------------------------

static UISlider *GetSystemVolumeSlider() {
    static UISlider *volumeSlider = nil;
    if (!volumeSlider) {
        // Create a hidden MPVolumeView to access the system slider
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
    if (level < 0.0f) level = 0.0f;
    if (level > 1.0f) level = 1.0f;
    
    UISlider *slider = GetSystemVolumeSlider();
    [slider setValue:level animated:NO];
    [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
}

// -----------------------------------------------------
// UI Hooks (sendEvent:)
// -----------------------------------------------------

static float gestureStartVolume = 0.0f;
static BOOL possibleVolumeGesture = NO;
static BOOL isTrackingVolumeGesture = NO;
static CGPoint initialTouchPoint;

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    if (!IsVolumeBoostYTEnabled()) { %orig(event); return; }

    UITouch *touch = [[event allTouches] anyObject];
    CGPoint location = [touch locationInView:self];

    switch (touch.phase) {
        case UITouchPhaseBegan: {
            if (location.x >= self.bounds.size.width - 25.0f) {
                possibleVolumeGesture = YES;
                isTrackingVolumeGesture = NO;
                initialTouchPoint = location;
                return; 
            }
            break;
        }
        case UITouchPhaseMoved: {
            if (possibleVolumeGesture) {
                CGFloat dx = initialTouchPoint.x - location.x;
                CGFloat dy = fabs(location.y - initialTouchPoint.y);
                if (dx > 15.0f && dx > dy) {
                    isTrackingVolumeGesture = YES;
                    possibleVolumeGesture = NO;
                    initialTouchPoint = location;
                    gestureStartVolume = GetCurrentSystemVolume();
                    return;
                } else if (dy > 20.0f) {
                    possibleVolumeGesture = NO;
                }
            }

            if (isTrackingVolumeGesture) {
                CGFloat translationY = location.y - initialTouchPoint.y;
                // Sensitivity: 300 points for a full 0% to 100% change
                float deltaVolume = -translationY / 300.0f; 
                SetSystemVolume(gestureStartVolume + deltaVolume);
                return;
            }
            break;
        }
        case UITouchPhaseEnded:
        case UITouchPhaseCancelled: {
            possibleVolumeGesture = NO;
            isTrackingVolumeGesture = NO;
            break;
        }
        default: break;
    }
    %orig(event);
}
%end

        // -----------------------------------------------------
        // YouTube In-App Settings Integration
        // -----------------------------------------------------

        %group YouTubeSettings

        %hook YTSettingsGroupData

    - (NSArray<NSNumber *> *)orderedCategories {
  // Only inject into the main settings group (type 1)
  if (self.type != 1)
    return %orig;

  // If another tweak (YouGroupSettings) handles grouping, let it do so
  if (class_getClassMethod(objc_getClass("YTSettingsGroupData"),
                           @selector(tweaks))) {
    return %orig;
  }

  NSMutableArray *mutableCategories = %orig.mutableCopy;
  if (mutableCategories) {
    // Insert our tweak section near the top
    [mutableCategories insertObject:@(TweakSection) atIndex:0];
  }
  return mutableCategories.copy ?: %orig;
}

+ (NSMutableArray<NSNumber *> *)tweaks {
  NSMutableArray<NSNumber *> *tweaks = %orig;
  if (tweaks && ![tweaks containsObject:@(TweakSection)]) {
    [tweaks addObject:@(TweakSection)];
  }
  return tweaks;
}

%end

        %hook YTAppSettingsPresentationData

    + (NSArray<NSNumber *> *)settingsCategoryOrder {
  NSArray<NSNumber *> *order = %orig;
  NSUInteger insertIndex = [order indexOfObject:@(1)];

  if (insertIndex != NSNotFound) {
    NSMutableArray<NSNumber *> *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(TweakSection) atIndex:insertIndex + 1];
    return mutableOrder.copy;
  }

  return order ?: %orig;
}

%end

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateVolumeBoostYTSectionWithEntry:(id)entry {
    NSMutableArray<YTSettingsSectionItem *> *sectionItems = [NSMutableArray array];
    Class YTSettingsSectionItemClass = %c(YTSettingsSectionItem);
    if (!YTSettingsSectionItemClass) return;

    YTSettingsViewController *settingsViewController = [self valueForKey:@"_settingsViewControllerDelegate"];

    YTSettingsSectionItem *enableTweak = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Enable System Volume Gesture"
             titleDescription:@"Allow custom right-edge pan volume gesture"
      accessibilityIdentifier:nil
                     switchOn:IsVolumeBoostYTEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kVolumeBoostYTEnabledKey];
                    [[NSUserDefaults standardUserDefaults] synchronize];

                    // If user disables it, we don't need to reset anything 
                    // because we are just controlling the hardware volume now.
                    return YES;
                  }
                settingItemId:0];
    [sectionItems addObject:enableTweak];

  if ([settingsViewController
          respondsToSelector:@selector
          (setSectionItems:
               forCategory:title:icon:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                                       icon:nil
                           titleDescription:nil
                               headerHidden:NO];
  } else if ([settingsViewController
                 respondsToSelector:@selector
                 (setSectionItems:
                      forCategory:title:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                           titleDescription:nil
                               headerHidden:NO];
  }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == TweakSection) {
        [self updateVolumeBoostYTSectionWithEntry:entry];
        return;
    }
    %orig;
}
%end

    %end // end group YouTubeSettings

    %ctor {
  // Never inject into SpringBoard (Home Screen)
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  if ([bundleID isEqualToString:@"com.apple.springboard"]) {
    return;
  }

  // Check if YouTube classes exist instead of relying on Bundle ID,
  // because sideloaded apps (like LiveContainer) often change their Bundle IDs.
  if (NSClassFromString(@"YTSettingsGroupData")) {
    %init(YouTubeSettings);
  }

  // Always initialize the core AVPlayer and UIWindow touch hooks for every app
  %init;
}
