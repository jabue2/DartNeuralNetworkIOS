#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface HomographyHelper : NSObject
// This method expects two arrays of NSValue (wrapping CGPoint) of equal length (at least 4 points)
// and returns a 3x3 homography matrix as a simd_float3x3.
+ (simd_float3x3)findHomographyFromPoints:(NSArray<NSValue *> *)srcPoints
                                 toPoints:(NSArray<NSValue *> *)dstPoints;
@end

NS_ASSUME_NONNULL_END
