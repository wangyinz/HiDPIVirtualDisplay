// Verify the production value-object builder. No display is created here.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <assert.h>
#import "../Sources/VirtualDisplayManager.m"
int main(void) { @autoreleasepool {
    if (!VDMRestrictedProviderAvailable()) {
        puts("SKIP: restricted virtual API unavailable on this macOS"); return 0;
    }
    unsigned sizes[][2]={{1920,1080},{5120,2880},{4586,1920},{7680,2160},{9600,5400},{12288,6912}};
    unsigned checks=0;
    for(unsigned i=0;i<sizeof(sizes)/sizeof(sizes[0]);i++) for(unsigned retina=0;retina<2;retina++) {
        double budget=-1;
        id settings=VDMCreateRestrictedSettings(sizes[i][0],sizes[i][1],retina,90,0,&budget);
        assert(settings && budget==0);checks++;
        NSDictionary *dict=[settings dictionaryRepresentation];NSArray *modes=dict[@"SLVirtualDisplayModes"];
        assert(modes.count==1);checks++;
        assert([dict[@"SLVirtualDisplayNativeMode"] unsignedIntValue]==0 &&
               [dict[@"SLVirtualDisplayPreferredMode"] unsignedIntValue]==0);checks++;
        NSDictionary *mode=modes[0];unsigned factor=retina?2:1;
        assert([mode[@"SLVirtualDisplayModeSizeInPixels"][@"Width"] unsignedIntValue]==sizes[i][0] &&
               [mode[@"SLVirtualDisplayModeSizeInPixels"][@"Height"] unsignedIntValue]==sizes[i][1]);checks++;
        assert([mode[@"SLVirtualDisplayModeSizeInPoints"][@"Width"] unsignedIntValue]==sizes[i][0]/factor &&
               [mode[@"SLVirtualDisplayModeSizeInPoints"][@"Height"] unsignedIntValue]==sizes[i][1]/factor);checks++;
        assert([mode[@"SLVirtualDisplayModeRefreshRate"] doubleValue]==90);checks++;
        [settings release];
    }
    id config=VDMCreateRestrictedConfiguration(9600,5400,163,@"Custom",(CGPoint){.3127,.329},
        (CGPoint){.64,.33},(CGPoint){.3,.6},(CGPoint){.15,.06});
    NSDictionary *dict=[config dictionaryRepresentation];
    assert([dict[@"SLVirtualDisplayOptions"] unsignedLongValue]==512);checks++;
    assert([dict[@"SLVirtualDisplayVendorID"] unsignedIntValue]==0x1234 &&
           [dict[@"SLVirtualDisplayProductID"] unsignedIntValue]==0x5678 &&
           [dict[@"SLVirtualDisplaySerialNumber"] unsignedIntValue]==0x4731);checks++;
    [config release];
    double budget=0;id settings=VDMCreateRestrictedSettings(3840,2160,YES,240,8,&budget);
    assert(settings && fabs(budget-1.0/240)<.000001);checks++;[settings release];
    assert(!VDMCreateRestrictedSettings(0,2160,YES,90,0,NULL));checks++;
    assert(!VDMCreateRestrictedSettings(3841,2160,YES,90,0,NULL));checks++;
    assert(!VDMCreateRestrictedSettings(3840,2160,YES,NAN,0,NULL));checks++;
    assert(!VDMCreateRestrictedSettings(32768,2160,YES,90,0,NULL));checks++;
    assert(!VDMCreateRestrictedConfiguration(3840,2160,0,@"Test",CGPointZero,CGPointZero,CGPointZero,CGPointZero));checks++;
    printf("Restricted virtual modes: %u checks passed; no display created\n",checks);
}return 0;}
