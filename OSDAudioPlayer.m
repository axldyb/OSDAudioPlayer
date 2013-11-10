/*!
 * OSDAudioPlayer.m
 *
 * Copyright (c) 2013 OpenSky, LLC
 *
 * Created by Skylar Schipper on 11/9/13
 */


#import "OSDAudioPlayer.h"

id static _sharedOSDAudioPlayer = nil;

@implementation OSDAudioPlayer


#pragma mark -
#pragma mark - Initialization
- (id)init {
	self = [super init];
	if (self) {
		
	}
	return self;
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

@end
