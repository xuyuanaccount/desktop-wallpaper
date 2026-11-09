import AppKit
import WallpaperCore

@MainActor
final class DesktopSurface {
    private let window: NSWindow
    private let container = NSView()
    private var video: VideoView?
    private var image: StaticImageView?
    private var web: WebView?
    private var rendered = false
    private var failed = false
    private var viewport = CGRect.zero
    private var paused = false
    private let clock: VideoClock?
    private let onError: (String) -> Void
    private(set) var wallpaper: Wallpaper
    private(set) var displayFrame: CGRect
    var interactive: Bool { wallpaper.interactive && web != nil && rendered && !paused }

    init(wallpaper: Wallpaper, displayFrame: CGRect, clock: VideoClock?, onError: @escaping (String) -> Void) {
        self.wallpaper = wallpaper
        self.displayFrame = displayFrame
        self.clock = clock
        self.onError = onError
        window = NSWindow(contentRect: displayFrame, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "DesktopWallpaper • Desktop"
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.hasShadow = false
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        window.contentView = container
    }

    func update(wallpaper: Wallpaper, displayFrame: CGRect, canvas: CGRect, paused: Bool, audio: Bool) {
        if self.displayFrame != displayFrame {
            self.displayFrame = displayFrame
            window.setFrame(displayFrame, display: false)
        }
        self.wallpaper = wallpaper
        self.paused = paused
        viewport = Layout.viewport(for: displayFrame, canvas: canvas)
        switch wallpaper.source {
        case .video(let url):
            if video == nil && !failed {
                let view = VideoView(url: url, clock: clock,
                                     onReady: { [weak self] in self?.show() },
                                     onError: { [weak self] in self?.fail($0) })
                container.addSubview(view)
                video = view
            }
            video?.frame = viewport
            video?.update(fit: wallpaper.fit, volume: audio ? wallpaper.volume : 0, playing: !paused)
        case .image(let url):
            if image == nil && !failed {
                guard let view = StaticImageView(url: url, fit: wallpaper.fit) else {
                    fail("无法读取壁纸图片。")
                    return
                }
                view.frame = viewport
                container.addSubview(view)
                image = view
                show()
            }
            image?.frame = viewport
            image?.fit = wallpaper.fit
        case .localWeb, .remoteWeb:
            if paused {
                web?.stopLoading()
                web?.removeFromSuperview()
                web = nil
                rendered = false
                window.orderOut(nil)
            } else if web == nil && !failed {
                let view = WebView(source: wallpaper.source,
                                   onReady: { [weak self] in self?.show() },
                                   onError: { [weak self] in self?.fail($0) })
                container.addSubview(view)
                web = view
            }
            web?.frame = viewport
        }
    }

    func sendPointer(_ action: DesktopPointer, at point: CGPoint) {
        let x = point.x - displayFrame.minX - viewport.minX
        let y = viewport.height - (point.y - displayFrame.minY - viewport.minY)
        web?.sendPointer(action, x: x, y: y)
    }

    func close() {
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        video?.update(fit: wallpaper.fit, volume: 0, playing: false)
        video?.removeFromSuperview()
        video = nil
        image?.removeFromSuperview()
        image = nil
        window.close()
    }

    private func show() {
        guard !failed else { return }
        if video == nil && image == nil && (paused || web == nil) { return }
        rendered = true
        window.orderFrontRegardless()
    }

    private func fail(_ message: String) {
        failed = true
        rendered = false
        window.orderOut(nil)
        onError(message)
    }
}
