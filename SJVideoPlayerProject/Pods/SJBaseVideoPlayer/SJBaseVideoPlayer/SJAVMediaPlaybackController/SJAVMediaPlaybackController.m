//
//  SJAVMediaPlaybackController.m
//  Project
//
//  Created by BlueDancer on 2018/8/10.
//  Copyright © 2018年 SanJiang. All rights reserved.
//

#import "SJAVMediaPlaybackController.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#if __has_include(<SJUIKit/NSObject+SJObserverHelper.h>)
#import <SJUIKit/NSObject+SJObserverHelper.h>
#else
#import "NSObject+SJObserverHelper.h"
#endif

#import "SJAVMediaPlayAsset+SJAVMediaPlaybackControllerAdd.h"
#import "SJVideoPlayerRegistrar.h"
#import "SJAVMediaPlayAsset.h"
#import "NSTimer+SJAssetAdd.h"
#import "SJAVMediaPlayAssetLoader.h"
#import "SJAVMediaMainPresenter.h"

NS_ASSUME_NONNULL_BEGIN
inline static bool isFloatZero(float value) {
    return fabsf(value) <= 0.00001f;
}

@interface SJAVMediaPlaybackController()<SJAVMediaPlayAssetPropertiesObserverDelegate>
@property (nonatomic, strong, readonly) SJVideoPlayerRegistrar *registrar;
@property (nonatomic, strong, nullable) SJAVMediaPlayAssetPropertiesObserver *playAssetObserver;
@property (nonatomic, strong, nullable) SJAVMediaPlayAsset *playAsset;
@property (nonatomic) BOOL isPlaying;

@property (nonatomic, strong, readonly) SJAVMediaMainPresenter *mainPresenter;
@property (nonatomic, strong, nullable) SJAVMediaAssetLoader *definitionLoader;
@end

@implementation SJAVMediaPlaybackController
@synthesize delegate = _delegate;
@synthesize media = _media;
@synthesize playerView = _playerView;
@synthesize error = _error;
@synthesize videoGravity = _videoGravity;
@synthesize currentTime = _currentTime;
@synthesize duration = _duration;
@synthesize bufferLoadedTime = _bufferLoadedTime;
@synthesize bufferStatus = _bufferStatus;
@synthesize rate = _rate;
@synthesize mute = _mute;
@synthesize presentationSize = _presentationSize;
@synthesize prepareStatus = _prepareStatus;
@synthesize pauseWhenAppDidEnterBackground = _pauseWhenAppDidEnterBackground;
@synthesize registrar = _registrar;
@synthesize volume = _volume;

- (void)dealloc {
#ifdef DEBUG
    NSLog(@"%d - %s", (int)__LINE__, __func__);
#endif
    if ( !_media.otherMedia ) [_playAsset.player pause];
    [_playerView removeFromSuperview];
    [self _cancelOperations];
}

- (void)_cancelOperations {
    [self cancelPendingSeeks];
    [self cancelExportOperation];
    [self cancelGenerateGIFOperation];
}

- (instancetype)init {
    self = [super init];
    if ( !self ) return nil;
    [self _initializeDefaultValues];
    [self _initializeMainPresenter];
    [self _initializeRegistrar];
    return self;
}

- (void)_initializeDefaultValues {
    _rate = 1;
    _volume = 1;
}

- (void)_initializeMainPresenter {
    _mainPresenter = [SJAVMediaMainPresenter mainPresenter];
    
    __weak typeof(self) _self = self;
    sjkvo_observe(_mainPresenter, @"readyForDisplay", ^(id  _Nonnull target, NSDictionary<NSKeyValueChangeKey,id> * _Nullable change) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( self.mainPresenter.isReadyForDisplay &&
            [self.delegate respondsToSelector:@selector(playbackControllerIsReadyForDisplay:)] ) {
            [self.delegate playbackControllerIsReadyForDisplay:self];
        #ifdef DEBUG
            printf("\nSJAVMediaPlaybackController<%p>.isReadyForDisplay\n", self);
        #endif
        }
    });
}

- (void)_initializeRegistrar {
    __weak typeof(self) _self = self;
    _registrar = [SJVideoPlayerRegistrar new];
    _registrar.willEnterForeground = ^(SJVideoPlayerRegistrar * _Nonnull registrar) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        [self _setupMainPresenterIfNeeded];
    };
    
    _registrar.didEnterBackground = ^(SJVideoPlayerRegistrar * _Nonnull registrar) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        [self _applicationDidEnterBackground];
    };
}

- (void)_setupMainPresenterIfNeeded {
    if ( _registrar.state == SJVideoPlayerAppState_Background ) return;
    if ( _prepareStatus != SJMediaPlaybackPrepareStatusReadyToPlay ) return;
    if ( _mainPresenter.player == _playAsset.player ) return;
    [_mainPresenter takeOverSubPresenter:[[SJAVMediaSubPresenter alloc] initWithAVPlayer:_playAsset.player]];
}

- (void)_applicationDidEnterBackground {
    if ( _mainPresenter.player ) {
        if ( [self pauseWhenAppDidEnterBackground] && self.isPlaying ) {
            [self pause];
        }
        else {
            [_mainPresenter removeAllPresenters];
        }
    }
}

- (UIView *)playerView {
    return _mainPresenter;
}

- (BOOL)isReadyForDisplay {
    return _mainPresenter.isReadyForDisplay;
}

- (void)setMedia:(nullable id<SJMediaModelProtocol>)media {
    [_playAsset.player pause];
    [_mainPresenter removeAllPresenters];
    [self _cancelOperations];
    _playAssetObserver = nil;
    _playAsset = nil;
    _error = nil;
    _currentTime = 0;
    _duration = 0;
    _bufferLoadedTime = 0;
    _bufferStatus = 0;
    _presentationSize = CGSizeZero;
    _prepareStatus = 0;
    _isPlaying = NO;
    _definitionLoader = nil;
    _media = media;
}

- (void)_resetMediaForSwitchDefinitionSuccess:(id<SJMediaModelProtocol>)new_meida {
    [_playAsset.player pause];
    sj_removeAssetForMedia(_media);
    _media = new_meida;
    _playAsset = sj_assetForMedia(new_meida);
    _playAssetObserver = [[SJAVMediaPlayAssetPropertiesObserver alloc] initWithPlayerAsset:_playAsset];
    _playAssetObserver.delegate = self;
    
    [self _updateDurationIfNeeded];
    [self _updateCurrentTimeIfNeeded];
    [self _updatePresentationSizeIfNeeded];
    [self _updatePrepareStatusIfNeeded];
    [self _updateBufferStatusIfNeeded];
    [self _updateBufferLoadedTimeIfNeeded];
}

- (void)setVolume:(float)volume {
    _volume = volume;
    if ( !_mute ) _playAsset.player.volume = volume;
}
- (float)volume {
    return _volume;
}

- (void)setMute:(BOOL)mute {
    if ( mute == _mute ) return;
    _mute = mute;
    _playAsset.player.muted = mute;
}

- (void)setRate:(float)rate {
    _rate = rate;
    _playAsset.player.rate = rate;
}

- (void)setVideoGravity:(SJVideoGravity)videoGravity {
    _mainPresenter.videoGravity = videoGravity;
}
- (SJVideoGravity)videoGravity {
    return _mainPresenter.videoGravity;
}

- (void)prepareToPlay {
    if ( !_media ) return;

    _playAsset = sj_assetForMedia(_media);
    _playAssetObserver = [[SJAVMediaPlayAssetPropertiesObserver alloc] initWithPlayerAsset:_playAsset];
    _playAssetObserver.delegate = self;
    
    if ( _playAsset.playerItem.status == AVPlayerStatusReadyToPlay ) {
        [self _updateDurationIfNeeded];
        [self _updateCurrentTimeIfNeeded];
        [self _updatePresentationSizeIfNeeded];
        [self _updatePrepareStatusIfNeeded];
        [self _updateBufferStatusIfNeeded];
        [self _updateBufferLoadedTimeIfNeeded];
    }
}

- (void)switchVideoDefinition:(id<SJMediaModelProtocol>)media {
    [self _switchingDefinitionStatusDidChange:media status:SJMediaPlaybackSwitchDefinitionStatusSwitching];

    SJAVMediaPlayAsset *asset = sj_assetForMedia(media);
    __weak typeof(self) _self = self;
    _definitionLoader = [[SJAVMediaAssetLoader alloc] initWithAsset:asset loadStatusDidChange:^(AVPlayerItemStatus status) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        [self _switchingDefinitionAssetLoadStatusDidChange:asset media:media status:status];
    }];
}

- (void)_switchingDefinitionAssetLoadStatusDidChange:(SJAVMediaPlayAsset *)asset media:(id<SJMediaModelProtocol>)media status:(AVPlayerItemStatus)status {
    switch (status) {
        case AVPlayerItemStatusFailed: {
            [self _switchingDefinitionStatusDidChange:media status:SJMediaPlaybackSwitchDefinitionStatusFailed];
        }
            break;
        case AVPlayerItemStatusUnknown: break;
        case AVPlayerItemStatusReadyToPlay: {
            // present
            SJAVMediaSubPresenter *presenter = [[SJAVMediaSubPresenter alloc] initWithAVPlayer:asset.player];
            [self.mainPresenter insertSubPresenterToBack:presenter];
            __weak typeof(self) _self = self;
            SJKVOObserverToken __block token = sjkvo_observe(presenter, @"readyForDisplay", ^(SJAVMediaSubPresenter *subPresenter, NSDictionary<NSKeyValueChangeKey,id> * _Nullable change) {
                __strong typeof(_self) self = _self;
                if ( !self ) return;
                // ready for display
                if ( [subPresenter isReadyForDisplay] ) {
                    // seek to current time
                    [asset.playerItem seekToTime:self.playAsset?self.playAsset.playerItem.currentTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
                        if ( !finished ) {
                            [self.mainPresenter removeSubPresenter:subPresenter];
                            [self _switchingDefinitionStatusDidChange:media status:SJMediaPlaybackSwitchDefinitionStatusFailed];
                            return;
                        }
                        // remove `isReadyForDisplay` observer
                        sjkvo_remove(subPresenter, token);
                        [self.mainPresenter takeOverSubPresenter:subPresenter];
                        [self _resetMediaForSwitchDefinitionSuccess:media];
                        if ( self.isPlaying ) [self play];
                        [self _switchingDefinitionStatusDidChange:media status:SJMediaPlaybackSwitchDefinitionStatusFinished];
                    }];
                }
            });
        }
            break;
    }
}

- (void)_switchingDefinitionStatusDidChange:(id<SJMediaModelProtocol>)media status:(SJMediaPlaybackSwitchDefinitionStatus)status {
    if ( [self.delegate respondsToSelector:@selector(playbackController:switchingDefinitionStatusDidChange:media:)] ) {
        [self.delegate playbackController:self switchingDefinitionStatusDidChange:status media:media];
    }
    
    if ( status == SJMediaPlaybackSwitchDefinitionStatusFinished ||
         status == SJMediaPlaybackSwitchDefinitionStatusFailed ) {
        _definitionLoader = nil;
    }
    
#ifdef DEBUG
    char *str = nil;
    switch ( status ) {
        case SJMediaPlaybackSwitchDefinitionStatusUnknown: break;
        case SJMediaPlaybackSwitchDefinitionStatusSwitching:
            str = "Switching";
            break;
        case SJMediaPlaybackSwitchDefinitionStatusFinished:
            str = "Finished";
            break;
        case SJMediaPlaybackSwitchDefinitionStatusFailed:
            str = "Failed";
            break;
    }
    printf("\nSJAVMediaPlaybackController<%p>.switchStatus = %s\n", self, str);
#endif
}

#pragma mark -
- (void)observer:(SJAVMediaPlayAssetPropertiesObserver *)observer durationDidChange:(NSTimeInterval)duration {
    [self _updateDurationIfNeeded];
}

- (void)observer:(SJAVMediaPlayAssetPropertiesObserver *)observer currentTimeDidChange:(NSTimeInterval)currentTime {
    [self _updateCurrentTimeIfNeeded];
}
- (void)observer:(SJAVMediaPlayAssetPropertiesObserver *)observer bufferLoadedTimeDidChange:(NSTimeInterval)bufferLoadedTime {
    [self _updateBufferLoadedTimeIfNeeded];
    [self _updatePrepareStatusIfNeeded];
}
- (void)observer:(SJAVMediaPlayAssetPropertiesObserver *)observer bufferStatusDidChange:(SJPlayerBufferStatus)bufferStatus {
    [self _updateBufferStatusIfNeeded];
}
- (void)observer:(SJAVMediaPlayAssetPropertiesObserver *)observer bufferWatingTimeDidChange:(NSTimeInterval)bufferWatingTime {
    if ( [self.delegate respondsToSelector:@selector(playbackController:bufferWatingTimeDidChange:)] ) {
        [self.delegate playbackController:self bufferWatingTimeDidChange:bufferWatingTime];
    }
}
- (void)observer:(SJAVMediaPlayAssetPropertiesObserver *)observer presentationSizeDidChange:(CGSize)presentationSize {
    [self _updatePresentationSizeIfNeeded];
}
- (void)observer:(SJAVMediaPlayAssetPropertiesObserver *)observer playerItemStatusDidChange:(AVPlayerItemStatus)playerItemStatus {
    [self _updatePrepareStatusIfNeeded];
}
- (void)playDidToEndForObserver:(SJAVMediaPlayAssetPropertiesObserver *)observer {
    _isPlaying = NO;
    if ( [self.delegate respondsToSelector:@selector(mediaDidPlayToEndForPlaybackController:)] ) {
        [self.delegate mediaDidPlayToEndForPlaybackController:self];
    }
}
- (void)observer:(SJAVMediaPlayAssetPropertiesObserver *)observer playbackTypeLoaded:(SJMediaPlaybackType)playbackType {
    if ( [self.delegate respondsToSelector:@selector(playbackController:playbackTypeLoaded:)] ) {
        [self.delegate playbackController:self playbackTypeLoaded:playbackType];
    }
}
- (void)_updateDurationIfNeeded {
    NSTimeInterval duration = _playAssetObserver.duration;
    if ( duration != _duration ) {
        _duration = duration;
        if ( [self.delegate respondsToSelector:@selector(playbackController:durationDidChange:)] ) {
            [self.delegate playbackController:self durationDidChange:duration];
        }
    }
}

- (void)_updateCurrentTimeIfNeeded {
    NSTimeInterval currentTime = _playAssetObserver.currentTime;
    if ( currentTime != _currentTime ) {
        _currentTime = currentTime;
        if ( [self.delegate respondsToSelector:@selector(playbackController:currentTimeDidChange:)] ) {
            [self.delegate playbackController:self currentTimeDidChange:currentTime];
        }
    }
}

- (void)_updateBufferLoadedTimeIfNeeded {
    NSTimeInterval bufferLoadedTime = _playAssetObserver.bufferLoadedTime;
    if ( bufferLoadedTime != _bufferLoadedTime ) {
        _bufferLoadedTime = bufferLoadedTime;
        if ( [self.delegate respondsToSelector:@selector(playbackController:bufferLoadedTimeDidChange:)] ) {
            [self.delegate playbackController:self bufferLoadedTimeDidChange:bufferLoadedTime];
        }
    }
}

- (void)_updateBufferStatusIfNeeded {
    SJPlayerBufferStatus bufferStatus = _playAssetObserver.bufferStatus;
    _bufferStatus = bufferStatus;
    if ( [self.delegate respondsToSelector:@selector(playbackController:bufferStatusDidChange:)] ) {
        [self.delegate playbackController:self bufferStatusDidChange:bufferStatus];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 缓存就绪&播放中, rate如果==0, 尝试播放
        if ( bufferStatus == SJPlayerBufferStatusPlayable &&
             self->_isPlaying &&
             isFloatZero(self->_playAsset.player.rate) ) {
            [self.playAsset.player play];
        }
    });
}

- (void)_updatePresentationSizeIfNeeded {
    CGSize presentationSize = _playAssetObserver.presentationSize;
    if ( !CGSizeEqualToSize(presentationSize, _presentationSize) ) {
        _presentationSize = presentationSize;
        if ( [self.delegate respondsToSelector:@selector(playbackController:presentationSizeDidChange:)] ) {
            [self.delegate playbackController:self presentationSizeDidChange:presentationSize];
        }
    }
}

- (void)_updatePrepareStatusIfNeeded {
    AVPlayerItemStatus playerItemStatus = _playAssetObserver.playerItemStatus;
    if ( _prepareStatus == (NSInteger)playerItemStatus )
        return;
    
    _prepareStatus = (SJMediaPlaybackPrepareStatus)playerItemStatus;
    _error = _playAsset.playerItem.error;
    
    BOOL isResponse = [self.delegate respondsToSelector:@selector(playbackController:prepareToPlayStatusDidChange:)];
    if ( _prepareStatus != SJMediaPlaybackPrepareStatusReadyToPlay ) {
        if ( isResponse )
            [self.delegate playbackController:self prepareToPlayStatusDidChange:(NSInteger)playerItemStatus];
        return;
    }
    
    // ready to play
    __weak SJAVMediaPlayAsset *_Nullable asset = self.playAsset;
    [self _setupMainPresenterIfNeeded];
    __weak typeof(self) _self = self;
    if ( !_media.otherMedia ) {
        [asset.playerItem seekToTime:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC) completionHandler:^(BOOL finished) {
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            if ( self.playAsset != asset ) return;
            [asset.playerItem seekToTime:CMTimeMakeWithSeconds(self.media.specifyStartTime, NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
                __strong typeof(_self) self = _self;
                if ( !self ) return;
                if ( self.playAsset != asset ) return;
                if ( isResponse )
                    [self.delegate playbackController:self prepareToPlayStatusDidChange:(NSInteger)playerItemStatus];
            }];
        }];
        
        return;
    }
    
    // play end ?
    NSTimeInterval current = floor(CMTimeGetSeconds(asset.playerItem.currentTime) + 0.5);
    NSTimeInterval duration = floor(CMTimeGetSeconds(asset.playerItem.duration) + 0.5);
    if ( current == duration ) {
        [asset.playerItem seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            if ( self.playAsset != asset ) return;
            if ( isResponse )
                [self.delegate playbackController:self prepareToPlayStatusDidChange:(NSInteger)playerItemStatus];
        }];
        return;
    }
    
    if ( isResponse )
        [self.delegate playbackController:self prepareToPlayStatusDidChange:(NSInteger)playerItemStatus];
}

#pragma mark -
- (void)play {
    if ( _prepareStatus != SJMediaPlaybackPrepareStatusReadyToPlay ) return;
    
    _isPlaying = YES;
    [_playAsset.player play];
    _playAsset.player.rate = self.rate;
    _playAsset.player.muted = self.mute;
    if ( !_mute ) _playAsset.player.volume = _volume;
    
#ifdef DEBUG
    printf("\n");
    printf("SJAVMediaPlaybackController<%p>.rate == %lf\n", self, self.rate);
    printf("SJAVMediaPlaybackController<%p>.mute == %s\n",  self, self.mute?"YES":"NO");
    printf("SJAVMediaPlaybackController<%p>.playerVolume == %lf\n",  self, _volume);
#endif
}
- (void)pause {
    if ( _prepareStatus != SJMediaPlaybackPrepareStatusReadyToPlay ) return;
    _isPlaying = NO;
    [self.playAsset.player pause];
}
- (void)stop {
    [_playAsset.player pause];
    
    if ( !_media.otherMedia ) {
        [_mainPresenter removeAllPresenters];
    }

    [self _cancelOperations];
    _playAssetObserver = nil;
    _playAsset = nil;
    _prepareStatus = SJMediaPlaybackPrepareStatusUnknown;
    _bufferStatus = SJPlayerBufferStatusUnknown;
    _isPlaying = NO;
}
- (void)seekToTime:(NSTimeInterval)secs completionHandler:(void (^ __nullable)(BOOL finished))completionHandler {
    if ( isnan(secs) ) { return; }

    if ( _prepareStatus != SJMediaPlaybackPrepareStatusReadyToPlay || _error ) {
        if ( completionHandler ) completionHandler(NO);
        return;
    }

    if ( secs > _duration || secs < 0 ) {
        if ( completionHandler ) completionHandler(NO);
        return;
    }

    [_playAsset.playerItem seekToTime:CMTimeMakeWithSeconds(secs, NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        if ( completionHandler ) completionHandler(finished);
    }];
}

- (void)cancelPendingSeeks {
    [_playAsset.playerItem cancelPendingSeeks];
}

#pragma mark -
- (void)generatedPreviewImagesWithMaxItemSize:(CGSize)itemSize completion:(nonnull void (^)(__kindof id<SJMediaPlaybackController> _Nonnull, NSArray<id<SJVideoPlayerPreviewInfo>> * _Nullable, NSError * _Nullable))block {
    __weak typeof(self) _self = self;
    [self.playAsset generatedPreviewImagesWithMaxItemSize:itemSize completion:^(SJAVMediaPlayAsset * _Nonnull a, NSArray<id<SJVideoPlayerPreviewInfo>> * _Nullable images, NSError * _Nullable error) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( block ) block(self, images, error);
    }];
}
- (nullable UIImage *)screenshot {
    return [_playAsset screenshot];
}
- (void)screenshotWithTime:(NSTimeInterval)time size:(CGSize)size completion:(nonnull void (^)(id<SJMediaPlaybackController> _Nonnull, UIImage * _Nullable, NSError * _Nullable))block {
    __weak typeof(self) _self = self;
    [self.playAsset screenshotWithTime:time size:size completion:^(SJAVMediaPlayAsset * _Nonnull a, UIImage * _Nullable image, NSError * _Nullable error) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( block ) block(self, image, error);
    }];
}

- (void)cancelExportOperation {
    [self.playAsset cancelExportOperation];
}

- (void)cancelGenerateGIFOperation {
    [self.playAsset cancelGenerateGIFOperation];
}

- (void)exportWithBeginTime:(NSTimeInterval)beginTime endTime:(NSTimeInterval)endTime presetName:(nullable NSString *)presetName progress:(nonnull void (^)(id<SJMediaPlaybackController> _Nonnull, float))progressBlock completion:(nonnull void (^)(id<SJMediaPlaybackController> _Nonnull, NSURL * _Nullable, UIImage * _Nullable))completionBlock failure:(nonnull void (^)(id<SJMediaPlaybackController> _Nonnull, NSError * _Nullable))failureBlock {
    __weak typeof(self) _self = self;
    [self.playAsset exportWithBeginTime:beginTime endTime:endTime presetName:presetName progress:^(SJAVMediaPlayAsset * _Nonnull a, float progress) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( progressBlock ) progressBlock(self, progress);
    } completion:^(SJAVMediaPlayAsset * _Nonnull a, AVAsset * _Nullable sandboxAsset, NSURL * _Nullable fileURL, UIImage * _Nullable thumbImage) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( completionBlock ) completionBlock(self, fileURL, thumbImage);
    } failure:^(SJAVMediaPlayAsset * _Nonnull a, NSError * _Nullable error) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( failureBlock ) failureBlock(self, error);
    }];
}

- (void)generateGIFWithBeginTime:(NSTimeInterval)beginTime duration:(NSTimeInterval)duration maximumSize:(CGSize)maximumSize interval:(float)interval gifSavePath:(nonnull NSURL *)gifSavePath progress:(nonnull void (^)(id<SJMediaPlaybackController> _Nonnull, float))progressBlock completion:(nonnull void (^)(id<SJMediaPlaybackController> _Nonnull, UIImage * _Nonnull, UIImage * _Nonnull))completion failure:(nonnull void (^)(id<SJMediaPlaybackController> _Nonnull, NSError * _Nonnull))failure {
    __weak typeof(self) _self = self;
    [self.playAsset generateGIFWithBeginTime:beginTime duration:duration maximumSize:maximumSize interval:interval gifSavePath:gifSavePath progress:^(SJAVMediaPlayAsset * _Nonnull a, float progress) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( progressBlock ) progressBlock(self, progress);
    } completion:^(SJAVMediaPlayAsset * _Nonnull a, UIImage * _Nonnull imageGIF, UIImage * _Nonnull thumbnailImage) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( completion ) completion(self, imageGIF, thumbnailImage);
    } failure:^(SJAVMediaPlayAsset * _Nonnull a, NSError * _Nonnull error) {
        __strong typeof(_self) self = _self;
        if ( !self ) return ;
        if ( failure ) failure(self, error);
    }];
}

- (NSTimeInterval)bufferWatingTime {
    return _playAsset.bufferWatingTime;
}

- (void)updateBufferStatus {
    [_playAsset updateBufferStatus];
}

- (SJMediaPlaybackType)playbackType {
    return _playAsset.playbackType;
}
@end
NS_ASSUME_NONNULL_END
