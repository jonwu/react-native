/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 */

#import "RCTImagePickerManager.h"

#import <MobileCoreServices/UTCoreTypes.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#import <React/RCTConvert.h>
#import <React/RCTImageStoreManager.h>
#import <React/RCTRootView.h>
#import <React/RCTUtils.h>

@interface RCTImagePickerController : UIImagePickerController

@property (nonatomic, assign) BOOL unmirrorFrontFacingCamera;

@end

@implementation RCTImagePickerController

@end

@interface RCTImagePickerManager () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@end

@implementation RCTImagePickerManager
{
  NSMutableArray<UIImagePickerController *> *_pickers;
  NSMutableArray<RCTResponseSenderBlock> *_pickerCallbacks;
  NSMutableArray<RCTResponseSenderBlock> *_pickerCancelCallbacks;
}

RCT_EXPORT_MODULE(ImagePickerIOS);

@synthesize bridge = _bridge;

- (id)init
{
  if (self = [super init]) {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(cameraChanged:)
                                                 name:@"AVCaptureDeviceDidStartRunningNotification"
                                               object:nil];
  }
  return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AVCaptureDeviceDidStartRunningNotification" object:nil];
}

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

RCT_EXPORT_METHOD(canRecordVideos:(RCTResponseSenderBlock)callback)
{
  NSArray<NSString *> *availableMediaTypes = [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];
  callback(@[@([availableMediaTypes containsObject:(NSString *)kUTTypeMovie])]);
}

RCT_EXPORT_METHOD(canUseCamera:(RCTResponseSenderBlock)callback)
{
  callback(@[@([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera])]);
}

RCT_EXPORT_METHOD(openCameraDialog:(NSDictionary *)config
                  successCallback:(RCTResponseSenderBlock)callback
                  cancelCallback:(RCTResponseSenderBlock)cancelCallback)
{
  if (RCTRunningInAppExtension()) {
    cancelCallback(@[@"Camera access is unavailable in an app extension"]);
    return;
  }

  RCTImagePickerController *imagePicker = [RCTImagePickerController new];
  imagePicker.delegate = self;
  imagePicker.sourceType = UIImagePickerControllerSourceTypeCamera;
  imagePicker.unmirrorFrontFacingCamera = [RCTConvert BOOL:config[@"unmirrorFrontFacingCamera"]];

  if ([RCTConvert BOOL:config[@"videoMode"]]) {
    imagePicker.mediaTypes = @[(NSString *)kUTTypeImage, (NSString *)kUTTypeMovie];
  }

  [self _presentPicker:imagePicker
       successCallback:callback
        cancelCallback:cancelCallback];
}

RCT_EXPORT_METHOD(openSelectDialog:(NSDictionary *)config
                  successCallback:(RCTResponseSenderBlock)callback
                  cancelCallback:(RCTResponseSenderBlock)cancelCallback)
{
  if (RCTRunningInAppExtension()) {
    cancelCallback(@[@"Image picker is currently unavailable in an app extension"]);
    return;
  }

  UIImagePickerController *imagePicker = [UIImagePickerController new];
  imagePicker.delegate = self;
  imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;

  NSMutableArray<NSString *> *allowedTypes = [NSMutableArray new];
  if ([RCTConvert BOOL:config[@"showImages"]]) {
    [allowedTypes addObject:(NSString *)kUTTypeImage];
  }
  if ([RCTConvert BOOL:config[@"showVideos"]]) {
    [allowedTypes addObject:(NSString *)kUTTypeMovie];
  }

  imagePicker.mediaTypes = allowedTypes;

  [self _presentPicker:imagePicker
       successCallback:callback
        cancelCallback:cancelCallback];
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<NSString *, id> *)info
{
  NSString *mediaType = info[UIImagePickerControllerMediaType];
  BOOL isMovie = [mediaType isEqualToString:(NSString *)kUTTypeMovie];
  NSString *key = isMovie ? UIImagePickerControllerMediaURL : UIImagePickerControllerReferenceURL;
  NSURL *imageURL = info[key];
  UIImage *image = info[UIImagePickerControllerOriginalImage];
  NSNumber *width = 0;
  NSNumber *height = 0;
  if (image) {
    height = @(image.size.height);
    width = @(image.size.width);
  }
  if (imageURL) {
    [self _dismissPicker:picker args:@[imageURL.absoluteString, RCTNullIfNil(height), RCTNullIfNil(width)]];
    return;
  }

  // This is a newly taken image, and doesn't have a URL yet.
  // We need to save it to the image store first.
  UIImage *originalImage = info[UIImagePickerControllerOriginalImage];

  __block PHObjectPlaceholder *placeholderAsset = nil;
  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHAssetChangeRequest *assetChangeRequest = [PHAssetChangeRequest creationRequestForAssetFromImage:originalImage];
    placeholderAsset = assetChangeRequest.placeholderForCreatedAsset;
  } completionHandler:^(BOOL success, NSError *error) {
    if (success) {
      // probably a bit hacky...
      NSString *id = [placeholderAsset.localIdentifier substringToIndex:36];
      NSString *assetUrlString = [NSString stringWithFormat:@"assets-library://asset/asset.JPG?id=%@&ext=JPG", id];

      [self _dismissPicker:picker args:@[assetUrlString, height, width]];
    }
  }
  // WARNING: Using ImageStoreManager may cause a memory leak because the
  // image isn't automatically removed from store once we're done using it.
  [_bridge.imageStoreManager storeImage:originalImage withBlock:^(NSString *tempImageTag) {
    [self _dismissPicker:picker args:tempImageTag ? @[tempImageTag, RCTNullIfNil(height), RCTNullIfNil(width)] : nil];
  }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
  [self _dismissPicker:picker args:nil];
}

- (void)_presentPicker:(UIImagePickerController *)imagePicker
       successCallback:(RCTResponseSenderBlock)callback
        cancelCallback:(RCTResponseSenderBlock)cancelCallback
{
  if (!_pickers) {
    _pickers = [NSMutableArray new];
    _pickerCallbacks = [NSMutableArray new];
    _pickerCancelCallbacks = [NSMutableArray new];
  }

  [_pickers addObject:imagePicker];
  [_pickerCallbacks addObject:callback];
  [_pickerCancelCallbacks addObject:cancelCallback];

  UIViewController *rootViewController = RCTPresentedViewController();
  [rootViewController presentViewController:imagePicker animated:YES completion:nil];
}

- (void)_dismissPicker:(UIImagePickerController *)picker args:(NSArray *)args
{
  NSUInteger index = [_pickers indexOfObject:picker];
  if (index == NSNotFound) {
    // This happens if the user selects multiple items in succession.
    return;
  }

  RCTResponseSenderBlock successCallback = _pickerCallbacks[index];
  RCTResponseSenderBlock cancelCallback = _pickerCancelCallbacks[index];

  [_pickers removeObjectAtIndex:index];
  [_pickerCallbacks removeObjectAtIndex:index];
  [_pickerCancelCallbacks removeObjectAtIndex:index];

  UIViewController *rootViewController = RCTPresentedViewController();
  dispatch_async(dispatch_get_main_queue(), ^{
      [rootViewController dismissViewControllerAnimated:YES completion:nil];
  });

  if (args) {
    successCallback(args);
  } else {
    cancelCallback(@[]);
  }
}

- (void)cameraChanged:(NSNotification *)notification
{
  for (UIImagePickerController *picker in _pickers) {
    if ([picker isKindOfClass:[RCTImagePickerController class]]
      && ((RCTImagePickerController *)picker).unmirrorFrontFacingCamera
      && picker.cameraDevice == UIImagePickerControllerCameraDeviceFront) {
      picker.cameraViewTransform = CGAffineTransformScale(CGAffineTransformIdentity, -1, 1);
    } else {
      picker.cameraViewTransform = CGAffineTransformIdentity;
    }
  }
}

@end
