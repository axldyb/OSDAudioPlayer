/*!
 *  OSDAudioPlayer.h
 *
 * Copyright (c) 2013 OpenSky, LLC
 *
 * Created by Skylar Schipper on 11/9/13
 */

#ifndef OSDAudioPlayer_h
#define OSDAudioPlayer_h

@import Foundation;
@import AVFoundation;

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

@end

#endif
