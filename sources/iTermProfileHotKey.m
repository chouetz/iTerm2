#import "iTermProfileHotKey.h"

#import "DebugLogging.h"
#import "ITAddressBookMgr.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermCarbonHotKeyController.h"
#import "iTermPreferences.h"
#import "iTermProfilePreferences.h"
#import "iTermRollAnimationWindow.h"
#import "NSArray+iTerm.h"
#import "PseudoTerminal.h"
#import "SolidColorView.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kGUID = @"GUID";
static NSString *const kArrangement = @"Arrangement";
static const NSTimeInterval kAnimationDuration = 0.25;

@interface iTermProfileHotKey()
@property(nonatomic, copy) NSString *profileGuid;
@property(nonatomic, retain) NSDictionary *restorableState;
@property(nonatomic, readwrite) BOOL rollingIn;
@property(nonatomic, retain) PseudoTerminal<iTermWeakReference> *windowController;
@property(nonatomic) BOOL birthingWindow;
@property(nonatomic, retain) NSWindowController *windowControllerBeingBorn;
@end

@implementation iTermProfileHotKey

- (instancetype)initWithKeyCode:(NSUInteger)keyCode
                      modifiers:(NSEventModifierFlags)modifiers
                     characters:(NSString *)characters
    charactersIgnoringModifiers:(NSString *)charactersIgnoringModifiers
                        profile:(Profile *)profile {
    self = [super initWithKeyCode:keyCode
                        modifiers:modifiers
                       characters:characters
      charactersIgnoringModifiers:charactersIgnoringModifiers];
    if (self) {
        _profileGuid = [profile[KEY_GUID] copy];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(terminalWindowControllerCreated:)
                                                     name:kTerminalWindowControllerWasCreatedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_restorableState release];
    [_profileGuid release];
    [_windowController release];
    [_windowControllerBeingBorn release];
    [super dealloc];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p keycode=%@ charactersIgnoringModifiers=%@ modifiers=%x profile.name=%@ profile.guid=%@ open=%@>",
            [self class], self, @(self.keyCode), self.charactersIgnoringModifiers, (int)self.modifiers, self.profile[KEY_NAME], self.profile[KEY_GUID], @(self.isHotKeyWindowOpen)];
}

#pragma mark - APIs

- (Profile *)profile {
    return [[ProfileModel sharedInstance] bookmarkWithGuid:_profileGuid];
}

- (void)createWindow {
    if (self.windowController.weaklyReferencedObject) {
        return;
    }

    DLog(@"Create new window controller for profile hotkey");
    self.windowController = [[self windowControllerFromRestorableState] weakSelf];
    if (!self.windowController.weaklyReferencedObject) {
        self.windowController = [[self windowControllerFromProfile:[self profile]] weakSelf];
    }
    if (!self.windowController.weaklyReferencedObject) {
        return;
    }

    if ([iTermAdvancedSettingsModel hotkeyWindowFloatsAboveOtherWindows]) {
        self.windowController.window.level = NSFloatingWindowLevel;
    } else {
        self.windowController.window.level = NSNormalWindowLevel;
    }
    self.windowController.isHotKeyWindow = YES;

    [self.windowController.window setAlphaValue:0];
    if (self.windowController.windowType != WINDOW_TYPE_TRADITIONAL_FULL_SCREEN) {
        [self.windowController.window setCollectionBehavior:self.windowController.window.collectionBehavior & ~NSWindowCollectionBehaviorFullScreenPrimary];
    }
}

- (void)rollInAnimatingInDirection:(iTermAnimationDirection)direction {
    iTermRollAnimationWindow *animationWindow = [[iTermRollAnimationWindow rollAnimationWindowForWindow:self.windowController.window] retain];
    self.windowController.window.alphaValue = 0.01;
    
    const NSTimeInterval duration = kAnimationDuration;
    [animationWindow animateInWithDirection:direction duration:duration completion:^() {
        self.windowController.window.alphaValue = 1;
        [self rollInFinished];
        [animationWindow release];
    }];
}

- (void)rollOutAnimatingInDirection:(iTermAnimationDirection)direction {
    iTermRollAnimationWindow *animationWindow = [[iTermRollAnimationWindow rollAnimationWindowForWindow:self.windowController.window] retain];
    self.windowController.window.alphaValue = 0.01;
    
    const NSTimeInterval duration = kAnimationDuration;
    [animationWindow animateOutWithDirection:direction duration:duration completion:^() {
        self.windowController.window.alphaValue = 0;
        [self didFinishRollingOut];
        [animationWindow release];
    }];
}

- (void)fadeIn {
    [NSAnimationContext beginGrouping];
    [[NSAnimationContext currentContext] setDuration:kAnimationDuration];
    [[NSAnimationContext currentContext] setCompletionHandler:^{
        [self rollInFinished];
    }];
    [[self.windowController.window animator] setAlphaValue:1];
    [NSAnimationContext endGrouping];
}

- (void)fadeOut {
    [NSAnimationContext beginGrouping];
    [[NSAnimationContext currentContext] setDuration:kAnimationDuration];
    [[NSAnimationContext currentContext] setCompletionHandler:^{
        [self didFinishRollingOut];
    }];
    self.windowController.window.animator.alphaValue = 0;
    [NSAnimationContext endGrouping];
}

- (iTermAnimationDirection)animateInDirectionForWindowType:(iTermWindowType)windowType {
    switch (windowType) {
        case WINDOW_TYPE_TOP:
        case WINDOW_TYPE_TOP_PARTIAL:
            return kAnimationDirectionDown;
            break;
            
        case WINDOW_TYPE_LEFT:
        case WINDOW_TYPE_LEFT_PARTIAL:
            return kAnimationDirectionRight;
            break;
            
        case WINDOW_TYPE_RIGHT:
        case WINDOW_TYPE_RIGHT_PARTIAL:
            return kAnimationDirectionLeft;
            break;
            
        case WINDOW_TYPE_BOTTOM:
        case WINDOW_TYPE_BOTTOM_PARTIAL:
            return kAnimationDirectionUp;
            break;
            
        case WINDOW_TYPE_NORMAL:
        case WINDOW_TYPE_NO_TITLE_BAR:
        case WINDOW_TYPE_TRADITIONAL_FULL_SCREEN:  // Framerate drops too much to roll this (2014 5k iMac)
        case WINDOW_TYPE_LION_FULL_SCREEN:
            assert(false);
    }
}

- (void)rollIn {
    DLog(@"Roll in [show] hotkey window");
    if (_rollingIn) {
        DLog(@"Already rolling in");
        return;
    }
    _rollingIn = YES;
    [NSApp activateIgnoringOtherApps:YES];
    [self.windowController.window makeKeyAndOrderFront:nil];
    
    if ([iTermProfilePreferences boolForKey:KEY_HOTKEY_ANIMATE inProfile:self.profile]) {
        switch (self.windowController.windowType) {
            case WINDOW_TYPE_TOP:
            case WINDOW_TYPE_TOP_PARTIAL:
            case WINDOW_TYPE_LEFT:
            case WINDOW_TYPE_LEFT_PARTIAL:
            case WINDOW_TYPE_RIGHT:
            case WINDOW_TYPE_RIGHT_PARTIAL:
            case WINDOW_TYPE_BOTTOM:
            case WINDOW_TYPE_BOTTOM_PARTIAL:
                [self rollInAnimatingInDirection:[self animateInDirectionForWindowType:self.windowController.windowType]];
                break;
                
            case WINDOW_TYPE_NORMAL:
            case WINDOW_TYPE_NO_TITLE_BAR:
            case WINDOW_TYPE_TRADITIONAL_FULL_SCREEN:  // Framerate drops too much to roll this (2014 5k iMac)
                [self fadeIn];
                break;
                
            case WINDOW_TYPE_LION_FULL_SCREEN:
                assert(false);
        }
    } else {
        self.windowController.window.alphaValue = 1;
        [self rollInFinished];
    }
}

- (void)rollOut {
    DLog(@"Roll out [hide] hotkey window");
    if (_rollingOut) {
        DLog(@"Already rolling out");
        return;
    }
    // Note: the test for alpha is because when you become an LSUIElement, the
    // window's alpha could be 1 but it's still invisible.
    if (self.windowController.window.alphaValue == 0) {
        DLog(@"RollOutHotkeyTerm returning because term isn't visible.");
        return;
    }

    _rollingOut = YES;

    if ([iTermProfilePreferences boolForKey:KEY_HOTKEY_ANIMATE inProfile:self.profile]) {
        switch (self.windowController.windowType) {
            case WINDOW_TYPE_TOP:
            case WINDOW_TYPE_TOP_PARTIAL:
            case WINDOW_TYPE_LEFT:
            case WINDOW_TYPE_LEFT_PARTIAL:
            case WINDOW_TYPE_RIGHT:
            case WINDOW_TYPE_RIGHT_PARTIAL:
            case WINDOW_TYPE_BOTTOM:
            case WINDOW_TYPE_BOTTOM_PARTIAL: {
                iTermAnimationDirection inDirection = [self animateInDirectionForWindowType:self.windowController.windowType];
                iTermAnimationDirection outDireciton = iTermAnimationDirectionOpposite(inDirection);
                [self rollOutAnimatingInDirection:outDireciton];
                break;
            }
                
            case WINDOW_TYPE_NORMAL:
            case WINDOW_TYPE_NO_TITLE_BAR:
            case WINDOW_TYPE_TRADITIONAL_FULL_SCREEN:  // Framerate drops too much to roll this (2014 5k iMac)
                [self fadeOut];
                break;
                
            case WINDOW_TYPE_LION_FULL_SCREEN:
                assert(false);
        }
    } else {
        self.windowController.window.alphaValue = 0;
        [self didFinishRollingOut];
    }
}

- (void)saveHotKeyWindowState {
    if (self.windowController.weaklyReferencedObject && self.profileGuid) {
        DLog(@"Saving hotkey window state for %@", self);
        BOOL includeContents = [iTermAdvancedSettingsModel restoreWindowContents];
        NSDictionary *arrangement = [self.windowController arrangementExcludingTmuxTabs:YES
                                                                      includingContents:includeContents];
        if (arrangement) {
            self.restorableState = @{ kGUID: self.profileGuid,
                                      kArrangement: arrangement };
        } else {
            self.restorableState = nil;
        }
    } else {
        DLog(@"Not saving hotkey window state for %@", self);
        self.restorableState = nil;
    }
}

- (void)setLegacyState:(NSDictionary *)state {
    if (self.profileGuid && state) {
        self.restorableState = @{ kGUID: self.profileGuid,
                                  kArrangement: state };
    } else {
        DLog(@"Not setting legacy state. profileGuid=%@, state=%@", self.profileGuid, state);
    }
}

- (void)loadRestorableStateFromArray:(NSArray *)states {
    for (NSDictionary *state in states) {
        if ([state[kGUID] isEqualToString:self.profileGuid]) {
            self.restorableState = state;
            return;
        }
    }
}

- (BOOL)isHotKeyWindowOpen {
    return self.windowController.window.alphaValue > 0;
}

#pragma mark - Protected

- (void)hotKeyPressedWithSiblings:(NSArray<iTermHotKey *> *)siblings {
    DLog(@"toggle window %@. siblings=%@", self, siblings);
    BOOL allSiblingsOpen = [siblings allWithBlock:^BOOL(iTermHotKey *sibling) {
        if ([sibling.target isKindOfClass:[self class]]) {
            iTermProfileHotKey *other = sibling.target;
            return other.isHotKeyWindowOpen;
        } else {
            return NO;
        }
    }];
    if (self.windowController.weaklyReferencedObject) {
        DLog(@"already have a hotkey window created");
        if (self.windowController.window.alphaValue == 1) {
            DLog(@"hotkey window opaque");
            if (!allSiblingsOpen) {
                DLog(@"Not all siblings open. Doing nothing.");
                return;
            }
            self.wasAutoHidden = NO;
            [self hideHotKeyWindow];
        } else {
            DLog(@"hotkey window not opaque");
            [self showHotKeyWindow];
        }
    } else {
        DLog(@"no hotkey window created yet");
        [self showHotKeyWindow];
    }
}

#pragma mark - Private

- (PseudoTerminal *)windowControllerFromRestorableState {
    NSDictionary *arrangement = [[self.restorableState[kArrangement] copy] autorelease];
    if (!arrangement) {
        // If the user had an arrangement saved in user defaults, restore it and delete it. This is
        // how hotkey window state was preserved prior to 12/9/14 when it was moved into application-
        // level restorable state. Eventually this migration code can be deleted.
        NSString *const kUserDefaultsHotkeyWindowArrangement = @"NoSyncHotkeyWindowArrangement";  // DEPRECATED
        arrangement =
            [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsHotkeyWindowArrangement];
        if (arrangement) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserDefaultsHotkeyWindowArrangement];
        }
    }
    self.restorableState = nil;
    if (!arrangement) {
        return nil;
    }

    PseudoTerminal *term = [PseudoTerminal terminalWithArrangement:arrangement];
    if (term) {
        [[iTermController sharedInstance] addTerminalWindow:term];
    }
    return term;
}

- (PseudoTerminal *)windowControllerFromProfile:(Profile *)hotkeyProfile {
    if (!hotkeyProfile) {
        return nil;
    }
    if ([[hotkeyProfile objectForKey:KEY_WINDOW_TYPE] intValue] == WINDOW_TYPE_LION_FULL_SCREEN) {
        // Lion fullscreen doesn't make sense with hotkey windows. Change
        // window type to traditional fullscreen.
        NSMutableDictionary *replacement = [[hotkeyProfile mutableCopy] autorelease];
        replacement[KEY_WINDOW_TYPE] = @(WINDOW_TYPE_TRADITIONAL_FULL_SCREEN);
        hotkeyProfile = replacement;
    }
    [self.delegate hotKeyWillCreateWindow:self];
    self.birthingWindow = YES;
    PTYSession *session = [[iTermController sharedInstance] launchBookmark:hotkeyProfile
                                                                inTerminal:nil
                                                                   withURL:nil
                                                                  isHotkey:YES
                                                                   makeKey:YES
                                                               canActivate:YES
                                                                   command:nil
                                                                     block:nil];
    self.birthingWindow = NO;

    [self.delegate hotKeyDidCreateWindow:self];
    PseudoTerminal *result = nil;
    if (session) {
        result = [[iTermController sharedInstance] terminalWithSession:session];
    }
    self.windowControllerBeingBorn = nil;
    return result;
}

- (void)rollInFinished {
    DLog(@"Roll-in finished for %@", self);
    _rollingIn = NO;
    [self.windowController.window makeKeyAndOrderFront:nil];
    [self.windowController.window makeFirstResponder:self.windowController.currentSession.textview];
    [[self.windowController currentTab] recheckBlur];
}

- (void)didFinishRollingOut {
    DLog(@"didFinishRollingOut");
    // NOTE: There used be an option called "closing hotkey switches spaces". I've removed the
    // "off" behavior and made the "on" behavior the only option. Various things didn't work
    // right, and the worst one was in this thread: "[iterm2-discuss] Possible bug when using Hotkey window?"
    // where clicks would be swallowed up by the invisible hotkey window. The "off" mode would do
    // this:
    // [[term window] orderWindow:NSWindowBelow relativeTo:0];
    // And the window was invisible only because its alphaValue was set to 0 elsewhere.
    
    DLog(@"Call orderOut: on terminal %@", self.windowController);
    [self.windowController.window orderOut:self];
    DLog(@"Returned from orderOut:. Set _rollingOut=NO");
    
    // This must be done after orderOut: so autoHideHotKeyWindowsExcept: will know to throw out the
    // previous state.
    _rollingOut = NO;

    DLog(@"Invoke didFinishRollingOutProfileHotKey:");
    [self.delegate didFinishRollingOutProfileHotKey:self];
}

- (BOOL)autoHides {
    return [iTermProfilePreferences boolForKey:KEY_HOTKEY_AUTOHIDE inProfile:self.profile];
}

- (void)hideHotKeyWindow {
    const BOOL activateStickyHotkeyWindow = (!self.autoHides &&
                                             !self.windowController.window.isKeyWindow);
    if (activateStickyHotkeyWindow && ![NSApp isActive]) {
        DLog(@"Storing previously active app");
        [self.delegate storePreviouslyActiveApp];
    }
    const BOOL hotkeyWindowOnOtherSpace = ![self.windowController.window isOnActiveSpace];
    if (hotkeyWindowOnOtherSpace || activateStickyHotkeyWindow) {
        DLog(@"Hotkey window is active on another space, or else it doesn't autohide but isn't key. Switch to it.");
        [NSApp activateIgnoringOtherApps:YES];
        [self.windowController.window makeKeyAndOrderFront:nil];
    } else {
        DLog(@"Hide hotkey window");
        [self hideHotKeyWindowAnimated:YES suppressHideApp:NO];
    }
}

- (void)showHotKeyWindow {
    DLog(@"showHotKeyWindow: %@", self);
    [self.delegate storePreviouslyActiveApp];

    if (!self.windowController.weaklyReferencedObject) {
        DLog(@"Create new hotkey window");
        [self createWindow];
    }
    [self rollIn];
}

- (void)hideHotKeyWindowAnimated:(BOOL)animated
                 suppressHideApp:(BOOL)suppressHideApp {
    DLog(@"Hide hotkey window. animated=%@ suppressHideApp=%@", @(animated), @(suppressHideApp));

    if (suppressHideApp) {
        [self.delegate suppressHideApp];
    }
    if (!animated) {
        [self fastHideHotKeyWindow];
    }

    // This used to iterate over hotkeyTerm.window.sheets, which seemed to
    // work, but sheets wasn't defined prior to 10.9. Consider going back to
    // that technique if this doesn't work well.
    while (self.windowController.window.attachedSheet) {
        [NSApp endSheet:self.windowController.window.attachedSheet];
    }
    [self rollOut];
}

- (void)windowWillClose {
    self.windowController = nil;
    self.restorableState = nil;
}

- (void)fastHideHotKeyWindow {
    DLog(@"fastHideHotKeyWindow");
    if (self.windowController.weaklyReferencedObject) {
        DLog(@"fastHideHotKeyWindow - found a hot term");
        // Temporarily tell the hotkeywindow that it's not hot so that it doesn't try to hide itself
        // when losing key status.
        self.windowController.isHotKeyWindow = NO;

        // Immediately hide the hotkey window.
        [self.windowController.window orderOut:nil];
        self.windowController.window.alphaValue = 0;

        // Restore hotkey window's status.
        self.windowController.isHotKeyWindow = YES;
    }
}

#pragma mark - Notifications

- (void)terminalWindowControllerCreated:(NSNotification *)notification {
    if (self.birthingWindow) {
        self.windowControllerBeingBorn = notification.object;
    }
}

@end
