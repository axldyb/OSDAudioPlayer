/*!
 * OSDAudioPlayer.m
 *
 * Copyright (c) 2013 OpenSky, LLC
 *
 * Created by Skylar Schipper on 11/9/13
 */


#import "OSDAudioPlayer.h"

static void _OSDAudioDebugLog(NSString *fmt, ...) {
    va_list arguments;
    va_start(arguments, fmt);
    NSString *string = [[NSString alloc] initWithFormat:fmt arguments:arguments];
    va_end(arguments);
    printf("OSDAudioPlayer: %s\n",[string UTF8String]);
}

#if DEBUG && OSD_AUDIO_PLAYER_DEBUG_LOG
    #define OSDDebugLog(fmt, ...) _OSDAudioDebugLog(fmt, ##__VA_ARGS__)
#else
    #define OSDDebugLog(fmt, ...)
#endif

void OSDAudioRouteChangeListenerCallback(void *inUserData, AudioSessionPropertyID inPropertyID, UInt32 inPropertyValueSize, const void *inPropertyValue);

id static _sharedOSDAudioPlayer = nil;

static NSString *const kOSDTracks      = @"tracks";
static NSString *const kOSDStatus      = @"status";
static NSString *const kOSDRate        = @"rate";
static NSString *const kOSDDuration    = @"duration";
static NSString *const kOSDPlayable    = @"playable";
static NSString *const kOSDCurrentItem = @"currentItem";

static void *OSDAudioPlayerRateChangeObservationContext = &OSDAudioPlayerRateChangeObservationContext;
static void *OSDAudioPlayerPlayerItemStatusObserverContext = &OSDAudioPlayerPlayerItemStatusObserverContext;

@interface OSDAudioPlayer ()

@property (nonatomic, strong) NSMutableArray *itemQueue;

@property (nonatomic, assign) BOOL pausedFromInteruption;
@property (nonatomic, assign) BOOL pausedFromRouteChange;
@property (nonatomic, assign) BOOL routeChangeDuringPause;

@property (nonatomic, strong) NSTimer *updateNotifyTimer;

@property (nonatomic, assign) BOOL calledBeginSeeking;
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
    return [NSArray arrayWithArray:self.itemQueue];
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
    if (_currentlyPlayingItem) {
        [self playItem:_currentlyPlayingItem];
        return YES;
    }
    return [self playNextItem];
}
- (void)playItem:(OSDAudioPlayerItem *)item {
    [self willChangeValueForKey:@"currentlyPlayingItem"];
    _currentlyPlayingItem = item;
    [self didChangeValueForKey:@"currentlyPlayingItem"];
    [self updateWillPlayItem];
    [self playAudioFromURL:_currentlyPlayingItem.itemURL];
}

- (void)play {
    dispatch_async(dispatch_get_main_queue(), ^{
        _pausedFromRouteChange = NO;
        [self setupUpdateNotifyTimerIfNeeded];
        [self.player play];
        [self setCurrentState:OSDAudioPlayerStatePlaying notify:YES];
        [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerDidPlayNotification object:self];
    });
}
- (void)setupUpdateNotifyTimerIfNeeded {
    if (!_updateNotifyTimer) {
        _updateNotifyTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(updateProgress:) userInfo:nil repeats:YES];
    }
}
- (void)pause {
    _pausedFromInteruption = NO;
    [_updateNotifyTimer invalidate];
    _updateNotifyTimer = nil;
    [self.player pause];
    [self setCurrentState:OSDAudioPlayerStatePaused notify:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:OSDAudioPlayerDidPauseNotification object:self];
}
- (void)stop {
    _pausedFromRouteChange = NO;
    _pausedFromInteruption = NO;
    [self.player pause];
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];
    [self destroyPlayer];
    [self setCurrentState:OSDAudioPlayerStateStopped notify:YES];
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
    
}
- (void)changeVolume {
    
}


- (void)beginSeeking {
    [_updateNotifyTimer invalidate];
    _updateNotifyTimer = nil;
    _calledBeginSeeking = YES;
    _seekRestoreState = self.currentState;
    _seekRestoreRate = self.player.rate;
    self.player.rate = 0.0;
    [self.player pause];
    [self setCurrentState:OSDAudioPlayerStateSeeking notify:YES];
}
- (void)seekToProgress:(NSTimeInterval)progress {
    if (!_calledBeginSeeking) {
        OSDDebugLog(@"Didn't call - beginSeeking  this will cause problems");
    }
    
    if (progress == 0.0) {
        return;
    }
    
    if (isfinite(progress)) {
        [self.player seekToTime:CMTimeMakeWithSeconds(progress, NSEC_PER_SEC)];
    }
}
- (void)endSeeking {
    _calledBeginSeeking = NO;
    [self setupUpdateNotifyTimerIfNeeded];
    self.player.rate = _seekRestoreRate;
    _seekRestoreRate = 0.0;
    if (_seekRestoreState == OSDAudioPlayerStatePlaying) {
        [self.player play];
    }
    [self setCurrentState:_seekRestoreState notify:YES];
    _seekRestoreState = OSDAudioPlayerStateUnknown;
}


- (BOOL)isPlaying {
    return self.currentState == OSDAudioPlayerStatePlaying;
}
- (BOOL)isPaused {
    return self.currentState == OSDAudioPlayerStatePaused;
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
        _routeChangeDuringPause = NO;
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

#pragma mark -
#pragma mark - Initialization
- (instancetype)init {
	self = [super init];
	if (self) {
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(currentItemDidPlayToEndNotification:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackStalledNotification:) name:AVPlayerItemPlaybackStalledNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackInterruptionNotification:) name:AVAudioSessionInterruptionNotification object:nil];
        
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
        
        AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, OSDAudioRouteChangeListenerCallback, (__bridge void *)(self));
        
        [self setCurrentState:OSDAudioPlayerStateUnknown notify:NO];
        
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
                [self playNextItem];
                break;
            case OSDAudioPlayerCurrentItemEndRepeat:
                [self playCurrentItem];
                break;
            case OSDAudioPlayerCurrentItemEndStop:
                [self stop];
                break;
            default:
                break;
        }
    });
}
- (void)playbackInterruptionNotification:(NSNotification *)notif {
    AVAudioSessionInterruptionType interruptionType = [notif.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (interruptionType == AVAudioSessionInterruptionTypeBegan && _currentState == OSDAudioPlayerStatePlaying) {
        [self pause];
        _pausedFromInteruption = YES;
    } else if (interruptionType == AVAudioSessionInterruptionTypeEnded && !(!_pausedFromRouteChange && _pausedFromInteruption)) {
        [self play];
        _pausedFromInteruption = NO;
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

/**
 This code was taken from http://developer.apple.com/library/ios/#samplecode/AddMusic/Listings/Classes_MainViewController_m.html#//apple_ref/doc/uid/DTS40008845-Classes_MainViewController_m-DontLinkElementID_6
 */
void OSDAudioRouteChangeListenerCallback(void *inUserData, AudioSessionPropertyID inPropertyID, UInt32 inPropertyValueSize, const void *inPropertyValue) {
    if (inPropertyID != kAudioSessionProperty_AudioRouteChange) return;
    
    if ([[OSDAudioPlayer sharedPlayer] currentState] != OSDAudioPlayerStatePlaying && [[OSDAudioPlayer sharedPlayer] currentState] == OSDAudioPlayerStatePaused) {
        [[OSDAudioPlayer sharedPlayer] setRouteChangeDuringPause:YES];
    } else {
        CFDictionaryRef routeChangeDictionary = inPropertyValue;
        CFNumberRef routeChangeReasonRef = CFDictionaryGetValue(routeChangeDictionary, CFSTR (kAudioSession_AudioRouteChangeKey_Reason));
        SInt32 routeChangeReason;
        CFNumberGetValue(routeChangeReasonRef, kCFNumberSInt32Type, &routeChangeReason);
        
        if (routeChangeReason == kAudioSessionRouteChangeReason_OldDeviceUnavailable) {
            [[OSDAudioPlayer sharedPlayer] setPausedFromRouteChange:YES];
            [[OSDAudioPlayer sharedPlayer] pause];
        }
    }
}

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

