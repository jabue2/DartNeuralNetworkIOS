//
//  HomographyHelper.mm
//  DartNeuralNetwork
//
//  Created by Jan Buechele on 21.02.25.
//


// HomographyHelper.mm
#import "HomographyHelper.h"
#import <UIKit/UIKit.h>
#import <opencv2/opencv.hpp>

using namespace cv;

@implementation HomographyHelper

+ (simd_float3x3)findHomographyFromPoints:(NSArray<NSValue *> *)srcPoints
                                 toPoints:(NSArray<NSValue *> *)dstPoints {
    if (srcPoints.count < 4 || srcPoints.count != dstPoints.count) {
        return matrix_identity_float3x3;
    }
    
    std::vector<Point2f> srcVec;
    std::vector<Point2f> dstVec;
    
    for (NSValue *value in srcPoints) {
        CGPoint pt = [value CGPointValue];
        srcVec.push_back(Point2f(pt.x, pt.y));
    }
    for (NSValue *value in dstPoints) {
        CGPoint pt = [value CGPointValue];
        dstVec.push_back(Point2f(pt.x, pt.y));
    }
    
    cv::Mat H = findHomography(srcVec, dstVec, RANSAC);
    simd_float3x3 homography = matrix_identity_float3x3;
    
    if (!H.empty() && H.rows == 3 && H.cols == 3) {
        // OpenCV matrices are often of type double.
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                homography.columns[j][i] = (float)H.at<double>(i, j);
            }
        }
    }
    
    return homography;
}

@end
