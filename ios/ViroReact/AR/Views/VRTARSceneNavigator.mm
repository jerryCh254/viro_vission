//
//  VRTARSceneNavigator.mm
//  ViroReact
//
//  Created by Andy Chu on 6/12/17.
//  Copyright ©️ 2017 Viro Media. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining
//  a copy of this software and associated documentation files (the
//  "Software"), to deal in the Software without restriction, including
//  without limitation the rights to use, copy, modify, merge, publish,
//  distribute, sublicense, and/or sell copies of the Software, and to
//  permit persons to whom the Software is furnished to do so, subject to
//  the following conditions:
//
//  The above copyright notice and this permission notice shall be included
//  in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#import <ViroKit/ViroKit.h>
#import "VRTARSceneNavigator.h"
#import <React/RCTAssert.h>
#import <React/RCTLog.h>
#import "VRTARScene.h"
#import "VRTNotifications.h"
#import <React/RCTRootView.h>
#import <React/RCTUtils.h>
#import "VRTPerfMonitor.h"
#import "VRTMaterialManager.h"

@implementation VRTARSceneNavigator {
    id <VROView> _vroView;
    NSInteger _currentStackPosition;
    RCTBridge *_bridge;
    VROVideoQuality _vroVideoQuality;
    BOOL _isSessionPaused;
}

- (instancetype)initWithBridge:(RCTBridge *)bridge {
    self = [super initWithBridge:bridge];
    if (self) {
        // Load materials; must be done each time we have a new context
        VRTMaterialManager *materialManager = [bridge materialManager];
        [materialManager reloadMaterials];
        
        [self setFrame:CGRectMake(0, 0,
                                  [[UIScreen mainScreen] bounds].size.width,
                                  [[UIScreen mainScreen] bounds].size.height)];
        self.currentViews = [[NSMutableArray alloc] init];
        _currentStackPosition = -1;
        _isSessionPaused = NO;

        _bridge = bridge;
        _autofocus = YES;
        _vroVideoQuality = VROVideoQuality::High;
        _numberOfTrackedImages = 0;
        _hdrEnabled = YES;
        _pbrEnabled = YES;
        _bloomEnabled = YES;
        _shadowsEnabled = YES;
        _multisamplingEnabled = NO;
    }
    return self;
}

#pragma mark - AR Session Management

- (void)pauseARSession {
    if (_isSessionPaused) {
        return;
    }
    
    if (_vroView) {
        VROViewAR *viewAR = (VROViewAR *)_vroView;
        [viewAR setPaused:YES];
        @try {
            std::shared_ptr<VROARSession> arSession = [viewAR getARSession];
            if (arSession) {
                arSession->pause();
            }
        } @catch (NSException *exception) {
            RCTLogError(@"Error pausing AR session: %@", exception.reason);
        }
        _isSessionPaused = YES;
    }
}

- (void)resumeARSession {
    if (!_isSessionPaused) {
        return;
    }
    
    if (_vroView) {
        VROViewAR *viewAR = (VROViewAR *)_vroView;
        [viewAR setPaused:NO];
        @try {
            std::shared_ptr<VROARSession> arSession = [viewAR getARSession];
            if (arSession) {
                arSession->run();
            }
        } @catch (NSException *exception) {
            RCTLogError(@"Error resuming AR session: %@", exception.reason);
        }
        _isSessionPaused = NO;
    }
}

#pragma mark - View Lifecycle

- (void)didMoveToWindow {
    [super didMoveToWindow];
    
    if (self.window) {
        [self resumeARSession];
    } else {
        [self pauseARSession];
    }
}

- (void)removeFromSuperview {
    [self parentDidDisappear];
    [self pauseARSession];
    
    if (_vroView) {
        @try {
            VROViewAR *viewAR = (VROViewAR *)_vroView;
            [viewAR deleteGL];
        } @catch (NSException *exception) {
            RCTLogError(@"Error during AR view cleanup: %@", exception.reason);
        }
    }
    
    [super removeFromSuperview];
}

#pragma mark - RCTInvalidating

- (void)invalidate {
    [self pauseARSession];
    
    if (_vroView) {
        @try {
            VROViewAR *viewAR = (VROViewAR *)_vroView;
            [viewAR deleteGL];
        } @catch (NSException *exception) {
            RCTLogError(@"Error during AR view cleanup: %@", exception.reason);
        }
        _vroView = nil;
    }
    
    _currentScene = nil;
    _childViews = nil;
}

#pragma mark - Property Setters

- (void)setAutofocus:(BOOL)autofocus {
    _autofocus = autofocus;
    if (_vroView) {
        VROViewAR *viewAR = (VROViewAR *) _vroView;
        std::shared_ptr<VROARSession> arSession = [viewAR getARSession];
        if (arSession) {
            arSession->setAutofocus(_autofocus);
        }
    }
}

- (void)setVideoQuality:(NSString *)videoQuality {
    _videoQuality = videoQuality;
    if ([videoQuality caseInsensitiveCompare:@"Low"] == NSOrderedSame) {
        _vroVideoQuality = VROVideoQuality::Low;
    } else {
        _vroVideoQuality = VROVideoQuality::High;
    }
    if (_vroView) {
        VROViewAR *viewAR = (VROViewAR *) _vroView;
        std::shared_ptr<VROARSession> arSession = [viewAR getARSession];
        if (arSession) {
            arSession->setVideoQuality(_vroVideoQuality);
        }
    }
}

// ... [Keep all other existing property setters unchanged] ...

#pragma mark - Scene Management

- (void)setSceneView:(VRTScene *)sceneView {
    if (_currentScene == sceneView) {
        return;
    }

    if (_vroView) {
        if (_currentScene == nil) {
            [_vroView setSceneController:[sceneView sceneController]];
        } else {
            [_vroView setSceneController:[sceneView sceneController] duration:1 timingFunction:VROTimingFunctionType::EaseIn];
        }
    }

    _currentScene = sceneView;
}

#pragma mark - React Subviews

- (void)insertReactSubview:(UIView *)subview atIndex:(NSInteger)atIndex {
    RCTAssert([subview isKindOfClass:[VRTARScene class]], @"VRTARNavigator only accepts VRTARScene subviews");
    [super insertReactSubview:subview atIndex:atIndex];
    
    VRTARScene *sceneView = (VRTARScene *)subview;
    [sceneView setView:_vroView];
    [self.currentViews insertObject:sceneView atIndex:atIndex];
    
    if (self.currentSceneIndex == atIndex){
        [self setSceneView:sceneView];
    }
}

- (void)removeReactSubview:(UIView *)subview {
    VRTARScene *sceneView = (VRTARScene *)subview;
    [self.currentViews removeObject:sceneView];
    [super removeReactSubview:subview];
}

#pragma mark - Projection Methods

- (VROVector3f)unprojectPoint:(VROVector3f)point {
    if(_vroView == nil || _vroView.renderer == nil) {
        RCTLogError(@"Unable to unproject. Renderer not initialized");
        return VROVector3f();
    }
    return [_vroView unprojectPoint:point];
}

- (VROVector3f)projectPoint:(VROVector3f)point {
    if(_vroView == nil || _vroView.renderer == nil) {
        RCTLogError(@"Unable to project. Renderer not initialized");
        return VROVector3f();
    }
    return [_vroView projectPoint:point];
}
 // njnj
@end
