// Runtime-checked SkyLight virtual display API. No private class symbols are
// linked: classes are resolved with NSClassFromString on the running system.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct { uint32_t width, height; } VDMVirtualSize;
typedef struct { float x, y; } VDMVirtualPoint;
typedef struct { VDMVirtualPoint red, green, blue, white; } VDMVirtualChromaticities;

@interface SLVirtualDisplayConfiguration : NSObject
@property(nonatomic) NSUInteger options;
- (instancetype)initWithName:(NSString *)name vendorID:(NSUInteger)vendor productID:(NSUInteger)product
    serialNumber:(NSUInteger)serial sizeInMillimeters:(VDMVirtualPoint)size
    maximumSizeInPixels:(VDMVirtualSize)pixels chromaticities:(VDMVirtualChromaticities)color
    error:(NSError **)error;
- (NSDictionary *)dictionaryRepresentation;
@end
@interface SLVirtualDisplayMode : NSObject
@property(nonatomic) double refreshDeadline;
- (instancetype)initWithSizeInPixels:(VDMVirtualSize)pixels sizeInPoints:(VDMVirtualSize)points
    refreshRate:(float)rate error:(NSError **)error;
@end
@interface SLVirtualDisplaySettings : NSObject
- (instancetype)initWithNativeMode:(SLVirtualDisplayMode *)native preferredMode:(SLVirtualDisplayMode *)preferred
    optionalModes:(NSArray *)optional rotations:(NSUInteger)rotations error:(NSError **)error;
- (NSDictionary *)dictionaryRepresentation;
@end
@interface SLVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithConfiguration:(SLVirtualDisplayConfiguration *)configuration error:(NSError **)error;
- (BOOL)applySettings:(SLVirtualDisplaySettings *)settings error:(NSError **)error;
- (void)destroy;
@end
