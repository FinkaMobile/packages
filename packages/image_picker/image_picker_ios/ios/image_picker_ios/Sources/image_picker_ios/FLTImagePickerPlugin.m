// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FLTImagePickerPlugin.h"
#import "FLTImagePickerPlugin_Test.h"

#import <AVFoundation/AVFoundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <Photos/Photos.h>
#import <PhotosUI/PHPhotoLibrary+PhotosUISupport.h>
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>

#import "./include/image_picker_ios/messages.g.h"
#import "FLTImagePickerImageUtil.h"
#import "FLTImagePickerMetaDataUtil.h"
#import "FLTImagePickerPhotoAssetUtil.h"
#import "FLTPHPickerSaveImageToPathOperation.h"

@implementation FLTImagePickerMethodCallContext
- (instancetype)initWithResult:(nonnull FlutterResultAdapter)result {
  if (self = [super init]) {
    _result = [result copy];
  }
  return self;
}

- (instancetype)initWithAssetResult:(nonnull FlutterAssetResultAdapter)assetResult {
  if (self = [super init]) {
    _assetResult = [assetResult copy];
  }
  return self;
}
@end

#pragma mark -

@interface FLTImagePickerPlugin ()

/// The UIImagePickerController instances that will be used when a new
/// controller would normally be created. Each call to
/// createImagePickerController will remove the current first element from
/// the array.
@property(strong, nonatomic)
    NSMutableArray<UIImagePickerController *> *imagePickerControllerOverrides;

@end

typedef NS_ENUM(NSInteger, ImagePickerClassType) { UIImagePickerClassType, PHPickerClassType };

@implementation FLTImagePickerPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FLTImagePickerPlugin *instance = [[FLTImagePickerPlugin alloc] init];
  SetUpFLTImagePickerApi(registrar.messenger, instance);
}

- (UIImagePickerController *)createImagePickerController {
  if ([self.imagePickerControllerOverrides count] > 0) {
    UIImagePickerController *controller = [self.imagePickerControllerOverrides firstObject];
    [self.imagePickerControllerOverrides removeObjectAtIndex:0];
    return controller;
  }

  return [[UIImagePickerController alloc] init];
}

- (void)setImagePickerControllerOverrides:
    (NSArray<UIImagePickerController *> *)imagePickerControllers {
  _imagePickerControllerOverrides = [imagePickerControllers mutableCopy];
}

- (UIViewController *)viewControllerWithWindow:(UIWindow *)window {
  UIWindow *windowToUse = window;
  if (windowToUse == nil) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
      if (window.isKeyWindow) {
        windowToUse = window;
        break;
      }
    }
  }

  UIViewController *topController = windowToUse.rootViewController;
  while (topController.presentedViewController) {
    topController = topController.presentedViewController;
  }
  return topController;
}

/// Returns the UIImagePickerControllerCameraDevice to use given [source].
///
/// @param source The source specification from Dart.
- (UIImagePickerControllerCameraDevice)cameraDeviceForSource:(FLTSourceSpecification *)source {
  switch (source.camera) {
    case FLTSourceCameraFront:
      return UIImagePickerControllerCameraDeviceFront;
    case FLTSourceCameraRear:
      return UIImagePickerControllerCameraDeviceRear;
  }
}

- (void)launchPHPickerWithContext:(nonnull FLTImagePickerMethodCallContext *)context
    API_AVAILABLE(ios(14)) {
  PHPickerConfiguration *config =
      [[PHPickerConfiguration alloc] initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];
  config.selectionLimit = context.maxImageCount;
  if (context.includeVideo) {
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
      [PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]
    ]];
  } else {
    config.filter = [PHPickerFilter imagesFilter];
  }

  PHPickerViewController *pickerViewController =
      [[PHPickerViewController alloc] initWithConfiguration:config];
  pickerViewController.delegate = self;
  pickerViewController.presentationController.delegate = self;
  self.callContext = context;

  if (context.requestFullMetadata) {
    [self checkPhotoAuthorizationWithPHPicker:pickerViewController];
  } else {
    [self showPhotoLibraryWithPHPicker:pickerViewController];
  }
}

- (void)launchUIImagePickerWithSource:(nonnull FLTSourceSpecification *)source
                              context:(nonnull FLTImagePickerMethodCallContext *)context {
  UIImagePickerController *imagePickerController = [self createImagePickerController];
  imagePickerController.modalPresentationStyle = UIModalPresentationCurrentContext;
  imagePickerController.delegate = self;
  if (context.includeVideo) {
    imagePickerController.mediaTypes = @[ (NSString *)kUTTypeImage, (NSString *)kUTTypeMovie ];

  } else {
    imagePickerController.mediaTypes = @[ (NSString *)kUTTypeImage ];
  }
  self.callContext = context;

  switch (source.type) {
    case FLTSourceTypeCamera:
      [self checkCameraAuthorizationWithImagePicker:imagePickerController
                                             camera:[self cameraDeviceForSource:source]];
      break;
    case FLTSourceTypeGallery:
      if (context.requestFullMetadata) {
        [self checkPhotoAuthorizationWithImagePicker:imagePickerController];
      } else {
        [self showPhotoLibraryWithImagePicker:imagePickerController];
      }
      break;
    default:
      [self sendCallResultWithError:[FlutterError errorWithCode:@"invalid_source"
                                                        message:@"Invalid image source."
                                                        details:nil]];
      break;
  }
}

#pragma mark - FLTImagePickerApi

- (void)pickImageWithSource:(nonnull FLTSourceSpecification *)source
                    maxSize:(nonnull FLTMaxSize *)maxSize
                    quality:(nullable NSNumber *)imageQuality
               fullMetadata:(BOOL)fullMetadata
                 completion:
                     (nonnull void (^)(FLTAssetPickResult *_Nullable, FlutterError *_Nullable))completion {
  [self cancelInProgressCall];
  FLTImagePickerMethodCallContext *context = [[FLTImagePickerMethodCallContext alloc]
      initWithAssetResult:^void(NSArray<FLTAssetPickResult *> *assetResults, FlutterError *error) {
        if (assetResults.count > 1) {
          completion(nil, [FlutterError errorWithCode:@"invalid_result"
                                              message:@"Incorrect number of return asset results provided"
                                              details:nil]);
        }
        completion(assetResults.firstObject, error);
      }];
  context.maxSize = maxSize;
  context.imageQuality = imageQuality;
  context.maxImageCount = 1;
  context.requestFullMetadata = fullMetadata;

  if (source.type == FLTSourceTypeGallery) {  // Capture is not possible with PHPicker
    if (@available(iOS 14, *)) {
      [self launchPHPickerWithContext:context];
    } else {
      [self launchUIImagePickerWithSource:source context:context];
    }
  } else {
    [self launchUIImagePickerWithSource:source context:context];
  }
}

- (void)pickMultiImageWithMaxSize:(nonnull FLTMaxSize *)maxSize
                          quality:(nullable NSNumber *)imageQuality
                     fullMetadata:(BOOL)fullMetadata
                            limit:(nullable NSNumber *)limit
                       completion:(nonnull void (^)(NSArray<FLTAssetPickResult *> *_Nullable,
                                                    FlutterError *_Nullable))completion {
  [self cancelInProgressCall];
  FLTImagePickerMethodCallContext *context =
      [[FLTImagePickerMethodCallContext alloc] initWithAssetResult:completion];
  context.maxSize = maxSize;
  context.imageQuality = imageQuality;
  context.requestFullMetadata = fullMetadata;
  context.maxImageCount = limit.intValue;

  if (@available(iOS 14, *)) {
    [self launchPHPickerWithContext:context];
  } else {
    // Camera is ignored for gallery mode, so the value here is arbitrary.
    [self launchUIImagePickerWithSource:[FLTSourceSpecification makeWithType:FLTSourceTypeGallery
                                                                      camera:FLTSourceCameraRear]
                                context:context];
  }
}

- (void)pickMediaWithMediaSelectionOptions:(nonnull FLTMediaSelectionOptions *)mediaSelectionOptions
                                completion:(nonnull void (^)(NSArray<FLTAssetPickResult *> *_Nullable,
                                                             FlutterError *_Nullable))completion {
  [self cancelInProgressCall];
  FLTImagePickerMethodCallContext *context =
      [[FLTImagePickerMethodCallContext alloc] initWithAssetResult:completion];
  context.maxSize = [mediaSelectionOptions maxSize];
  context.imageQuality = [mediaSelectionOptions imageQuality];
  context.requestFullMetadata = [mediaSelectionOptions requestFullMetadata];
  context.includeVideo = YES;
  NSNumber *limit = [mediaSelectionOptions limit];
  if (!mediaSelectionOptions.allowMultiple) {
    context.maxImageCount = 1;
  } else if (limit != nil) {
    context.maxImageCount = limit.intValue;
  }

  if (@available(iOS 14, *)) {
    [self launchPHPickerWithContext:context];
  } else {
    // Camera is ignored for gallery mode, so the value here is arbitrary.
    [self launchUIImagePickerWithSource:[FLTSourceSpecification makeWithType:FLTSourceTypeGallery
                                                                      camera:FLTSourceCameraRear]
                                context:context];
  }
}

- (void)pickVideoWithSource:(nonnull FLTSourceSpecification *)source
                maxDuration:(nullable NSNumber *)maxDurationSeconds
                 completion:
                     (nonnull void (^)(FLTAssetPickResult *_Nullable, FlutterError *_Nullable))completion {
  [self cancelInProgressCall];
  FLTImagePickerMethodCallContext *context = [[FLTImagePickerMethodCallContext alloc]
      initWithAssetResult:^void(NSArray<FLTAssetPickResult *> *assetResults, FlutterError *error) {
        if (assetResults.count > 1) {
          completion(nil, [FlutterError errorWithCode:@"invalid_result"
                                              message:@"Incorrect number of return asset results provided"
                                              details:nil]);
        }
        completion(assetResults.firstObject, error);
      }];
  context.maxImageCount = 1;

  UIImagePickerController *imagePickerController = [self createImagePickerController];
  imagePickerController.modalPresentationStyle = UIModalPresentationCurrentContext;
  imagePickerController.delegate = self;
  imagePickerController.mediaTypes = @[
    (NSString *)kUTTypeMovie, (NSString *)kUTTypeAVIMovie, (NSString *)kUTTypeVideo,
    (NSString *)kUTTypeMPEG4
  ];
  imagePickerController.videoQuality = UIImagePickerControllerQualityTypeHigh;

  if (maxDurationSeconds) {
    NSTimeInterval max = [maxDurationSeconds doubleValue];
    imagePickerController.videoMaximumDuration = max;
  }

  self.callContext = context;

  switch (source.type) {
    case FLTSourceTypeCamera:
      [self checkCameraAuthorizationWithImagePicker:imagePickerController
                                             camera:[self cameraDeviceForSource:source]];
      break;
    case FLTSourceTypeGallery:
      [self checkPhotoAuthorizationWithImagePicker:imagePickerController];
      break;
    default:
      [self sendCallResultWithError:[FlutterError errorWithCode:@"invalid_source"
                                                        message:@"Invalid video source."
                                                        details:nil]];
      break;
  }
}

#pragma mark -

/// If a call is still in progress, cancels it by returning an error and then clearing state.
///
/// TODO(stuartmorgan): Eliminate this, and instead track context per image picker (e.g., using
/// associated objects).
- (void)cancelInProgressCall {
  if (self.callContext) {
    [self sendCallResultWithError:[FlutterError errorWithCode:@"multiple_request"
                                                      message:@"Cancelled by a second request"
                                                      details:nil]];
    self.callContext = nil;
  }
}

- (void)showCamera:(UIImagePickerControllerCameraDevice)device
    withImagePicker:(UIImagePickerController *)imagePickerController {
  @synchronized(self) {
    if (imagePickerController.beingPresented) {
      return;
    }
  }
  // Camera is not available on simulators
  if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera] &&
      [UIImagePickerController isCameraDeviceAvailable:device]) {
    imagePickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
    imagePickerController.cameraDevice = device;
    [[self viewControllerWithWindow:nil] presentViewController:imagePickerController
                                                      animated:YES
                                                    completion:nil];
  } else {
    UIAlertController *cameraErrorAlert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"Error", @"Alert title when camera unavailable")
                         message:NSLocalizedString(@"Camera not available.",
                                                   "Alert message when camera unavailable")
                  preferredStyle:UIAlertControllerStyleAlert];
    [cameraErrorAlert
        addAction:[UIAlertAction actionWithTitle:NSLocalizedString(
                                                     @"OK", @"Alert button when camera unavailable")
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action){
                                         }]];
    [[self viewControllerWithWindow:nil] presentViewController:cameraErrorAlert
                                                      animated:YES
                                                    completion:nil];
    [self sendCallResultWithSavedPathList:nil];
  }
}

- (void)checkCameraAuthorizationWithImagePicker:(UIImagePickerController *)imagePickerController
                                         camera:(UIImagePickerControllerCameraDevice)device {
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

  switch (status) {
    case AVAuthorizationStatusAuthorized:
      [self showCamera:device withImagePicker:imagePickerController];
      break;
    case AVAuthorizationStatusNotDetermined: {
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                               completionHandler:^(BOOL granted) {
                                 dispatch_async(dispatch_get_main_queue(), ^{
                                   if (granted) {
                                     [self showCamera:device withImagePicker:imagePickerController];
                                   } else {
                                     [self errorNoCameraAccess:AVAuthorizationStatusDenied];
                                   }
                                 });
                               }];
      break;
    }
    case AVAuthorizationStatusDenied:
    case AVAuthorizationStatusRestricted:
    default:
      [self errorNoCameraAccess:status];
      break;
  }
}

- (void)checkPhotoAuthorizationWithImagePicker:(UIImagePickerController *)imagePickerController {
  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
  switch (status) {
    case PHAuthorizationStatusNotDetermined: {
      [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (status == PHAuthorizationStatusAuthorized) {
            [self showPhotoLibraryWithImagePicker:imagePickerController];
          } else {
            [self errorNoPhotoAccess:status];
          }
        });
      }];
      break;
    }
    case PHAuthorizationStatusAuthorized:
      [self showPhotoLibraryWithImagePicker:imagePickerController];
      break;
    case PHAuthorizationStatusDenied:
    case PHAuthorizationStatusRestricted:
    default:
      [self errorNoPhotoAccess:status];
      break;
  }
}

- (void)checkPhotoAuthorizationWithPHPicker:(PHPickerViewController *)pickerViewController
    API_AVAILABLE(ios(14)) {
  PHAccessLevel requestedAccessLevel = PHAccessLevelReadWrite;
  PHAuthorizationStatus status =
      [PHPhotoLibrary authorizationStatusForAccessLevel:requestedAccessLevel];
  switch (status) {
    case PHAuthorizationStatusNotDetermined: {
      [PHPhotoLibrary
          requestAuthorizationForAccessLevel:requestedAccessLevel
                                     handler:^(PHAuthorizationStatus status) {
                                       dispatch_async(dispatch_get_main_queue(), ^{
                                         if (status == PHAuthorizationStatusAuthorized) {
                                           [self showPhotoLibraryWithPHPicker:pickerViewController];
                                         } else if (status == PHAuthorizationStatusLimited) {
                                           [self showPhotoLibraryWithPHPicker:pickerViewController];
                                         } else {
                                           [self errorNoPhotoAccess:status];
                                         }
                                       });
                                     }];
      break;
    }
    case PHAuthorizationStatusAuthorized:
    case PHAuthorizationStatusLimited:
      [self showPhotoLibraryWithPHPicker:pickerViewController];
      break;
    case PHAuthorizationStatusDenied:
    case PHAuthorizationStatusRestricted:
    default:
      [self errorNoPhotoAccess:status];
      break;
  }
}

- (void)errorNoCameraAccess:(AVAuthorizationStatus)status {
  switch (status) {
    case AVAuthorizationStatusRestricted:
      [self sendCallResultWithError:[FlutterError
                                        errorWithCode:@"camera_access_restricted"
                                              message:@"The user is not allowed to use the camera."
                                              details:nil]];
      break;
    case AVAuthorizationStatusDenied:
    default:
      [self sendCallResultWithError:[FlutterError
                                        errorWithCode:@"camera_access_denied"
                                              message:@"The user did not allow camera access."
                                              details:nil]];
      break;
  }
}

- (void)errorNoPhotoAccess:(PHAuthorizationStatus)status {
  switch (status) {
    case PHAuthorizationStatusRestricted:
      [self sendCallResultWithError:[FlutterError
                                        errorWithCode:@"photo_access_restricted"
                                              message:@"The user is not allowed to use the photo."
                                              details:nil]];
      break;
    case PHAuthorizationStatusDenied:
    default:
      [self sendCallResultWithError:[FlutterError
                                        errorWithCode:@"photo_access_denied"
                                              message:@"The user did not allow photo access."
                                              details:nil]];
      break;
  }
}

- (void)showPhotoLibraryWithPHPicker:(PHPickerViewController *)pickerViewController
    API_AVAILABLE(ios(14)) {
  [[self viewControllerWithWindow:nil] presentViewController:pickerViewController
                                                    animated:YES
                                                  completion:nil];
}

- (void)showPhotoLibraryWithImagePicker:(UIImagePickerController *)imagePickerController {
  imagePickerController.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
  [[self viewControllerWithWindow:nil] presentViewController:imagePickerController
                                                    animated:YES
                                                  completion:nil];
}

- (NSNumber *)getDesiredImageQuality:(NSNumber *)imageQuality {
  if (![imageQuality isKindOfClass:[NSNumber class]]) {
    imageQuality = @1;
  } else if (imageQuality.intValue < 0 || imageQuality.intValue > 100) {
    imageQuality = @1;
  } else {
    imageQuality = @([imageQuality floatValue] / 100);
  }
  return imageQuality;
}

#pragma mark - UIAdaptivePresentationControllerDelegate

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
  [self sendCallResultWithSavedPathList:nil];
}

#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14)) {
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (results.count == 0) {
    [self sendCallResultWithSavedPathList:nil];
    return;
  }
  __block NSOperationQueue *saveQueue = [[NSOperationQueue alloc] init];
  saveQueue.name = @"Flutter Save Image Queue";
  saveQueue.qualityOfService = NSQualityOfServiceUserInitiated;

  FLTImagePickerMethodCallContext *currentCallContext = self.callContext;
  NSNumber *maxWidth = currentCallContext.maxSize.width;
  NSNumber *maxHeight = currentCallContext.maxSize.height;
  NSNumber *imageQuality = currentCallContext.imageQuality;
  NSNumber *desiredImageQuality = [self getDesiredImageQuality:imageQuality];
  BOOL requestFullMetadata = currentCallContext.requestFullMetadata;
  NSMutableArray<FLTAssetPickResult *> *assetList = [[NSMutableArray alloc] initWithCapacity:results.count];
  __block FlutterError *saveError = nil;
  __weak typeof(self) weakSelf = self;
  // This operation will be executed on the main queue after
  // all selected files have been saved.
  NSBlockOperation *sendListOperation = [NSBlockOperation blockOperationWithBlock:^{
    if (saveError != nil) {
      [weakSelf sendCallResultWithError:saveError];
    } else {
      [weakSelf sendCallResultWithSavedAssetList:assetList];
    }
    // Retain queue until here.
    saveQueue = nil;
  }];

  [results enumerateObjectsUsingBlock:^(PHPickerResult *result, NSUInteger index, BOOL *stop) {
    // NSNull means it hasn't saved yet.
    [assetList addObject:(FLTAssetPickResult *)[NSNull null]];
    FLTPHPickerSaveImageToPathOperation *saveOperation =
        [[FLTPHPickerSaveImageToPathOperation alloc]
                 initWithResult:result
                      maxHeight:maxHeight
                       maxWidth:maxWidth
            desiredImageQuality:desiredImageQuality
                   fullMetadata:requestFullMetadata
           savedAssetResultBlock:^(FLTAssetPickResult *assetResult, FlutterError *error) {
                   if (assetResult != nil) {
                     assetList[index] = assetResult;
                   } else {
                     saveError = error;
                   }
                 }];
    [sendListOperation addDependency:saveOperation];
    [saveQueue addOperation:saveOperation];
  }];

  // Schedule the final Flutter callback on the main queue
  // to be run after all images have been saved.
  [NSOperationQueue.mainQueue addOperation:sendListOperation];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<NSString *, id> *)info {
  NSURL *videoURL = info[UIImagePickerControllerMediaURL];
  [picker dismissViewControllerAnimated:YES completion:nil];
  // The method dismissViewControllerAnimated does not immediately prevent
  // further didFinishPickingMediaWithInfo invocations. A nil check is necessary
  // to prevent below code to be unwantly executed multiple times and cause a
  // crash.
  if (!self.callContext) {
    return;
  }
  if (videoURL != nil) {
    if (@available(iOS 13.0, *)) {
      NSURL *destination = [FLTImagePickerPhotoAssetUtil saveVideoFromURL:videoURL];
      if (destination == nil) {
        [self sendCallResultWithError:[FlutterError
                                          errorWithCode:@"flutter_image_picker_copy_video_error"
                                                message:@"Could not cache the video file."
                                                details:nil]];
        return;
      }

      videoURL = destination;
    }

    // Extract PHAsset to get local identifier (same logic as images)
    PHAsset *originalAsset;
    if (_callContext.requestFullMetadata) {
      // Full metadata are available only in PHAsset, which requires gallery permission.
      originalAsset = [FLTImagePickerPhotoAssetUtil getAssetFromImagePickerInfo:info];
    }

    NSString *localIdentifier = originalAsset ? originalAsset.localIdentifier : nil;
    FLTAssetPickResult *assetResult = [FLTAssetPickResult makeWithPath:videoURL.path localIdentifier:localIdentifier];
    [self sendCallResultWithSavedAssetList:@[ assetResult ]];
  } else {
    UIImage *image = info[UIImagePickerControllerEditedImage];
    if (image == nil) {
      image = info[UIImagePickerControllerOriginalImage];
    }
    NSNumber *maxWidth = self.callContext.maxSize.width;
    NSNumber *maxHeight = self.callContext.maxSize.height;
    NSNumber *imageQuality = self.callContext.imageQuality;
    NSNumber *desiredImageQuality = [self getDesiredImageQuality:imageQuality];

    PHAsset *originalAsset;
    if (_callContext.requestFullMetadata) {
      // Full metadata are available only in PHAsset, which requires gallery permission.
      originalAsset = [FLTImagePickerPhotoAssetUtil getAssetFromImagePickerInfo:info];
    }

    if (maxWidth != nil || maxHeight != nil) {
      image = [FLTImagePickerImageUtil scaledImage:image
                                          maxWidth:maxWidth
                                         maxHeight:maxHeight
                               isMetadataAvailable:YES];
    }

    if (!originalAsset) {
      // Image picked without an original asset (e.g. User took a photo directly)
      [self saveImageAsAssetWithPickerInfo:info image:image imageQuality:desiredImageQuality localIdentifier:nil];
    } else {
      NSString *localIdentifier = originalAsset.localIdentifier;
      void (^resultHandler)(NSData *imageData, NSString *dataUTI, NSDictionary *info) = ^(
          NSData *_Nullable imageData, NSString *_Nullable dataUTI, NSDictionary *_Nullable info) {
        // maxWidth and maxHeight are used only for GIF images.
        [self saveImageAsAssetWithOriginalImageData:imageData
                                              image:image
                                           maxWidth:maxWidth
                                          maxHeight:maxHeight
                                       imageQuality:desiredImageQuality
                                    localIdentifier:localIdentifier];
      };
      if (@available(iOS 13.0, *)) {
        [[PHImageManager defaultManager]
            requestImageDataAndOrientationForAsset:originalAsset
                                           options:nil
                                     resultHandler:^(NSData *_Nullable imageData,
                                                     NSString *_Nullable dataUTI,
                                                     CGImagePropertyOrientation orientation,
                                                     NSDictionary *_Nullable info) {
                                       resultHandler(imageData, dataUTI, info);
                                     }];
      } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [[PHImageManager defaultManager]
            requestImageDataForAsset:originalAsset
                             options:nil
                       resultHandler:^(NSData *_Nullable imageData, NSString *_Nullable dataUTI,
                                       UIImageOrientation orientation,
                                       NSDictionary *_Nullable info) {
                         resultHandler(imageData, dataUTI, info);
                       }];
#pragma clang diagnostic pop
      }
    }
  }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self sendCallResultWithSavedPathList:nil];
}

#pragma mark -

- (void)saveImageWithOriginalImageData:(NSData *)originalImageData
                                 image:(UIImage *)image
                              maxWidth:(NSNumber *)maxWidth
                             maxHeight:(NSNumber *)maxHeight
                          imageQuality:(NSNumber *)imageQuality {
  NSString *savedPath =
      [FLTImagePickerPhotoAssetUtil saveImageWithOriginalImageData:originalImageData
                                                             image:image
                                                          maxWidth:maxWidth
                                                         maxHeight:maxHeight
                                                      imageQuality:imageQuality];
  [self sendCallResultWithSavedPathList:@[ savedPath ]];
}

- (void)saveImageWithPickerInfo:(NSDictionary *)info
                          image:(UIImage *)image
                   imageQuality:(NSNumber *)imageQuality {
  NSString *savedPath = [FLTImagePickerPhotoAssetUtil saveImageWithPickerInfo:info
                                                                        image:image
                                                                 imageQuality:imageQuality];
  [self sendCallResultWithSavedPathList:@[ savedPath ]];
}

- (void)saveImageAsAssetWithOriginalImageData:(NSData *)originalImageData
                                        image:(UIImage *)image
                                     maxWidth:(NSNumber *)maxWidth
                                    maxHeight:(NSNumber *)maxHeight
                                 imageQuality:(NSNumber *)imageQuality
                              localIdentifier:(NSString *)localIdentifier {
  FLTAssetPickResult *assetResult = [FLTImagePickerPhotoAssetUtil saveImageAsAssetWithOriginalImageData:originalImageData
                                                                                                   image:image
                                                                                                maxWidth:maxWidth
                                                                                               maxHeight:maxHeight
                                                                                            imageQuality:imageQuality
                                                                                         localIdentifier:localIdentifier];
  [self sendCallResultWithSavedAssetList:@[ assetResult ]];
}

- (void)saveImageAsAssetWithPickerInfo:(NSDictionary *)info
                                 image:(UIImage *)image
                          imageQuality:(NSNumber *)imageQuality
                       localIdentifier:(NSString *)localIdentifier {
  FLTAssetPickResult *assetResult = [FLTImagePickerPhotoAssetUtil saveImageAsAssetWithPickerInfo:info
                                                                                            image:image
                                                                                     imageQuality:imageQuality
                                                                                  localIdentifier:localIdentifier];
  [self sendCallResultWithSavedAssetList:@[ assetResult ]];
}

- (void)sendCallResultWithSavedPathList:(nullable NSArray *)pathList {
  if (!self.callContext) {
    return;
  }

  // Check if we have an asset result callback, and if so, convert paths to asset results
  if (self.callContext.assetResult) {
    if (pathList) {
      NSMutableArray<FLTAssetPickResult *> *assetList = [[NSMutableArray alloc] initWithCapacity:pathList.count];
      for (NSString *path in pathList) {
        if ([path isKindOfClass:[NSString class]]) {
          // No local identifier available when coming from path-based operations
          FLTAssetPickResult *assetResult = [FLTAssetPickResult makeWithPath:path localIdentifier:nil];
          [assetList addObject:assetResult];
        }
      }
      [self sendCallResultWithSavedAssetList:assetList];
    } else {
      [self sendCallResultWithSavedAssetList:nil];
    }
    return;
  }

  // Original path-based logic
  if ([pathList containsObject:[NSNull null]]) {
    self.callContext.result(nil, [FlutterError errorWithCode:@"create_error"
                                                     message:@"pathList's items should not be null"
                                                     details:nil]);
  } else {
    self.callContext.result(pathList ?: [NSArray array], nil);
  }
  self.callContext = nil;
}

- (void)sendCallResultWithSavedAssetList:(nullable NSArray<FLTAssetPickResult *> *)assetList {
  if (!self.callContext) {
    return;
  }

  if ([assetList containsObject:[NSNull null]]) {
    self.callContext.assetResult(nil, [FlutterError errorWithCode:@"create_error"
                                                          message:@"assetList's items should not be null"
                                                          details:nil]);
  } else {
    self.callContext.assetResult(assetList ?: [NSArray array], nil);
  }
  self.callContext = nil;
}

/// Sends the given error via `callContext.result` as the result of the original platform channel
/// method call, clearing the in-progress call state.
///
/// @param error The error to return.
- (void)sendCallResultWithError:(FlutterError *)error {
  if (!self.callContext) {
    return;
  }
  self.callContext.result(nil, error);
  self.callContext = nil;
}

@end
