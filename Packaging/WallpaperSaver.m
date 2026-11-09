#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <ScreenSaver/ScreenSaver.h>
#import <WebKit/WebKit.h>

@interface DesktopWallpaperSaverView : ScreenSaverView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) CALayer *contentLayer;
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation DesktopWallpaperSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)preview {
    self = [super initWithFrame:frame isPreview:preview];
    if (self) {
        self.animationTimeInterval = 1;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)startAnimation {
    [super startAnimation];
    if (self.contentLayer || self.webView) return;
    NSURL *resources = [NSBundle bundleForClass:self.class].resourceURL;
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfURL:[resources URLByAppendingPathComponent:@"Wallpaper.plist"]];
    NSString *entry = config[@"entry"];
    if (!entry) return;
    NSURL *file = [resources URLByAppendingPathComponent:entry];
    if ([config[@"kind"] isEqualToString:@"video"]) {
        self.player = [AVQueuePlayer new];
        self.player.muted = YES;
        self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:[AVPlayerItem playerItemWithURL:file]];
        AVPlayerLayer *videoLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
        videoLayer.videoGravity = [config[@"fit"] isEqualToString:@"fit"] ? AVLayerVideoGravityResizeAspect : AVLayerVideoGravityResizeAspectFill;
        self.contentLayer = videoLayer;
        [self.player play];
    } else if ([config[@"kind"] isEqualToString:@"image"]) {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)file, NULL);
        if (!source) return;
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        NSNumber *orientation = properties[(__bridge NSString *)kCGImagePropertyOrientation];
        CGImageRef image;
        if (orientation && orientation.integerValue != 1) {
            NSDictionary *options = @{
                (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES
            };
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        }
        CFRelease(source);
        if (!image) return;
        self.contentLayer = [CALayer layer];
        self.contentLayer.contents = (__bridge id)image;
        self.contentLayer.contentsGravity = [config[@"fit"] isEqualToString:@"fit"] ? kCAGravityResizeAspect : kCAGravityResizeAspectFill;
        CGImageRelease(image);
    } else if ([config[@"kind"] isEqualToString:@"web"]) {
        WKWebViewConfiguration *webConfig = [WKWebViewConfiguration new];
        webConfig.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        webConfig.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
        self.webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:webConfig];
        self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:self.webView];
        NSString *root = config[@"root"];
        [self.webView loadFileURL:file allowingReadAccessToURL:root ? [resources URLByAppendingPathComponent:root] : file];
    }
    if (self.contentLayer) {
        self.contentLayer.frame = self.bounds;
        [self.layer addSublayer:self.contentLayer];
    }
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.contentLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)stopAnimation {
    [self.player pause];
    [self.looper disableLooping];
    [self.contentLayer removeFromSuperlayer];
    self.contentLayer = nil;
    self.looper = nil;
    self.player = nil;
    [self.webView stopLoading];
    [self.webView removeFromSuperview];
    self.webView = nil;
    [super stopAnimation];
}

- (void)animateOneFrame {}

@end
