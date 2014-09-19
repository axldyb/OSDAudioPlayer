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

#ifndef OSDAudioPlayer_h
#define OSDAudioPlayer_h

@import Foundation;
@import AVFoundation;
@import MediaPlayer;

// Notifications
OBJC_EXTERN NSString * const OSDAudioPlayerQueueDidUpdateNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerWillPlayItemNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerPlaybackTimeChangedNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerItemReadyToPlayNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerItemFailedNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerItemUnknownNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerPlaybackProgressUpdatedNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerPlaybackDidPlayToEndNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerPlaybackStalledNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerStateDidChangeNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerDidPlayNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerDidPauseNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerDidStopNotification;

// Errors
OBJC_EXTERN NSString * const OSDAudioPlayerDidThrowErrorNotification;
OBJC_EXTERN NSString * const OSDAudioPlayerErrorNotificationErrorKey;
OBJC_EXTERN NSString * const OSDAudioPlayerErrorDomain;

#ifndef OSD_AUDIO_PLAYER_DEBUG_LOG
    #define OSD_AUDIO_PLAYER_DEBUG_LOG 1
#endif

typedef NS_ENUM(NSInteger, OSDAudioPlayerErrorCodes) {
    OSDAudioPlayerErrorCodeUnknown          = -1,
    OSDAudioPlayerErrorNoURLForItem         = 400,
    OSDAudioPlayerErrorAssetNotPlayable     = 500,
    OSDAudioPlayerErrorAssetTrackLoadFailed = 501,
    OSDAudioPlayerErrorPlayerItemFailed     = 502
};

typedef NS_ENUM(NSInteger, OSDAudioPlayerPlayRule) {
    OSDAudioPlayerAutoPlayWhenReady    = 0, // Default
    OSDAudioPlayerManualyPlayWhenReady = 1
};
typedef NS_ENUM(NSInteger, OSDAudioPlayerCurrentItemEndRule) {
    OSDAudioPlayerCurrentItemEndPlayNext = 0, // Default
    OSDAudioPlayerCurrentItemEndStop     = 1,
    OSDAudioPlayerCurrentItemEndRepeat   = 2
};
typedef NS_ENUM(NSInteger, OSDAudioPlayerState) {
    OSDAudioPlayerStateUnknown   = 0,
    OSDAudioPlayerStatePlaying   = 1,
    OSDAudioPlayerStatePaused    = 2,
    OSDAudioPlayerStateLoading   = 3,
    OSDAudioPlayerStateStopped   = 4,
    OSDAudioPlayerStateSeeking   = 5,
    OSDAudioPlayerStateReady     = 6,
    OSDAudioPlayerStateDone      = 7,
    OSDAudioPlayerStateBuffering = 8,
    OSDAudioPlayerStateError     = 9
};


@interface OSDAudioPlayerItem : NSObject <NSCopying>

@property (nonatomic, strong) NSURL *itemURL;

@property (nonatomic, strong) NSString *displayName;

@property (nonatomic, strong) NSMutableDictionary *userInfo;

@property (nonatomic, strong) UIImage *itemImage;

+ (instancetype)newPlayerItemWithURL:(NSURL *)itemURL displayName:(NSString *)displayName userInfo:(NSDictionary *)userInfo;

@property (nonatomic) MPMediaType mediaType;

@end

/*!
 *  Simple Audio Player
 */
@interface OSDAudioPlayer : NSObject

/*!
 *  Shared instance class method for accessing the shared instance of OSDAudioPlayer
 *
 *  \return Returns the shared instance of OSDAudioPlayer
 */
+ (instancetype)sharedPlayer;

#pragma mark -
#pragma mark - Queue
- (void)queueItem:(OSDAudioPlayerItem *)item;
- (void)insertItemIntoQueue:(OSDAudioPlayerItem *)item atIndex:(NSInteger)index;

- (void)dequeueItem:(OSDAudioPlayerItem *)item;
- (void)dequeueItemAtIndex:(NSInteger)index;
- (void)clearQueue;

- (NSArray *)queuedItems;

#pragma mark -
#pragma mark - State
@property (nonatomic, strong, readonly) OSDAudioPlayerItem *currentlyPlayingItem;
@property (nonatomic, assign, readonly) OSDAudioPlayerState currentState;

- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isLoading;

- (NSTimeInterval)currentItemProgress;
- (NSTimeInterval)loadedProgress;
- (NSTimeInterval)currentItemDuration;

- (float_t)progress;

#pragma mark -
#pragma mark - Playback
@property (nonatomic, assign) OSDAudioPlayerPlayRule playbackRule;
@property (nonatomic, assign) OSDAudioPlayerCurrentItemEndRule endPlaybackRule;

- (void)play;
- (void)pause;
- (void)stop;

- (BOOL)playNextItem;
- (BOOL)playCurrentItem;

- (void)beginSeeking;
- (void)seekToProgress:(NSTimeInterval)progress;
- (void)seekToProgress:(NSTimeInterval)progress completion:(void(^)(BOOL finished))completion;
- (void)endSeeking;


#pragma mark -
#pragma mark - Audio Player
@property (nonatomic, strong, readonly) AVPlayer *player;
@property (nonatomic, strong, readonly) AVAudioSession *audioSession;

- (void)destroyPlayer;

#pragma mark -
#pragma mark - Misc
@property (nonatomic, readonly) UIBackgroundTaskIdentifier backgroundTask;
- (void)invalidateBackgroundTask;

@property (nonatomic, strong, readonly) NSError *lastThrownError;

@end


@interface NSDictionary (OSDAudioPlayerAdditions)

- (NSError *)OSDAudioPlayerError;

@end

@interface OSDAudioPlayer (UIResponder)

- (void)remoteControlReceivedWithEvent:(UIEvent *)event;

@end


NS_INLINE NSString *OSDAudioPlayerTimeToString(NSTimeInterval time) {
    NSInteger minutes = (NSInteger)(floor(time) / 60);
    NSInteger seconds = ((NSInteger)floor(time) % 60);
    return [NSString stringWithFormat:@"%li:%02li",(long)minutes,(long)seconds];
}

#endif
