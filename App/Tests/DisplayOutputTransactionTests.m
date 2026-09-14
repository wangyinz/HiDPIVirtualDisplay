// Exercise the real link enumeration/staging code with an injected SkyLight
// boundary. These tests never submit a real display configuration.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <xpc/xpc.h>
#include <assert.h>
#include <string.h>
static void *TestSymbol(void *handle, const char *name);
#define dlsym TestSymbol
#import "../Sources/VirtualDisplayManager.m"
#undef dlsym

static uint32_t reportedCount = 2, returnedCount = 2, currentIndex = 1;
static int32_t observedTiming;
static int configured;
static BOOL exposeLinks = YES, exposeConfigure = YES;
static CGError queryResult = kCGErrorSuccess, configureResult = kCGErrorSuccess;
static uint64_t firstWord, secondWord;
static CGError TestCount(CGDirectDisplayID display, int32_t timing, uint32_t *count) {
    assert(display == 77); observedTiming = timing; *count = reportedCount; return queryResult;
}
static CGError TestLinks(CGDirectDisplayID display, int32_t timing, VDMOutputLink *links,
                         uint32_t *count, uint32_t *current) {
    assert(display == 77 && timing == observedTiming);
    if (*count >= 2) {
        links[0] = (VDMOutputLink){8, 1, 0, 0};
        links[1] = (VDMOutputLink){12, 1, 2, 0};
    }
    *count = returnedCount; *current = currentIndex; return queryResult;
}
static CGError TestConfigure(CGDisplayConfigRef config, CGDirectDisplayID display,
                             uint64_t first, uint64_t second) {
    assert(config == (CGDisplayConfigRef)(uintptr_t)123 && display == 77);
    configured++; firstWord = first; secondWord = second; return configureResult;
}
static void *TestSymbol(void *handle, const char *name) {
    if (!strcmp(name, "SLSGetDisplayOutputModeCount")) return (void *)TestCount;
    if (!strcmp(name, "SLSGetDisplayOutputModeLinkDescriptions")) return exposeLinks ? (void *)TestLinks : NULL;
    if (!strcmp(name, "SLSConfigureDisplayOutputMode")) return exposeConfigure ? (void *)TestConfigure : NULL;
    return NULL;
}
int main(void) { @autoreleasepool {
    CGDisplayConfigRef config = (CGDisplayConfigRef)(uintptr_t)123;
    NSDictionary *hdr = @{@"bitsPerComponent": @12, @"range": @1, @"eotf": @2, @"encoding": @0};
    assert(VDMStageOutputMode(config, 77, 1504, hdr) == kCGErrorSuccess);
    assert(observedTiming == 1504 && configured == 1); // Explicit destination timing.
    assert(firstWord == (12ULL | (1ULL << 32)) && secondWord == 2);
    NSDictionary *bad = @{@"bitsPerComponent": @16, @"range": @1, @"eotf": @2, @"encoding": @0};
    assert(VDMStageOutputMode(config, 77, 1504, bad) != kCGErrorSuccess && configured == 1);
    exposeConfigure = NO;
    assert(VDMStageOutputMode(config, 77, 1504, hdr) == kCGErrorNotImplemented && configured == 1);
    exposeConfigure = YES; exposeLinks = NO;
    assert(VDMStageOutputMode(config, 77, 1504, hdr) != kCGErrorSuccess && configured == 1);
    exposeLinks = YES; reportedCount = 0;
    assert(VDMOutputStateForTiming(77, 1504) == nil);
    reportedCount = 1025;
    assert(VDMOutputStateForTiming(77, 1504) == nil);
    reportedCount = 2; returnedCount = 3;
    assert(VDMStageOutputMode(config, 77, 1504, hdr) != kCGErrorSuccess && configured == 1);
    returnedCount = 2; currentIndex = UINT32_MAX;
    assert(VDMOutputStateForTiming(77, 1504)[@"current"] == nil);
    assert([VDMOutputStateForTiming(77, 1504)[@"modes"] count] == 2);
    queryResult = kCGErrorFailure;
    assert(VDMStageOutputMode(config, 77, 1504, hdr) != kCGErrorSuccess && configured == 1);
    queryResult = kCGErrorSuccess; configureResult = kCGErrorInvalidOperation;
    assert(VDMStageOutputMode(config, 77, 1504, hdr) == kCGErrorInvalidOperation && configured == 2);
    puts("PASS: destination timing, exact format, ABI packing, absent APIs, invalid enumeration and staging failure.");
    return 0;
} }
