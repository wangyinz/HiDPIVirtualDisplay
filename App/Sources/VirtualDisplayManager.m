// VirtualDisplayManager.m
// Implementation of virtual display creation using private CoreGraphics APIs
// Compiled with -fno-objc-arc - uses manual retain/release

#import "VirtualDisplayManager.h"
#import "CGVirtualDisplayPrivate.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <xpc/xpc.h>

static void *VDMSkyLightHandle(void);

// Compatibility for older SDKs
#ifndef kIOMainPortDefault
#define kIOMainPortDefault 0
#endif

// Global array to retain windows that appear during display operations
// This prevents the CGVirtualDisplay framework's internal windows from being over-released
static NSMutableArray *_retainedWindows = nil;
static id _windowObserver = nil;

@interface VirtualDisplayManager () {
    CGVirtualDisplay *_display;
    CGVirtualDisplayDescriptor *_descriptor;
    CGVirtualDisplaySettings *_settings;
    CGVirtualDisplayMode *_mode;
    NSArray *_modesArray;
    NSString *_displayName;
    CGDirectDisplayID _currentDisplayID;
    BOOL _dockRepairInFlight;
}
@end

/// Read a 16-bit fixed-point chromaticity value from a nested CF dictionary.
/// DisplayAttributes stores chromaticity as integers in [0, 65536] range.
static CGFloat cfDictGetFixed16(CFDictionaryRef dict, CFStringRef key) {
    CFNumberRef ref = CFDictionaryGetValue(dict, key);
    if (!ref) return 0;
    int32_t raw = 0;
    CFNumberGetValue(ref, kCFNumberSInt32Type, &raw);
    return (CGFloat)raw / 65536.0;
}

@implementation VirtualDisplayManager

// Helper function to retain a window if not already retained
static void retainWindowIfNeeded(NSWindow *window) {
    if (window && ![_retainedWindows containsObject:window]) {
        [window retain];
        [_retainedWindows addObject:window];
        NSLog(@"VDM: Retained window: %p (class: %@, title: %@)",
              window, [window class], [window title] ?: @"<untitled>");
    }
}

+ (void)initialize {
    if (self == [VirtualDisplayManager class]) {
        // Initialize the retained windows array
        _retainedWindows = [[NSMutableArray alloc] init];
        [_retainedWindows retain];
        NSLog(@"VDM: Window retention array initialized");

        // Observe multiple window notifications to catch framework-created windows
        NSArray *notifications = @[
            NSWindowDidBecomeMainNotification,
            NSWindowDidBecomeKeyNotification,
            NSWindowDidUpdateNotification,
            NSWindowDidChangeScreenNotification,
            NSWindowDidExposeNotification
        ];

        for (NSNotificationName notifName in notifications) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:notifName
                object:nil
                queue:nil
                usingBlock:^(NSNotification *notification) {
                    retainWindowIfNeeded(notification.object);
                }];
        }

        // Also prevent windows from being released when they close
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification
            object:nil
            queue:nil
            usingBlock:^(NSNotification *notification) {
                NSWindow *window = notification.object;
                if (window) {
                    // Extra retain to counteract the close release
                    [window retain];
                    NSLog(@"VDM: Extra retain on closing window: %p", window);
                }
            }];

        NSLog(@"VDM: Window observers installed");
    }
}

+ (instancetype)sharedManager {
    static VirtualDisplayManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[VirtualDisplayManager alloc] init];
        [sharedManager retain];
        NSLog(@"VDM: Shared manager created");
    });
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _display = nil;
        _descriptor = nil;
        _settings = nil;
        _mode = nil;
        _modesArray = nil;
        _displayName = nil;
        _currentDisplayID = kCGNullDirectDisplay;

        // Retain all existing windows to prevent crash from framework window over-release
        for (NSWindow *window in [NSApp windows]) {
            retainWindowIfNeeded(window);
        }

        // Scan for windows once at init. The notification observers above will
        // catch any new windows going forward. The previous 2-second repeating
        // timer added unnecessary main-thread load during display operations.

        NSLog(@"VDM: Manager initialized");
    }
    return self;
}

- (CGDirectDisplayID)currentDisplayID {
    return _currentDisplayID;
}

// Internal creation method that accepts explicit color primaries.
// Both public create methods delegate to this.
- (CGDirectDisplayID)_createDisplayInternalWithWidth:(unsigned int)width
                                              height:(unsigned int)height
                                                 ppi:(unsigned int)ppi
                                               hiDPI:(BOOL)hiDPI
                                                name:(NSString *)name
                                         refreshRate:(double)refreshRate
                                          whitePoint:(CGPoint)whitePoint
                                          redPrimary:(CGPoint)redPrimary
                                        greenPrimary:(CGPoint)greenPrimary
                                         bluePrimary:(CGPoint)bluePrimary {

    NSLog(@"VDM: ========== CREATE START ==========");
    NSLog(@"VDM: %ux%u @ %u PPI, HiDPI=%@", width, height, ppi, hiDPI ? @"YES" : @"NO");
    NSLog(@"VDM: Primaries: R(%.4f,%.4f) G(%.4f,%.4f) B(%.4f,%.4f) W(%.4f,%.4f)",
          redPrimary.x, redPrimary.y, greenPrimary.x, greenPrimary.y,
          bluePrimary.x, bluePrimary.y, whitePoint.x, whitePoint.y);

    // Clear any leftovers from a previous create so overwriting the ivars
    // below can't leak partially-created objects.
    [self releaseDisplayObjects];

    @try {
        // alloc/init already returns an owned (+1) reference; the extra
        // retains this code used to add meant releaseDisplayObjects never
        // dropped the refcount to zero, so the CGVirtualDisplay never
        // deallocated and the virtual display survived every in-process
        // "destroy" (the phantom-display source).
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = hiDPI ? 1 : 0;
        _settings = settings;

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        // Use a dedicated serial queue instead of the main queue.
        // Main queue contention between virtual display callbacks and UI/timer
        // work contributed to the WindowServer deadlock.
        dispatch_queue_t eventQueue = dispatch_queue_create("com.hidpi.virtualdisplay.events",
                                                            DISPATCH_QUEUE_SERIAL);
        descriptor.queue = eventQueue;  // property retains it
        dispatch_release(eventQueue);

        _displayName = [name copy];
        descriptor.name = _displayName;

        // Set color primaries — when these match the physical display's EDID,
        // ColorSync can use an identity transform (no per-frame color conversion).
        descriptor.whitePoint = whitePoint;
        descriptor.redPrimary = redPrimary;
        descriptor.greenPrimary = greenPrimary;
        descriptor.bluePrimary = bluePrimary;

        float widthInInches = (float)width / (float)ppi;
        float heightInInches = (float)height / (float)ppi;
        descriptor.sizeInMillimeters = CGSizeMake(widthInInches * 25.4f, heightInInches * 25.4f);

        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        descriptor.vendorID = 0x1234;
        descriptor.productID = 0x5678;
        // Use a fixed serial so ColorSync can reuse the same ICC profile
        // across restarts. arc4random() was generating a new serial every time,
        // causing ColorSync to create thousands of unique ICC profiles (4000+)
        // which made colorsync.displayservices spin at 60%+ CPU.
        descriptor.serialNum = 0x4731;
        descriptor.terminationHandler = nil;

        _descriptor = descriptor;

        unsigned int modeWidth = hiDPI ? width / 2 : width;
        unsigned int modeHeight = hiDPI ? height / 2 : height;
        NSLog(@"VDM: Mode: %ux%u", modeWidth, modeHeight);

        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:modeWidth
                                                                          height:modeHeight
                                                                     refreshRate:refreshRate];
        if (!mode) {
            NSLog(@"VDM: ERROR - Failed to create mode");
            [self releaseDisplayObjects];
            return kCGNullDirectDisplay;
        }
        _mode = mode;

        // Single-mode array — adding a 60 Hz fallback caused macOS to silently
        // pick the fallback over the requested rate after some mirror configs,
        // making the virtual render at 60 Hz even when the user asked for 120
        // (the panel scanned at 120 but content only updated 60 times/sec).
        // The caller is now responsible for clamping the requested rate to a
        // value the panel actually supports (via maxSupportedRefreshRate).
        NSMutableArray *modes = [NSMutableArray arrayWithObject:_mode];
        _modesArray = [modes retain];
        _settings.modes = _modesArray;

        NSLog(@"VDM: Creating display...");
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:_descriptor];
        if (!display) {
            NSLog(@"VDM: ERROR - Failed to create display");
            [self releaseDisplayObjects];
            return kCGNullDirectDisplay;
        }
        _display = display;
        NSLog(@"VDM: Display created: %p", _display);

        NSLog(@"VDM: Applying settings...");
        BOOL applied = [_display applySettings:_settings];
        if (!applied) {
            NSLog(@"VDM: ERROR - Failed to apply settings");
            [self releaseDisplayObjects];
            return kCGNullDirectDisplay;
        }
        NSLog(@"VDM: Settings applied");

        CGDirectDisplayID displayID = _display.displayID;
        _currentDisplayID = displayID;
        NSLog(@"VDM: Display ID: %u", displayID);

        if (displayID == 0 || displayID == kCGNullDirectDisplay) {
            NSLog(@"VDM: ERROR - Invalid display ID");
            [self releaseDisplayObjects];
            return kCGNullDirectDisplay;
        }

        NSLog(@"VDM: ========== CREATE COMPLETE ==========");
        return displayID;

    } @catch (NSException *exception) {
        NSLog(@"VDM: EXCEPTION: %@", exception);
        [self releaseDisplayObjects];
        return kCGNullDirectDisplay;
    }
}

- (CGDirectDisplayID)createVirtualDisplayWithWidth:(unsigned int)width
                                            height:(unsigned int)height
                                               ppi:(unsigned int)ppi
                                             hiDPI:(BOOL)hiDPI
                                              name:(NSString *)name
                                       refreshRate:(double)refreshRate {
    // Default to sRGB primaries when no target display is specified
    return [self _createDisplayInternalWithWidth:width height:height ppi:ppi
                                          hiDPI:hiDPI name:name refreshRate:refreshRate
                                     whitePoint:CGPointMake(0.3127, 0.3290)
                                     redPrimary:CGPointMake(0.6400, 0.3300)
                                   greenPrimary:CGPointMake(0.3000, 0.6000)
                                    bluePrimary:CGPointMake(0.1500, 0.0600)];
}

- (CGDirectDisplayID)createG9VirtualDisplayWithScaledWidth:(unsigned int)scaledWidth
                                              scaledHeight:(unsigned int)scaledHeight {
    // Detect refresh rate from the actual external display, not the built-in screen
    double refreshRate = 60.0;
    CGDirectDisplayID displayList[32];
    uint32_t displayCount;
    if (CGGetOnlineDisplayList(32, displayList, &displayCount) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < displayCount; i++) {
            if (!CGDisplayIsBuiltin(displayList[i]) && CGDisplayVendorNumber(displayList[i]) != 0x1234) {
                CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayList[i]);
                if (mode) {
                    double rate = CGDisplayModeGetRefreshRate(mode);
                    CGDisplayModeRelease(mode);
                    if (rate > 0) {
                        refreshRate = rate;
                        NSLog(@"VDM: Detected external monitor refresh rate: %.0f Hz", rate);
                        break;
                    }
                }
            }
        }
    }
    NSLog(@"VDM: G9 convenience method using refresh rate: %.1f Hz", refreshRate);

    return [self createVirtualDisplayWithWidth:scaledWidth * 2
                                        height:scaledHeight * 2
                                           ppi:140
                                         hiDPI:YES
                                          name:@"G9 HiDPI Virtual"
                                   refreshRate:refreshRate];
}

- (BOOL)mirrorDisplay:(CGDirectDisplayID)sourceDisplayID
            toDisplay:(CGDirectDisplayID)targetDisplayID {
    return [self mirrorDisplay:sourceDisplayID toDisplay:targetDisplayID atRate:0.0];
}

/// Copy the panel's desktop-usable mode list. Caller owns the result.
static CFArrayRef VDMCopyDesktopModes(CGDirectDisplayID displayID) {
    NSDictionary *opts = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    return CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)opts);
}

/// IOKit marks the timings the panel declares as its own. Not in the CoreGraphics
/// headers, but CGDisplayModeGetIOFlags returns the IOKit flag word verbatim.
static const uint32_t kVDMDisplayModeNativeFlag = 0x02000000;

/// Whether a mode maps one point to one pixel, i.e. a real scanout mode rather
/// than a HiDPI or scaled duplicate of a smaller one.
static BOOL VDMIsOneToOne(CGDisplayModeRef mode) {
    return CGDisplayModeGetWidth(mode) == CGDisplayModeGetPixelWidth(mode) &&
           CGDisplayModeGetHeight(mode) == CGDisplayModeGetPixelHeight(mode);
}

/// The panel's native pixel grid.
///
/// Prefers the timings IOKit flags as native, because "biggest mode in the list"
/// is not trustworthy here: while a mirror is attached, the target inherits the
/// source's mode, so a physical 7680x2160 panel mirroring a 5120x1440 HiDPI
/// virtual reports a 10240x2880 mode it cannot actually scan out. Falls back to
/// the largest one-to-one mode for panels that flag nothing.
/// Returns NO when the panel reports nothing usable.
/// Native pixel grid within an already-copied mode list. Callers that also walk
/// the list share this so both see one snapshot: the list can change under a
/// mode switch, and picking a native size out of one array while searching
/// another can leave the search with nothing to match.
static BOOL VDMNativePixelSizeInModes(CFArrayRef modes, size_t *outWidth, size_t *outHeight) {
    size_t flaggedW = 0, flaggedH = 0, flaggedPixels = 0;
    size_t oneToOneW = 0, oneToOneH = 0, oneToOnePixels = 0;

    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) continue;
        // Both candidates require one-to-one. The native flag travels with an
        // inherited mirror mode as readily as with a real one, so on its own it
        // is not enough to tell the panel's own timings from the source's.
        if (!VDMIsOneToOne(mode)) continue;

        size_t w = CGDisplayModeGetPixelWidth(mode);
        size_t h = CGDisplayModeGetPixelHeight(mode);

        if ((CGDisplayModeGetIOFlags(mode) & kVDMDisplayModeNativeFlag) && w * h > flaggedPixels) {
            flaggedPixels = w * h;
            flaggedW = w;
            flaggedH = h;
        }
        if (w * h > oneToOnePixels) {
            oneToOnePixels = w * h;
            oneToOneW = w;
            oneToOneH = h;
        }
    }

    size_t w = flaggedPixels ? flaggedW : oneToOneW;
    size_t h = flaggedPixels ? flaggedH : oneToOneH;
    if (w == 0 || h == 0) return NO;
    if (outWidth) *outWidth = w;
    if (outHeight) *outHeight = h;
    return YES;
}

BOOL VDMNativePixelSize(CGDirectDisplayID displayID, size_t *outWidth, size_t *outHeight) {
    CFArrayRef modes = VDMCopyDesktopModes(displayID);
    if (!modes) return NO;
    BOOL found = VDMNativePixelSizeInModes(modes, outWidth, outHeight);
    CFRelease(modes);
    return found;
}

// A VRR mode reports its maximum refresh rate through CoreGraphics, so fixed
// 60 Hz and 48–60 Hz can have identical public rates and IO flags. Resolve the
// per-mode SkyLight query at runtime; missing symbols keep the legacy choice.
typedef bool (*SLModeVRRQueryFn)(CGDirectDisplayID, uint32_t);

static NSInteger VDMModeVariableRefreshState(CGDirectDisplayID displayID, CGDisplayModeRef mode) {
    if (!mode) return -1;
    static SLModeVRRQueryFn query = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = VDMSkyLightHandle();
        if (handle) query = (SLModeVRRQueryFn)dlsym(handle, "SLSIsDisplayModeVRR");
    });
    return query ? (query(displayID, CGDisplayModeGetIODisplayModeID(mode)) ? 1 : 0) : -1;
}

NSInteger VDMVariableRefreshState(CGDirectDisplayID displayID) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    NSInteger state = VDMModeVariableRefreshState(displayID, mode);
    if (mode) CGDisplayModeRelease(mode);
    return state;
}

/// Fixed modes win ties; unknown metadata preserves enumeration order.
static NSInteger VDMRefreshPreference(CGDirectDisplayID displayID, CGDisplayModeRef mode) {
    if (!mode) return 3;
    NSInteger state = VDMModeVariableRefreshState(displayID, mode);
    return state < 0 ? 1 : (state == 0 ? 0 : 2);
}

/// Pick a native physical-output mode independently of the mirror's desktop size.
///
/// Resolution wins over refresh rate. Pinning below the native pixel grid to
/// hit a requested rate makes the monitor rescale everything the mirror sends
/// it, which costs far more detail than the extra frames are worth. Bandwidth
/// limited links hit this constantly: a panel that does native at 60 Hz but
/// only half-height at 120 Hz used to get pinned to the half-height mode.
///
/// Order of preference:
///   1. native pixel grid at the requested rate
///   2. native pixel grid at its own highest rate
///   3. largest mode at the requested rate (only if native size is unknown)
///
/// Returns NULL if nothing matches. Caller owns the returned mode and must
/// release it via CGDisplayModeRelease().
static CGDisplayModeRef CopyBestModeAtRate(CGDirectDisplayID displayID, double refreshRate) {
    CFArrayRef modes = VDMCopyDesktopModes(displayID);
    if (!modes) return NULL;

    size_t nativeW = 0, nativeH = 0;
    BOOL haveNative = VDMNativePixelSizeInModes(modes, &nativeW, &nativeH);

    CGDisplayModeRef nativeAtRate = NULL;   // native grid, requested rate
    CGDisplayModeRef nativeFastest = NULL;  // native grid, highest rate
    CGDisplayModeRef anyAtRate = NULL;      // last resort: biggest at requested rate
    double nativeFastestRate = -1;
    size_t anyAtRatePixels = 0;

    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)) continue;
        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t ph = CGDisplayModeGetPixelHeight(mode);
        // Keep the physical target in a one-to-one native mode. With a larger
        // HiDPI mirror source, a 2x physical mode clipped ordinary and text
        // cursors on the QN990F. The source still owns the HiDPI desktop.
        if (!VDMIsOneToOne(mode)) continue;

        double rate = CGDisplayModeGetRefreshRate(mode);
        BOOL rateMatches = fabs(rate - refreshRate) <= 0.5;

        if (haveNative && pw == nativeW && ph == nativeH) {
            if (rateMatches && VDMRefreshPreference(displayID, mode) < VDMRefreshPreference(displayID, nativeAtRate)) {
                nativeAtRate = mode;
            }
            // nativeFastestRate is seeded at -1, so a panel that reports 0 Hz
            // for its native timing still lands here rather than falling
            // through to a smaller mode.
            if (rate > nativeFastestRate ||
                (fabs(rate - nativeFastestRate) < 0.01 &&
                 VDMRefreshPreference(displayID, mode) < VDMRefreshPreference(displayID, nativeFastest))) {
                nativeFastestRate = rate;
                nativeFastest = mode;
            }
        }

        if (rateMatches && (pw * ph > anyAtRatePixels ||
            (pw * ph == anyAtRatePixels &&
             VDMRefreshPreference(displayID, mode) < VDMRefreshPreference(displayID, anyAtRate)))) {
            anyAtRatePixels = pw * ph;
            anyAtRate = mode;
        }
    }

    CGDisplayModeRef best = nativeAtRate;
    if (!best) best = nativeFastest;
    if (best && best != nativeAtRate) {
        NSLog(@"VDM: Panel %u has no %.1f Hz mode at native %zux%zu — keeping native at %.1f Hz "
              @"instead of dropping resolution", displayID, refreshRate, nativeW, nativeH,
              CGDisplayModeGetRefreshRate(best));
    }
    if (!best && anyAtRate) {
        NSLog(@"VDM: WARN - Panel %u offers no native-size mode, falling back to largest mode at %.1f Hz",
              displayID, refreshRate);
        best = anyAtRate;
    }

    if (best) {
        NSLog(@"VDM: Native pin selected mode %u, refresh policy: %@",
              CGDisplayModeGetIODisplayModeID(best),
              VDMRefreshPreference(displayID, best) == 0 ? @"fixed (VRR off)" : @"VRR or unknown");
    }
    CGDisplayModeRef retained = best ? (CGDisplayModeRef)CGDisplayModeRetain(best) : NULL;
    CFRelease(modes);
    return retained;
}

/// Put the target display back into `mode` after a failed mirror attempt so
/// the panel isn't stranded in the pinned mode the user never asked for.
/// Best-effort; no-op when mode is NULL or unchanged.
static void VDMRestorePinnedMode(CGDirectDisplayID displayID, CGDisplayModeRef mode) {
    if (!mode) return;
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
    BOOL unchanged = current &&
        CGDisplayModeGetWidth(current) == CGDisplayModeGetWidth(mode) &&
        CGDisplayModeGetHeight(current) == CGDisplayModeGetHeight(mode) &&
        fabs(CGDisplayModeGetRefreshRate(current) - CGDisplayModeGetRefreshRate(mode)) < 0.5;
    if (current) CGDisplayModeRelease(current);
    if (unchanged) return;

    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return;
    if (CGConfigureDisplayWithDisplayMode(config, displayID, mode, NULL) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return;
    }
    CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    NSLog(@"VDM: Restored target %u to original mode after failed mirror (err=%d)", displayID, err);
}

/// Selecting the physical native mode leaves the virtual mirror source and its
/// HiDPI desktop geometry intact. Scaled mirror-only modes may be listed by
/// CoreGraphics but are rejected when explicitly configured (error 1001).
- (BOOL)pinNativeModeForDisplay:(CGDirectDisplayID)displayID atRate:(double)refreshRate {
    if (refreshRate <= 0 || !CGDisplayIsOnline(displayID)) return NO;
    CGDisplayModeRef desired = CopyBestModeAtRate(displayID, refreshRate);
    if (!desired) return NO;

    CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
    BOOL unchanged = current &&
        CGDisplayModeGetIODisplayModeID(current) == CGDisplayModeGetIODisplayModeID(desired);
    if (current) CGDisplayModeRelease(current);
    if (unchanged) {
        CGDisplayModeRelease(desired);
        return YES;
    }

    NSLog(@"VDM: Pinning physical output %u to %zux%zu @ %.1f Hz",
          displayID, CGDisplayModeGetPixelWidth(desired),
          CGDisplayModeGetPixelHeight(desired), CGDisplayModeGetRefreshRate(desired));
    CGDisplayConfigRef config;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err == kCGErrorSuccess) {
        err = CGConfigureDisplayWithDisplayMode(config, displayID, desired, NULL);
        if (err == kCGErrorSuccess) {
            err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        } else {
            CGCancelDisplayConfiguration(config);
        }
    }
    CGDisplayModeRelease(desired);
    NSLog(@"VDM: Physical pin result: %d; variable-refresh state: %ld",
          err, (long)VDMVariableRefreshState(displayID));
    return err == kCGErrorSuccess;
}

- (BOOL)mirrorDisplay:(CGDirectDisplayID)sourceDisplayID
            toDisplay:(CGDirectDisplayID)targetDisplayID
               atRate:(double)refreshRate {

    NSLog(@"VDM: Mirror %u -> %u (pin target to %.1f Hz)",
          sourceDisplayID, targetDisplayID, refreshRate);

    // Remember the target's mode so a failed mirror doesn't strand the
    // panel in the pinned mode with no HiDPI to show for it.
    CGDisplayModeRef originalMode = CGDisplayCopyDisplayMode(targetDisplayID);

    // Establish the mirror first. macOS can replace the target timing with a
    // VRR mode here, even if a fixed native mode was selected beforehand.
    CGDisplayConfigRef configRef;
    CGError err = CGBeginDisplayConfiguration(&configRef);
    if (err != kCGErrorSuccess) {
        NSLog(@"VDM: ERROR - Begin config failed: %d", err);
        VDMRestorePinnedMode(targetDisplayID, originalMode);
        if (originalMode) CGDisplayModeRelease(originalMode);
        return NO;
    }

    err = CGConfigureDisplayMirrorOfDisplay(configRef, targetDisplayID, sourceDisplayID);
    if (err != kCGErrorSuccess) {
        NSLog(@"VDM: ERROR - Configure mirror failed: %d", err);
        CGCancelDisplayConfiguration(configRef);
        VDMRestorePinnedMode(targetDisplayID, originalMode);
        if (originalMode) CGDisplayModeRelease(originalMode);
        return NO;
    }

    // Use kCGConfigureForSession instead of kCGConfigurePermanently to avoid
    // triggering ColorSync profile persistence I/O that can stall the daemon.
    err = CGCompleteDisplayConfiguration(configRef, kCGConfigureForSession);
    if (err != kCGErrorSuccess) {
        NSLog(@"VDM: ERROR - Complete config failed: %d", err);
        VDMRestorePinnedMode(targetDisplayID, originalMode);
        if (originalMode) CGDisplayModeRelease(originalMode);
        return NO;
    }
    if (originalMode) CGDisplayModeRelease(originalMode);

    // Keep the source's HiDPI desktop, then select the physical native scanout in
    // a separate transaction. Pinning before the mirror is overwritten; combining
    // the two operations in one transaction is rejected on some configurations.
    if (refreshRate > 0 && ![self pinNativeModeForDisplay:targetDisplayID atRate:refreshRate]) {
        NSLog(@"VDM: WARN - Mirror is active but physical output pin failed");
    }

    // The source owns the HiDPI desktop; the target reports native output size.
    NSLog(@"VDM: Mirror target variable-refresh state: %ld (0=fixed, 1=VRR, -1=unknown)",
          (long)VDMVariableRefreshState(targetDisplayID));
    CGDisplayModeRef actual = CGDisplayCopyDisplayMode(targetDisplayID);
    if (actual) {
        NSLog(@"VDM: Mirror success — target %u now at %zux%zu @ %.1f Hz",
              targetDisplayID,
              CGDisplayModeGetWidth(actual),
              CGDisplayModeGetHeight(actual),
              CGDisplayModeGetRefreshRate(actual));
        CGDisplayModeRelease(actual);
    } else {
        NSLog(@"VDM: Mirror success (could not read back target mode)");
    }
    return YES;
}

// Dock's outermost-edge walk includes the inactive mirror target. Its native
// pixel-sized bounds can put the right edge outside the virtual desktop. The
// session's Dock placement service can select the source without changing the
// physical mode (changing that mode's scale regresses the hardware cursor).
static BOOL VDMDockRepairApplies(CGDirectDisplayID source, CGDirectDisplayID target) {
    if (!source || !target || CGMainDisplayID() != source ||
        !CGDisplayIsOnline(source) || !CGDisplayIsOnline(target) ||
        CGDisplayMirrorsDisplay(target) != source) return NO;
    CGDirectDisplayID active[2] = {0};
    uint32_t count = 0;
    // Do not take over Dock placement while another desktop/Sidecar is active.
    return CGGetActiveDisplayList(2, active, &count) == kCGErrorSuccess &&
           count == 1 && active[0] == source;
}

- (void)repairDockPlacementForSource:(CGDirectDisplayID)sourceDisplayID
                  mirroredToDisplay:(CGDirectDisplayID)targetDisplayID {
    NSAssert([NSThread isMainThread], @"Dock repair must run on the main queue");
    if (_dockRepairInFlight || sourceDisplayID != _currentDisplayID ||
        !VDMDockRepairApplies(sourceDisplayID, targetDisplayID)) return;

    __block xpc_connection_t connection = xpc_connection_create_mach_service(
        "com.apple.dock.sidecar", dispatch_get_main_queue(), 0);
    if (!connection) return;
    _dockRepairInFlight = YES;
    __block BOOL finished = NO;
    __block BOOL requestedMove = NO;
    // Under MRC the __block connection is not retained by the blocks. The
    // create reference is released exactly once, including error/timeout paths.
    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        self->_dockRepairInFlight = NO;
        xpc_connection_cancel(connection);
        xpc_release(connection);
        connection = NULL;
    };
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (finished) return;
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) {
            finish();
            return;
        }
        if (xpc_dictionary_get_uint64(event, "msg") != 100) return;
        if (sourceDisplayID != self->_currentDisplayID ||
            !VDMDockRepairApplies(sourceDisplayID, targetDisplayID)) {
            finish();
            return;
        }
        uint64_t dockDisplay = xpc_dictionary_get_uint64(event, "disp");
        if (requestedMove) {
            NSLog(@"VDM: Dock placement verified: source=%u, Dock=%llu",
                  sourceDisplayID, (unsigned long long)dockDisplay);
            finish();
        } else if (dockDisplay == targetDisplayID) {
            requestedMove = YES;
            xpc_object_t move = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_uint64(move, "msg", 2);
            xpc_dictionary_set_uint64(move, "disp", sourceDisplayID);
            xpc_connection_send_message(connection, move);
            xpc_release(move);
        } else {
            // Already on the source, or on an unrelated display: leave it alone.
            finish();
        }
    });
    xpc_connection_resume(connection);
    xpc_object_t query = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(query, "msg", 1);
    xpc_connection_send_message(connection, query);
    xpc_release(query);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (!finished && requestedMove) NSLog(@"VDM: Dock placement request timed out");
        finish();
    });
}

- (BOOL)stopMirroringForDisplay:(CGDirectDisplayID)displayID {
    NSLog(@"VDM: Stop mirror for %u", displayID);

    CGDisplayConfigRef configRef;
    CGError err = CGBeginDisplayConfiguration(&configRef);
    if (err != kCGErrorSuccess) return NO;

    err = CGConfigureDisplayMirrorOfDisplay(configRef, displayID, kCGNullDirectDisplay);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(configRef);
        return NO;
    }

    err = CGCompleteDisplayConfiguration(configRef, kCGConfigureForSession);
    if (err != kCGErrorSuccess) return NO;

    NSLog(@"VDM: Stop mirror success");
    return YES;
}

- (void)destroyVirtualDisplay:(CGDirectDisplayID)displayID {
    NSLog(@"VDM: destroyVirtualDisplay called for %u", displayID);
    if (displayID == _currentDisplayID) {
        [self releaseDisplayObjects];
    }
}

- (void)destroyAllVirtualDisplays {
    NSLog(@"VDM: destroyAllVirtualDisplays called");
    [self releaseDisplayObjects];
}

- (void)releaseDisplayObjects {
    NSLog(@"VDM: Releasing display objects...");

    // Release in reverse order of creation
    if (_display) {
        NSLog(@"VDM: Releasing _display %p", _display);
        [_display release];
        _display = nil;
    }

    if (_modesArray) {
        [_modesArray release];
        _modesArray = nil;
    }

    if (_mode) {
        [_mode release];
        _mode = nil;
    }

    if (_settings) {
        [_settings release];
        _settings = nil;
    }

    if (_descriptor) {
        [_descriptor release];
        _descriptor = nil;
    }

    if (_displayName) {
        [_displayName release];
        _displayName = nil;
    }

    _currentDisplayID = kCGNullDirectDisplay;
    NSLog(@"VDM: Display objects released");
}

- (void)resetAllMirroring {
    NSLog(@"VDM: resetAllMirroring called");
    CGDirectDisplayID displayList[32];
    uint32_t displayCount;

    CGError err = CGGetOnlineDisplayList(32, displayList, &displayCount);
    if (err != kCGErrorSuccess) return;

    for (uint32_t i = 0; i < displayCount; i++) {
        CGDirectDisplayID displayID = displayList[i];
        CGDirectDisplayID mirrorOf = CGDisplayMirrorsDisplay(displayID);
        if (mirrorOf == kCGNullDirectDisplay) continue;
        // Only break mirror sets that involve one of OUR virtual displays
        // (vendor 0x1234). Mirroring the user configured between two of
        // their own displays is none of our business.
        if (CGDisplayVendorNumber(mirrorOf) != 0x1234 &&
            CGDisplayVendorNumber(displayID) != 0x1234) {
            NSLog(@"VDM: Leaving unrelated mirror set alone (%u mirrors %u)", displayID, mirrorOf);
            continue;
        }
        [self stopMirroringForDisplay:displayID];
    }
    NSLog(@"VDM: Reset mirroring complete");
}

- (NSArray<NSDictionary *> *)listAllDisplays {
    NSMutableArray *displays = [NSMutableArray array];
    CGDirectDisplayID displayList[32];
    uint32_t displayCount;

    if (CGGetOnlineDisplayList(32, displayList, &displayCount) != kCGErrorSuccess) {
        return displays;
    }

    for (uint32_t i = 0; i < displayCount; i++) {
        CGDirectDisplayID displayID = displayList[i];
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
        if (mode) {
            [displays addObject:@{
                @"id": @(displayID),
                @"width": @(CGDisplayModeGetWidth(mode)),
                @"height": @(CGDisplayModeGetHeight(mode)),
                @"isMain": @(CGDisplayIsMain(displayID)),
                @"isBuiltin": @(CGDisplayIsBuiltin(displayID)),
                @"mirrorOf": @(CGDisplayMirrorsDisplay(displayID)),
                @"isVirtual": @(displayID == _currentDisplayID)
            }];
            CGDisplayModeRelease(mode);
        }
    }
    return displays;
}

- (CGDirectDisplayID)mainDisplayID {
    return CGMainDisplayID();
}

- (BOOL)isVirtualDisplay:(CGDirectDisplayID)displayID {
    return displayID == _currentDisplayID;
}

#pragma mark - EDID Chromaticity Reading

- (BOOL)getChromaticityForDisplay:(CGDirectDisplayID)displayID
                            redX:(CGFloat *)redX redY:(CGFloat *)redY
                          greenX:(CGFloat *)greenX greenY:(CGFloat *)greenY
                           blueX:(CGFloat *)blueX blueY:(CGFloat *)blueY
                          whiteX:(CGFloat *)whiteX whiteY:(CGFloat *)whiteY {

    uint32_t targetVendor = CGDisplayVendorNumber(displayID);
    uint32_t targetProduct = CGDisplayModelNumber(displayID);
    NSLog(@"VDM: Reading EDID chromaticity for display %u (vendor=%u, product=%u)",
          displayID, targetVendor, targetProduct);

    // Strategy 1: Apple Silicon — read DisplayAttributes from IOMobileFramebufferShim.
    // On Apple Silicon Macs, display metadata (including parsed EDID chromaticity)
    // lives in the DisplayAttributes dictionary on IOMobileFramebufferShim services.
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                     IOServiceMatching("IOMobileFramebufferShim"),
                                                     &iter);
    if (kr == KERN_SUCCESS) {
        io_service_t service;
        while ((service = IOIteratorNext(iter)) != 0) {
            CFDictionaryRef attrs = IORegistryEntryCreateCFProperty(
                service, CFSTR("DisplayAttributes"), kCFAllocatorDefault, 0);
            IOObjectRelease(service);
            if (!attrs) continue;

            CFDictionaryRef productAttrs = CFDictionaryGetValue(attrs, CFSTR("ProductAttributes"));
            if (!productAttrs) { CFRelease(attrs); continue; }

            uint32_t vendor = 0, product = 0;
            CFNumberRef numRef;

            numRef = CFDictionaryGetValue(productAttrs, CFSTR("LegacyManufacturerID"));
            if (numRef) CFNumberGetValue(numRef, kCFNumberSInt32Type, &vendor);

            numRef = CFDictionaryGetValue(productAttrs, CFSTR("ProductID"));
            if (numRef) CFNumberGetValue(numRef, kCFNumberSInt32Type, &product);

            if (vendor != targetVendor || product != targetProduct) {
                CFRelease(attrs);
                continue;
            }

            // Found the matching display — extract chromaticity
            CFDictionaryRef chroma = CFDictionaryGetValue(attrs, CFSTR("Chromaticity"));
            CFDictionaryRef wp = CFDictionaryGetValue(attrs, CFSTR("DefaultWhitePoint"));

            if (chroma && wp) {
                CFDictionaryRef red = CFDictionaryGetValue(chroma, CFSTR("Red"));
                CFDictionaryRef green = CFDictionaryGetValue(chroma, CFSTR("Green"));
                CFDictionaryRef blue = CFDictionaryGetValue(chroma, CFSTR("Blue"));

                if (red && green && blue) {
                    *redX   = cfDictGetFixed16(red,   CFSTR("X"));
                    *redY   = cfDictGetFixed16(red,   CFSTR("Y"));
                    *greenX = cfDictGetFixed16(green, CFSTR("X"));
                    *greenY = cfDictGetFixed16(green, CFSTR("Y"));
                    *blueX  = cfDictGetFixed16(blue,  CFSTR("X"));
                    *blueY  = cfDictGetFixed16(blue,  CFSTR("Y"));
                    *whiteX = cfDictGetFixed16(wp,    CFSTR("X"));
                    *whiteY = cfDictGetFixed16(wp,    CFSTR("Y"));

                    NSLog(@"VDM: EDID chromaticity (DisplayAttributes):");
                    NSLog(@"VDM:   Red:   (%.4f, %.4f)", *redX, *redY);
                    NSLog(@"VDM:   Green: (%.4f, %.4f)", *greenX, *greenY);
                    NSLog(@"VDM:   Blue:  (%.4f, %.4f)", *blueX, *blueY);
                    NSLog(@"VDM:   White: (%.4f, %.4f)", *whiteX, *whiteY);

                    CFRelease(attrs);
                    IOObjectRelease(iter);
                    return YES;
                }
            }
            CFRelease(attrs);
        }
        IOObjectRelease(iter);
    }

    // Strategy 2: Intel fallback — read raw EDID from IODisplayConnect services.
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IODisplayConnect"),
                                       &iter);
    if (kr == KERN_SUCCESS) {
        io_service_t service;
        while ((service = IOIteratorNext(iter)) != 0) {
            CFDataRef edidData = IORegistryEntryCreateCFProperty(
                service, CFSTR("IODisplayEDID"), kCFAllocatorDefault, 0);
            IOObjectRelease(service);
            if (!edidData) continue;

            const UInt8 *bytes = CFDataGetBytePtr(edidData);
            CFIndex len = CFDataGetLength(edidData);

            if (len >= 12) {
                // EDID manufacturer ID: bytes 8-9 (big-endian PnP compressed ASCII)
                uint16_t mfg  = ((uint16_t)bytes[8] << 8) | bytes[9];
                // EDID product code: bytes 10-11 (little-endian)
                uint16_t prod = ((uint16_t)bytes[11] << 8) | bytes[10];

                if (mfg == targetVendor && prod == targetProduct && len >= 35) {
                    // EDID chromaticity: bytes 25-34 (10-bit values, /1024)
                    UInt8 b25 = bytes[25], b26 = bytes[26];
                    uint16_t rx = ((uint16_t)bytes[27] << 2) | ((b25 >> 6) & 0x03);
                    uint16_t ry = ((uint16_t)bytes[28] << 2) | ((b25 >> 4) & 0x03);
                    uint16_t gx = ((uint16_t)bytes[29] << 2) | ((b25 >> 2) & 0x03);
                    uint16_t gy = ((uint16_t)bytes[30] << 2) | ((b25 >> 0) & 0x03);
                    uint16_t bx = ((uint16_t)bytes[31] << 2) | ((b26 >> 6) & 0x03);
                    uint16_t by = ((uint16_t)bytes[32] << 2) | ((b26 >> 4) & 0x03);
                    uint16_t wx = ((uint16_t)bytes[33] << 2) | ((b26 >> 2) & 0x03);
                    uint16_t wy = ((uint16_t)bytes[34] << 2) | ((b26 >> 0) & 0x03);

                    *redX   = (CGFloat)rx / 1024.0;
                    *redY   = (CGFloat)ry / 1024.0;
                    *greenX = (CGFloat)gx / 1024.0;
                    *greenY = (CGFloat)gy / 1024.0;
                    *blueX  = (CGFloat)bx / 1024.0;
                    *blueY  = (CGFloat)by / 1024.0;
                    *whiteX = (CGFloat)wx / 1024.0;
                    *whiteY = (CGFloat)wy / 1024.0;

                    NSLog(@"VDM: EDID chromaticity (IODisplayEDID):");
                    NSLog(@"VDM:   Red:   (%.4f, %.4f)", *redX, *redY);
                    NSLog(@"VDM:   Green: (%.4f, %.4f)", *greenX, *greenY);
                    NSLog(@"VDM:   Blue:  (%.4f, %.4f)", *blueX, *blueY);
                    NSLog(@"VDM:   White: (%.4f, %.4f)", *whiteX, *whiteY);

                    CFRelease(edidData);
                    IOObjectRelease(iter);
                    return YES;
                }
            }
            CFRelease(edidData);
        }
        IOObjectRelease(iter);
    }

    NSLog(@"VDM: WARNING - Could not read chromaticity for display %u", displayID);
    return NO;
}

#pragma mark - Color-Matched Virtual Display Creation

- (CGDirectDisplayID)createVirtualDisplayWithWidth:(unsigned int)width
                                            height:(unsigned int)height
                                               ppi:(unsigned int)ppi
                                             hiDPI:(BOOL)hiDPI
                                              name:(NSString *)name
                                       refreshRate:(double)refreshRate
                              matchingDisplay:(CGDirectDisplayID)targetDisplayID {

    NSLog(@"VDM: Creating virtual display matching physical display %u", targetDisplayID);

    CGFloat rX, rY, gX, gY, bX, bY, wX, wY;
    CGPoint white, red, green, blue;

    if ([self getChromaticityForDisplay:targetDisplayID
                                  redX:&rX redY:&rY
                                greenX:&gX greenY:&gY
                                 blueX:&bX blueY:&bY
                                whiteX:&wX whiteY:&wY]) {
        NSLog(@"VDM: Using target display's EDID chromaticity → identity ColorSync transform");
        white = CGPointMake(wX, wY);
        red   = CGPointMake(rX, rY);
        green = CGPointMake(gX, gY);
        blue  = CGPointMake(bX, bY);
    } else {
        NSLog(@"VDM: WARNING - EDID read failed, falling back to sRGB primaries");
        white = CGPointMake(0.3127, 0.3290);
        red   = CGPointMake(0.6400, 0.3300);
        green = CGPointMake(0.3000, 0.6000);
        blue  = CGPointMake(0.1500, 0.0600);
    }

    return [self _createDisplayInternalWithWidth:width height:height ppi:ppi
                                          hiDPI:hiDPI name:name refreshRate:refreshRate
                                     whitePoint:white
                                     redPrimary:red
                                   greenPrimary:green
                                    bluePrimary:blue];
}

#pragma mark - Physical HDR and output color

// SkyLight exposes per-display HDR control that stays in sync with the
// System Settings ▸ Displays "High Dynamic Range" checkbox. SkyLight is a
// private framework, so we resolve the symbols at runtime rather than link it.
typedef bool (*SLHDRQueryFn)(CGDirectDisplayID);
typedef int  (*SLHDRSetFn)(CGDirectDisplayID, bool);

static void *VDMSkyLightHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!handle) {
            NSLog(@"VDM: WARNING - could not dlopen SkyLight for display control");
        }
    });
    return handle;
}

- (BOOL)displaySupportsHDR:(CGDirectDisplayID)displayID {
    SLHDRQueryFn fn = (SLHDRQueryFn)dlsym(VDMSkyLightHandle(), "SLSDisplaySupportsHDRMode");
    return fn ? (fn(displayID) ? YES : NO) : NO;
}

- (BOOL)isHDREnabledForDisplay:(CGDirectDisplayID)displayID {
    SLHDRQueryFn fn = (SLHDRQueryFn)dlsym(VDMSkyLightHandle(), "SLSDisplayIsHDRModeEnabled");
    return fn ? (fn(displayID) ? YES : NO) : NO;
}

- (BOOL)setHDREnabled:(BOOL)enabled forDisplay:(CGDirectDisplayID)displayID {
    SLHDRSetFn fn = (SLHDRSetFn)dlsym(VDMSkyLightHandle(), "SLSDisplaySetHDRModeEnabled");
    if (!fn) {
        NSLog(@"VDM: ERROR - SLSDisplaySetHDRModeEnabled unavailable");
        return NO;
    }
    int rc = fn(displayID, enabled ? true : false);
    NSLog(@"VDM: setHDREnabled(%d) for display %u -> rc=%d", enabled, displayID, rc);
    return rc == 0;
}


// The 16-byte link description is returned as two machine words by SkyLight.
// Field mapping is the same mapping used by WS::Displays::make_link_description
// for the named CADisplay RGB/YCbCr/full/limited/HDR10 constants. The final
// output parameter of SLSGetDisplayOutputModeLinkDescriptions is the CURRENT
// link index (also used by SLSDisplayIsHDRModeEnabled), not a preferred index.
// Do not substitute IOMobileFramebuffer's different PixelEncoding enums.
typedef struct {
    uint32_t bitsPerComponent;
    uint32_t range;
    uint32_t eotf;
    uint32_t encoding;
} VDMOutputLink;
_Static_assert(sizeof(VDMOutputLink) == 16, "SkyLight link ABI");

typedef CGError (*VDMOutputCountFn)(CGDirectDisplayID, int32_t, uint32_t *);
typedef CGError (*VDMOutputLinksFn)(CGDirectDisplayID, int32_t, VDMOutputLink *, uint32_t *, uint32_t *);
typedef CGError (*VDMConfigureOutputFn)(CGDisplayConfigRef, CGDirectDisplayID, uint64_t, uint64_t);

static NSDictionary *VDMOutputDictionary(VDMOutputLink link) {
    return @{@"bitsPerComponent": @(link.bitsPerComponent), @"range": @(link.range),
             @"eotf": @(link.eotf), @"encoding": @(link.encoding)};
}

- (NSDictionary<NSString *, id> *)outputStateForDisplay:(CGDirectDisplayID)displayID {
    if (!CGDisplayIsOnline(displayID) || CGDisplayIsBuiltin(displayID) ||
        [self isVirtualDisplay:displayID]) return nil;
    void *handle = VDMSkyLightHandle();
    if (!handle) return nil;
    VDMOutputCountFn countFn = (VDMOutputCountFn)dlsym(handle, "SLSGetDisplayOutputModeCount");
    VDMOutputLinksFn linksFn = (VDMOutputLinksFn)dlsym(handle, "SLSGetDisplayOutputModeLinkDescriptions");
    if (!countFn || !linksFn) return nil;

    // A concurrent mode change can invalidate the enumeration. Retry once and
    // otherwise report unavailable rather than publish a mismatched format.
    for (int attempt = 0; attempt < 2; ++attempt) {
        CGDisplayModeRef timing = CGDisplayCopyDisplayMode(displayID);
        if (!timing) return nil;
        int32_t modeID = CGDisplayModeGetIODisplayModeID(timing);
        CGDisplayModeRelease(timing);
        uint32_t count = 0;
        if (countFn(displayID, modeID, &count) != kCGErrorSuccess || count == 0 || count > 1024) return nil;
        VDMOutputLink *links = calloc(count, sizeof(VDMOutputLink));
        if (!links) return nil;
        uint32_t capacity = count, current = UINT32_MAX;
        CGError rc = linksFn(displayID, modeID, links, &count, &current);
        timing = CGDisplayCopyDisplayMode(displayID);
        BOOL sameTiming = timing && CGDisplayModeGetIODisplayModeID(timing) == modeID;
        if (timing) CGDisplayModeRelease(timing);
        if (rc != kCGErrorSuccess || count > capacity || !sameTiming) {
            free(links);
            continue;
        }
        NSMutableArray *modes = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t i = 0; i < count; ++i) [modes addObject:VDMOutputDictionary(links[i])];
        free(links);
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:
            @{@"modes": modes, @"modeID": @(modeID)}];
        if (current < count) {
            result[@"current"] = modes[current];
            result[@"currentIndex"] = @(current);
        }
        return result;
    }
    return nil;
}

- (BOOL)setOutputMode:(NSDictionary<NSString *, NSNumber *> *)mode
          forDisplay:(CGDirectDisplayID)displayID {
    // Only exact formats the driver offers for this timing may be sent. Never
    // synthesize a combination of independent depth/range/chroma preferences.
    NSDictionary *state = [self outputStateForDisplay:displayID];
    if (!state || ![state[@"modes"] containsObject:mode]) {
        NSLog(@"VDM: output format unavailable for display %u: %@", displayID, mode);
        return NO;
    }
    void *handle = VDMSkyLightHandle();
    VDMConfigureOutputFn configure = handle ?
        (VDMConfigureOutputFn)dlsym(handle, "SLSConfigureDisplayOutputMode") : NULL;
    if (!configure) return NO;
    uint64_t first = [mode[@"bitsPerComponent"] unsignedIntValue] |
                     ((uint64_t)[mode[@"range"] unsignedIntValue] << 32);
    uint64_t second = [mode[@"eotf"] unsignedIntValue] |
                      ((uint64_t)[mode[@"encoding"] unsignedIntValue] << 32);
    CGDisplayConfigRef config = NULL;
    CGError rc = CGBeginDisplayConfiguration(&config);
    if (rc == kCGErrorSuccess) {
        rc = configure(config, displayID, first, second);
        if (rc == kCGErrorSuccess) rc = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        else CGCancelDisplayConfiguration(config);
    }
    NSLog(@"VDM: output format for display %u -> %@, rc=%d", displayID, mode, rc);
    return rc == kCGErrorSuccess;
}

@end
