// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>

#import "FLTImagePickerImageUtil.h"
#import "messages.g.h"

NS_ASSUME_NONNULL_BEGIN

@interface FLTImagePickerPhotoAssetUtil : NSObject

+ (nullable PHAsset *)getAssetFromImagePickerInfo:(NSDictionary *)info;

+ (nullable PHAsset *)getAssetFromPHPickerResult:(PHPickerResult *)result API_AVAILABLE(ios(14));

// Saves video to temporary URL. Returns nil on failure;
+ (NSURL *)saveVideoFromURL:(NSURL *)videoURL;

// Saves image with correct meta data and extention copied from the original asset.
// maxWidth and maxHeight are used only for GIF images.
+ (NSString *)saveImageWithOriginalImageData:(NSData *)originalImageData
                                       image:(UIImage *)image
                                    maxWidth:(nullable NSNumber *)maxWidth
                                   maxHeight:(nullable NSNumber *)maxHeight
                                imageQuality:(nullable NSNumber *)imageQuality;

// Save image with correct meta data and extention copied from image picker result info.
+ (NSString *)saveImageWithPickerInfo:(nullable NSDictionary *)info
                                image:(UIImage *)image
                         imageQuality:(nullable NSNumber *)imageQuality;

// MARK: - Asset Result Methods

// Saves image with correct meta data and extention copied from the original asset.
// Returns FLTAssetPickResult with path and local identifier.
+ (FLTAssetPickResult *)saveImageAsAssetWithOriginalImageData:(NSData *)originalImageData
                                                        image:(UIImage *)image
                                                     maxWidth:(nullable NSNumber *)maxWidth
                                                    maxHeight:(nullable NSNumber *)maxHeight
                                                 imageQuality:(nullable NSNumber *)imageQuality
                                              localIdentifier:(nullable NSString *)localIdentifier;

// Save image with correct meta data and extention copied from image picker result info.
// Returns FLTAssetPickResult with path and local identifier.
+ (FLTAssetPickResult *)saveImageAsAssetWithPickerInfo:(nullable NSDictionary *)info
                                                 image:(UIImage *)image
                                          imageQuality:(nullable NSNumber *)imageQuality
                                       localIdentifier:(nullable NSString *)localIdentifier;

// Saves video to temporary URL. Returns FLTAssetPickResult with path and local identifier.
+ (FLTAssetPickResult *)saveVideoAsAssetFromURL:(NSURL *)videoURL
                                localIdentifier:(nullable NSString *)localIdentifier;

@end

NS_ASSUME_NONNULL_END
