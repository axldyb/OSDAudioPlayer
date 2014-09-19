/**
 * OSDAudioPlayer
 *
 * @author
 *    @name    - Skylar Schipper
 *    @email   - ss@schipp.co
 *    @twitter - skylarsch
 *
 * The MIT License (MIT)
 *
 * Copyright (c) 2014 OpenSky, LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */


#import "OSDAudioPlayer.h"

static void _OSDAudioDebugLog(NSString *fmt, ...) {
#if DEBUG && OSD_AUDIO_PLAYER_DEBUG_LOG
    va_list arguments;
    va_start(arguments, fmt);
    NSString *string = [[NSString alloc] initWithFormat:fmt arguments:arguments];
    va_end(arguments);
    printf("OSDAudioPlayer: %s\n",[string UTF8String]);
#endif
}
#define OSDDebugLog(fmt, ...) _OSDAudioDebugLog(fmt, ##__VA_ARGS__)



static OSDAudioPlayer *_sharedOSDAudioPlayer = nil;

static NSString *const kOSDTracks      = @"tracks";
static NSString *const kOSDStatus      = @"status";
static NSString *const kOSDRate        = @"rate";
static NSString *const kOSDDuration    = @"duration";
static NSString *const kOSDPlayable    = @"playable";
static NSString *const kOSDCurrentItem = @"currentItem";

static void *OSDAudioPlayerRateChangeObservationContext = &OSDAudioPlayerRateChangeObservationContext;
static void *OSDAudioPlayerPlayerItemStatusObserverContext = &OSDAudioPlayerPlayerItemStatusObserverContext;

@interface OSDAudioPlayer ()

@property (nonatomic, strong, readwrite) OSDAudioPlayerItem *currentlyPlayingItem;

@property (nonatomic, strong) NSMutableArray *itemQueue;

@property (nonatomic, assign) BOOL pausedFromInteruption;
@property (nonatomic, assign) BOOL pausedFromRouteChange;
@property (nonatomic, assign) BOOL routeChangeDuringPause;

@property (nonatomic, strong) NSTimer *updateNotifyTimer;
@property (nonatomic, strong) NSTimer *updateNowPlayingInfo;

@property (nonatomic, assign) BOOL calledBeginSeeking;
@property (nonatomic, assign, getter = isSeekPerforming) BOOL seekPerforming;
@property (nonatomic) float_t seekRestoreRate;
@property (nonatomic) OSDAudioPlayerState seekRestoreState;

@end

@implementation OSDAudioPlayer

#pragma mark -
#pragma mark - Metadata
- (NSTimeInterval)currentItemProgress {
    if (isfinite([self currentItemDuration])) {
        return (NSTimeInterval)CMTimeGetSeconds([self.player currentTime]);
    }
    return 0.0;
}
- (NSTimeInterval)loadedProgress {
    NSArray *loadedTimeRanges = [self.player.currentItem loadedTimeRanges];
    if (loadedTimeRanges && loadedTimeRanges.count > 0) {
        CMTimeRange timeRange = [[loadedTimeRanges firstObject] CMTimeRangeValue];
        Float64 startTime = CMTimeGetSeconds(timeRange.start);
        Float64 duration = CMTimeGetSeconds(timeRange.duration);
        return (NSTimeInterval)(startTime + duration);
    }
    return 0.0;
}
- (NSTimeInterval)currentItemDuration {
    if (!self.player.currentItem) {
        return 0.0;
    }
    
    if (self.player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
        CMTime playerDur = [self.player.currentItem duration];
        if (CMTIME_IS_INVALID(playerDur) || CMTIME_IS_INDEFINITE(playerDur)) {
            return 0.0;
        }
        NSTimeInterval duration = (NSTimeInterval)CMTimeGetSeconds(playerDur);
        if (!isnan(duration)) {
            return duration;
        }
    }
    
    return 0.0;
}

- (float_t)progress {
    NSTimeInterval dur = [self currentItemDuration];
    if (dur == 0.0) {
        return 0.0;
    }
    return [self currentItemProgress] / dur;
}

#pragma mark -
#pragma mark - Player Queue
- (void)queueItem:(OSDAudioPlayerItem *)item {
    [self insertItemIntoQueue:item atIndex:self.itemQueue.count];
}
- (void)insertItemIntoQueue:(OSDAudioPlayerItem *)item atIndex:(NSInteger)index {
    [self.itemQueue insertObject:[item copy] atIndex:index];
    [self updatedQueue];
}

- (void)dequeueItem:(OSDAudioPlayerItem *)item {
    NSUInteger index = [self.itemQueue indexOfObject:item];
    if (index == NSNotFound) {
        return;
    }
    [self dequeueItemAtIndex:index];
}
- (void)dequeueItemAtIndex:(NSInteger)index {
    [self.itemQueue removeObjectAtIndex:index];
    [self updatedQueue];
}
- (void)clearQueue {
    [self.itemQueue removeAllObjects];
    [self updatedQueue];
}

- (NSArray *)queuedItems {
    return [self.itemQueue copy];
}

#pragma mark -
#pragma mark - Playback
- (BOOL)playNextItem {
    OSDAudioPlayerItem *nextItem = [self.itemQueue firstObject];
    if (nextItem) {
        [self.itemQueue removeObjectAtIndex:0];
        [self updatedQueue];
        [self playItem:nextItem];
        return YES;
    }
    return NO;
}
- (BOOL)playCurrentItem {
    if (self.currentlyPlayingItem) {
        [self playItem:self.currentlyPlayingItem];
        return YES;
    }
    return [self playNextItem];
}
- (void)playItem:(OSDAudioPlayerItem *)item {
    self.currentlyPlayingItem = item;
    [self updateWillPlayItem];
    [self playAudioFromURL:self.currentlyPlayingItem.itemURL];
}

- (void)play {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pausedFromRouteChange = NO;
        [self setupUpdateNotifyTimerIfNeeded];
        [self.player play];
        [self setCurrentState:OSDAudioPlayerStatePlaying notify:YES];
        [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerDidPlayNotification object:self];
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
        [self updateNowPlayingInfo];
    });
}
- (void)pause {
    _updateNotifyTimer = nil;
    [self.player pause];
    [self setCurrentState:OSDAudioPlayerStatePaused notify:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerDidPauseNotification object:self];
    [self invalidateUpdateNotifyTimer];
}

- (void)playOrPause
{
    if (self.player.rate > 0.0) {
        [self pause];
    } else {
        if (self.player) {
            [self play];
        } else {
            if (self.currentlyPlayingItem) {
                [self playItem:self.currentlyPlayingItem];
            }
        }
    }
    [self updateNowPlayingInfo];
}
- (void)stop {
    self.pausedFromRouteChange = NO;
    self.pausedFromInteruption = NO;
    [self.player pause];
    [self destroyPlayer];
    [self setCurrentState:OSDAudioPlayerStateStopped notify:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
        [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
    });
}

- (void)playAudioFromURL:(NSURL *)url {
    if (!url) {
        NSError *error = [[NSError alloc] initWithDomain:OSDAudioPlayerErrorDomain
                                                    code:OSDAudioPlayerErrorNoURLForItem
                                                userInfo:@{
                                                           NSLocalizedDescriptionKey: NSLocalizedString(@"The item could not be played.  The location for the audio is invalid", nil),
                                                           NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"The passed url for the current item is nil", nil),
                                                           }];
        [self throwError:error];
        return;
    }
    
    [self setCurrentState:OSDAudioPlayerStateLoading notify:YES];
    [self setupBackgroundTaskIfNeeded];
    
    AVURLAsset __block *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray *tracksKeys = @[
                            kOSDTracks,
                            kOSDDuration,
                            kOSDPlayable
                            ];
    
    [asset loadValuesAsynchronouslyForKeys:tracksKeys completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self assetDidLoadValues:asset];
        });
    }];
}
- (void)assetDidLoadValues:(AVURLAsset *)asset {
    OSDDebugLog(@"Asset did load");
    NSError *trackError = nil;
    AVKeyValueStatus status = [asset statusOfValueForKey:kOSDTracks error:&trackError];
    if (status == AVKeyValueStatusLoaded) {
        if ([AVAsset instancesRespondToSelector:@selector(isPlayable)] && ![asset isPlayable]) {
            OSDDebugLog(@"Can't play item");
            NSError *error = [[NSError alloc] initWithDomain:OSDAudioPlayerErrorDomain
                                                        code:OSDAudioPlayerErrorAssetNotPlayable
                                                    userInfo:trackError.userInfo];
            [self throwError:error];
            return;
        }
        
        AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
        [playerItem addObserver:self forKeyPath:kOSDStatus options:0 context:OSDAudioPlayerPlayerItemStatusObserverContext];
        
        if (_player) {
            [self destroyPlayer];
        }
        
        OSDDebugLog(@"Creating AVPlayer");
        _player = [AVPlayer playerWithPlayerItem:playerItem];
        [_player addObserver:self forKeyPath:kOSDRate options:0 context:OSDAudioPlayerRateChangeObservationContext];
        [self updateInfoDictionary];
        [self changeVolume];
    } else if (status == AVKeyValueStatusFailed) {
        OSDDebugLog(@"The asset's trains failed to load %@",trackError);
        
        NSError *error = [[NSError alloc] initWithDomain:OSDAudioPlayerErrorDomain code:OSDAudioPlayerErrorAssetTrackLoadFailed userInfo:trackError.userInfo];
        [self throwError:error];
    }
}

- (void)updateInfoDictionary {
    OSDAudioPlayerItem *item = self.currentlyPlayingItem;
    if (!item) {
        return;
    }
    
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:4];
    info[MPMediaItemPropertyTitle] = item.displayName;
    info[MPMediaItemPropertyMediaType] = @(item.mediaType);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.player.rate);
    info[MPMediaItemPropertyPlaybackDuration] = @([self currentItemDuration]);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @([self currentItemProgress]);
    
    UIImage *image = nil;
    if (item.itemImage) {
        image = item.itemImage;
        info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithImage:image];
    }
    
    for (AVMetadataItem *item in [self.player.currentItem.asset commonMetadata]) {
        if ([[item commonKey] isEqualToString:AVMetadataCommonKeyArtist]) {
            info[MPMediaItemPropertyArtist] = [item value];
        }
        if (nil == image){
            if ([[item commonKey] isEqualToString:AVMetadataCommonKeyArtwork]) {
                if ([item.keySpace isEqualToString:AVMetadataKeySpaceID3]) {
                    if ([[[UIDevice currentDevice] systemVersion] floatValue] >= 8.0) {
                        NSData *newImage = [item.value copyWithZone:nil];
                        image = [UIImage imageWithData:newImage];
                    } else {
                        NSDictionary *dict = (NSDictionary *)[item value];
                        if ([dict objectForKey:@"data"]) {
                            image = [UIImage imageWithData:[dict objectForKey:@"data"]];
                        }
                    }
                } else if ([item.keySpace isEqualToString:AVMetadataKeySpaceiTunes]) {
                    image= [UIImage imageWithData:(NSData *)item.value];
                }
                if (image) {
                    info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithImage:image];
                }
            }
        }
    }
    
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:info];
}
- (void)changeVolume {
    
}

- (void)beginSeeking {
    [self invalidateUpdateNotifyTimer];
    self.calledBeginSeeking = YES;
    self.seekRestoreState = self.currentState;
    self.seekRestoreRate = self.player.rate;
    self.player.rate = 0.0;
    [self.player pause];
    [self setCurrentState:OSDAudioPlayerStateSeeking notify:YES];
}

- (void)seekToProgress:(NSTimeInterval)progress {
    [self seekToProgress:progress completion:nil];
}

- (void)seekToProgress:(NSTimeInterval)progress completion:(void(^)(BOOL finished))completion {
    if (!self.calledBeginSeeking) {
        OSDDebugLog(@"Didn't call - beginSeeking  this will cause problems");
    }
    double_t duration = [self currentItemDuration];
    if (duration == 0.0 || [self isSeekPerforming]) {
        return;
    }
    if (isfinite(duration)) {
        typeof(self) __weak welf = self;
        [self.player seekToTime:CMTimeMakeWithSeconds(progress, NSEC_PER_SEC) completionHandler:^(BOOL finished) {
            welf.seekPerforming = !finished;
            [welf updateProgress:nil];
            if (completion) {
                completion(finished);
            }
        }];
    }
}

- (void)seekForward
{
    [self beginSeeking];
    if (self.player.currentItem.canPlayFastForward) {
        self.player.rate = 10.0;
        [self updateNowPlayingInfo];
    }
}

- (void)seekBackwards
{
    [self beginSeeking];
    if (self.player.currentItem.canPlayFastReverse) {
        self.player.rate = -10.0;
        [self updateNowPlayingInfo];
    }
}

- (void)endSeeking {
    self.calledBeginSeeking = NO;
    [self setupUpdateNotifyTimerIfNeeded];
    self.player.rate = self.seekRestoreRate;
    self.seekRestoreRate = 0.0;
    if (_seekRestoreState == OSDAudioPlayerStatePlaying) {
        [self.player play];
    }
    [self setCurrentState:_seekRestoreState notify:YES];
    self.seekRestoreState = OSDAudioPlayerStateUnknown;
}

- (BOOL)isPlaying {
    return self.currentState == OSDAudioPlayerStatePlaying;
}
- (BOOL)isPaused {
    return self.currentState == OSDAudioPlayerStatePaused;
}
- (BOOL)isLoading {
    return (self.currentState == OSDAudioPlayerStateLoading || self.currentState == OSDAudioPlayerStateBuffering);
}

#pragma mark -
#pragma mark - Play Update Timer
- (void)setupUpdateNotifyTimerIfNeeded {
    if (![self.updateNotifyTimer isValid]) {
        self.updateNotifyTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(updateProgress:) userInfo:nil repeats:YES];
    }
    if (![self.updateNowPlayingInfo isValid]) {
        self.updateNowPlayingInfo = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(updateInfoDictionary) userInfo:nil repeats:YES];
    }
}
- (void)invalidateUpdateNotifyTimer {
    [self.updateNotifyTimer invalidate];
    self.updateNotifyTimer = nil;
    [self.updateNowPlayingInfo invalidate];
    self.updateNowPlayingInfo = nil;
}

#pragma mark -
#pragma mark - Notification Helpers
- (void)updatedQueue {
    OSDDebugLog(@"Item queue did change items (%lu)",self.itemQueue.count);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerQueueDidUpdateNotification object:self];
    });
}
- (void)updateWillPlayItem {
    OSDDebugLog(@"Will play item");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerWillPlayItemNotification object:self];
    });
}
- (void)throwError:(NSError *)error {
    OSDDebugLog(@"Throwing error: %@",error);
    dispatch_async(dispatch_get_main_queue(), ^{
        _lastThrownError = error;
        [self setCurrentState:OSDAudioPlayerStateError notify:YES];
        [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerDidThrowErrorNotification
                                                            object:self
                                                          userInfo:@{
                                                                     OSDAudioPlayerErrorNotificationErrorKey: error
                                                                     }];
    });
}

- (void)updateProgress:(NSTimer *)timer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerPlaybackProgressUpdatedNotification object:self];
    });
}

- (void)setCurrentState:(OSDAudioPlayerState)currentState notify:(BOOL)sendNotification {
    if (self.routeChangeDuringPause) {
        self.routeChangeDuringPause = NO;
        return;
    }
    _currentState = currentState;
    OSDDebugLog(@"Current State: %li",currentState);
    if (sendNotification) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerStateDidChangeNotification object:self];
        });
    }
}

#pragma mark -
#pragma mark - Lazy Loaders
- (NSMutableArray *)itemQueue {
    @synchronized(self) {
        if (!_itemQueue) {
            _itemQueue = [NSMutableArray array];
        }
        return _itemQueue;
    }
}

- (AVAudioSession *)audioSession {
    return [AVAudioSession sharedInstance];
}

#pragma mark -
#pragma mark - Initialization
- (instancetype)init {
	self = [super init];
	if (self) {
		dispatch_async(dispatch_get_main_queue(), ^{
            NSError *sessionError = nil;
            if (![self.audioSession setCategory:AVAudioSessionCategoryPlayback error:&sessionError]) {
                OSDDebugLog(@"Can't set session category: %@",sessionError);
            }
            NSError *activeSessionError = nil;
            if (![self.audioSession setActive:YES error:&activeSessionError]) {
                OSDDebugLog(@"Can't set session to active: %@",activeSessionError);
            }
            
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(currentItemDidPlayToEndNotification:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackStalledNotification:) name:AVPlayerItemPlaybackStalledNotification object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackInterruptionNotification:) name:AVAudioSessionInterruptionNotification object:nil];
            
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioPlayerRouteChangedNotification:) name:AVAudioSessionRouteChangeNotification object:nil];
            
            [self setCurrentState:OSDAudioPlayerStateUnknown notify:NO];
        });
        
        _playbackRule = OSDAudioPlayerAutoPlayWhenReady;
        _endPlaybackRule = OSDAudioPlayerCurrentItemEndPlayNext;
        _backgroundTask = UIBackgroundTaskInvalid;
	}
	return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark -
#pragma mark - Notification Methods
- (void)playbackStalledNotification:(NSNotification *)notif {
    [self setCurrentState:OSDAudioPlayerStateBuffering notify:YES];
}
- (void)currentItemDidPlayToEndNotification:(NSNotification *)notif {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setCurrentState:OSDAudioPlayerStateDone notify:YES];
        [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerPlaybackDidPlayToEndNotification object:self userInfo:notif.userInfo];
        
        switch (self.endPlaybackRule) {
            case OSDAudioPlayerCurrentItemEndPlayNext:
                if (![self playNextItem]) {
                    [self stop];
                }
                break;
            case OSDAudioPlayerCurrentItemEndRepeat:
                if (![self playCurrentItem]) {
                    [self stop];
                }
                break;
            case OSDAudioPlayerCurrentItemEndStop:
                [self stop];
                break;
            default:
                break;
        }
    });
}
- (void)playbackInterruptionNotification:(NSNotification *)notif
{
    AVAudioSessionInterruptionType interruptType = [notif.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    
    if ( AVAudioSessionInterruptionTypeEnded == interruptType ) {
        AVAudioSessionInterruptionOptions interruptOption = [notif.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        
        if (self.isPlaying && interruptOption == AVAudioSessionInterruptionOptionShouldResume) {
            [self play];
            self.pausedFromInteruption = NO;
        }
    }
}

#pragma mark -
#pragma mark - Singleton
+ (instancetype)sharedPlayer {
	@synchronized (self) {
        if (!_sharedOSDAudioPlayer) {
            _sharedOSDAudioPlayer = [[[self class] alloc] init];
        }
        return _sharedOSDAudioPlayer;
    }
}

#pragma mark -
#pragma mark - Player
- (void)destroyPlayer {
    OSDDebugLog(@"Destroying player");
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
    self.currentlyPlayingItem = nil;
    [self invalidateUpdateNotifyTimer];
	if (_player) {
		[_player removeObserver:self forKeyPath:kOSDRate context:OSDAudioPlayerRateChangeObservationContext];
        
		[_player pause];
		_player = nil;
        
        _pausedFromInteruption = NO;
	}
}

#pragma mark -
#pragma mark - Background
- (void)invalidateBackgroundTask {
    OSDDebugLog(@"Invalidating background task.");
    if (self.backgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
        _backgroundTask = UIBackgroundTaskInvalid;
    }
    [self destroyPlayer];
}
- (void)setupBackgroundTaskIfNeeded {
    if (_backgroundTask == UIBackgroundTaskInvalid) {
        OSDDebugLog(@"Setting up background task.");
        _backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [self stop];
            [self invalidateBackgroundTask];
        }];
    }
}

#pragma mark -
#pragma mark - KVO
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (context == OSDAudioPlayerRateChangeObservationContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerPlaybackTimeChangedNotification object:self];
            [self updateInfoDictionary];
        });
	} else if (context == OSDAudioPlayerPlayerItemStatusObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *thePlayerItem = (AVPlayerItem *)object;
            if (thePlayerItem.status == AVPlayerItemStatusReadyToPlay) {
                OSDDebugLog(@"Player item status changed (AVPlayerItemStatusReadyToPlay)");
                [self setCurrentState:OSDAudioPlayerStateReady notify:YES];
                [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerItemReadyToPlayNotification object:self];
                if (_playbackRule == OSDAudioPlayerAutoPlayWhenReady) {
                    [self play];
                }
            } else if (thePlayerItem.status == AVPlayerItemStatusFailed) {
                OSDDebugLog(@"Player item status changed (AVPlayerItemStatusFailed)");
                [self destroyPlayer];
                NSError *error = [[NSError alloc] initWithDomain:OSDAudioPlayerErrorDomain code:OSDAudioPlayerErrorPlayerItemFailed userInfo:nil];
                [self throwError:error];
                [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerItemFailedNotification object:self];
            } else if (thePlayerItem.status == AVPlayerItemStatusUnknown) {
                OSDDebugLog(@"Player item status changed (AVPlayerItemStatusUnknown)");
                [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerItemUnknownNotification object:self];
                [self setCurrentState:OSDAudioPlayerStateUnknown notify:YES];
            }
        });
	} else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark -
#pragma mark - Route Changed
- (void)audioPlayerRouteChangedNotification:(NSNotification *)notif {
    AVAudioSessionRouteChangeReason reason = [notif.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    
    if ([self isPaused]) {
        self.routeChangeDuringPause = YES;
    } else if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        self.pausedFromRouteChange = YES;
        [self pause];
    }
    [self updateInfoDictionary];
}

@end


@implementation OSDAudioPlayer (UIResponder)

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    
    OSDDebugLog(@"%s - %lu", __PRETTY_FUNCTION__, event.subtype);
    
    if (event.type == UIEventTypeRemoteControl) {
        switch (event.subtype) {
            case UIEventSubtypeRemoteControlPlay:
                [self play];
                break;
            case UIEventSubtypeRemoteControlPause:
                [self pause];
                break;
            case UIEventSubtypeRemoteControlStop:
                [self stop];
                break;
            case UIEventSubtypeRemoteControlTogglePlayPause:
                [self playOrPause];
                break;
            case UIEventSubtypeRemoteControlNextTrack:
                //[self playNextItem];
                OSDDebugLog(@"Remote wants to play next track");
                break;
            case UIEventSubtypeRemoteControlPreviousTrack:
                //[self playNextItem];
                OSDDebugLog(@"Remote wants to play previous item");
                break;
            case UIEventSubtypeRemoteControlBeginSeekingBackward:
                [self seekBackwards];
                break;
            case UIEventSubtypeRemoteControlEndSeekingBackward:
                [self endSeeking];
                break;
            case UIEventSubtypeRemoteControlBeginSeekingForward:
                [self seekForward];
                break;
            case UIEventSubtypeRemoteControlEndSeekingForward:
                [self endSeeking];
                break;
            default:
                break;
        }
    }
}

@end


//-------------------------------------------------------//
//-------------------------------------------------------//
//-------------------------------------------------------//
//-------------------------------------------------------//
//-------------------------------------------------------//
//-------------------------------------------------------//
@implementation OSDAudioPlayerItem

+ (instancetype)newPlayerItemWithURL:(NSURL *)itemURL displayName:(NSString *)displayName userInfo:(NSDictionary *)userInfo {
    NSParameterAssert(itemURL);
    
    OSDAudioPlayerItem *item = [[self alloc] init];
    item.itemURL = itemURL;
    item.displayName = (displayName) ?: [[itemURL path] lastPathComponent];
    item.mediaType = MPMediaTypeMusic;
    [item.userInfo addEntriesFromDictionary:userInfo];
    
    return item;
}

- (NSMutableDictionary *)userInfo {
    if (!_userInfo) {
        _userInfo = [NSMutableDictionary dictionary];
    }
    return _userInfo;
}

- (id)copyWithZone:(NSZone *)zone {
    OSDAudioPlayerItem *item = [[[self class] alloc] init];
    item.itemURL = [self.itemURL copyWithZone:zone];
    item.displayName = [self.displayName copyWithZone:zone];
    item.userInfo = [self.userInfo copyWithZone:zone];
    item.mediaType = self.mediaType;
    item.itemImage = self.itemImage;
    return item;
}

- (NSUInteger)hash {
    return [self.itemURL hash] + [self.displayName hash] + [self.userInfo hash];
}
- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[OSDAudioPlayerItem class]]) {
        return NO;
    }
    OSDAudioPlayerItem *compare = object;
    
    if (![self.itemURL isEqual:compare.itemURL]) {
        return NO;
    }
    if (![self.displayName isEqualToString:compare.displayName]) {
        return NO;
    }
    if (![self.userInfo isEqualToDictionary:compare.userInfo]) {
        return NO;
    }
    if (![self.itemImage isEqual:compare.itemImage]) {
        return NO;
    }
    
    return YES;
}

@end


//-------------------------------------------------------//
//-------------------------------------------------------//
//-------------------------------------------------------//
//-------------------------------------------------------//
//-------------------------------------------------------//
//-------------------------------------------------------//
@implementation NSDictionary (OSDAudioPlayerAdditions)

- (NSError *)OSDAudioPlayerError {
    return [self objectForKey:OSDAudioPlayerErrorNotificationErrorKey];
}

@end

NSString * const OSDAudioPlayerQueueDidUpdateNotification = @"OSDAudioPlayerQueueDidUpdateNotification";
NSString * const OSDAudioPlayerWillPlayItemNotification = @"OSDAudioPlayerWillPlayItemNotification";
NSString * const OSDAudioPlayerDidThrowErrorNotification = @"OSDAudioPlayerDidThrowErrorNotification";
NSString * const OSDAudioPlayerErrorNotificationErrorKey = @"OSDAudioPlayerErrorNotificationErrorKey";
NSString * const OSDAudioPlayerPlaybackTimeChangedNotification = @"OSDAudioPlayerPlaybackTimeChangedNotification";
NSString * const OSDAudioPlayerItemReadyToPlayNotification = @"OSDAudioPlayerItemReadyToPlayNotification";
NSString * const OSDAudioPlayerItemFailedNotification = @"OSDAudioPlayerItemFailedNotification";
NSString * const OSDAudioPlayerItemUnknownNotification = @"OSDAudioPlayerItemUnknownNotification";
NSString * const OSDAudioPlayerPlaybackProgressUpdatedNotification = @"OSDAudioPlayerPlaybackProgressUpdatedNotification";
NSString * const OSDAudioPlayerPlaybackDidPlayToEndNotification = @"OSDAudioPlayerPlaybackDidPlayToEndNotification";
NSString * const OSDAudioPlayerPlaybackStalledNotification = @"OSDAudioPlayerPlaybackStalledNotification";
NSString * const OSDAudioPlayerDidPlayNotification = @"OSDAudioPlayerDidPlayNotification";
NSString * const OSDAudioPlayerDidPauseNotification = @"OSDAudioPlayerDidPlayNotification";
NSString * const OSDAudioPlayerDidStopNotification = @"OSDAudioPlayerDidPlayNotification";
NSString * const OSDAudioPlayerStateDidChangeNotification = @"OSDAudioPlayerStateDidChangeNotification";

NSString * const OSDAudioPlayerErrorDomain = @"com.openskydev.AudioPlayerError";

