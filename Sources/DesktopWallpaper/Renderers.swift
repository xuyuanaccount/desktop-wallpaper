import AppKit
import AVFoundation
import WebKit
import WallpaperCore

@MainActor
final class VideoClock {
    private var anchor = CMClockGetTime(CMClockGetHostTimeClock())
    private var elapsed = 0.0
    private var paused = false

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if paused { elapsed += CMTimeSubtract(now, anchor).seconds }
        anchor = now
        self.paused = paused
    }

    func start(_ player: AVQueuePlayer) {
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.12, preferredTimescale: 600))
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else {
            player.play()
            return
        }
        let position = elapsed + (paused ? 0 : CMTimeSubtract(host, anchor).seconds)
        let itemTime = CMTime(seconds: position.truncatingRemainder(dividingBy: duration), preferredTimescale: 600)
        player.setRate(1, time: itemTime, atHostTime: host)
    }
}

@MainActor
final class VideoView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var ready = false
    private var failed = false
    private var playing = false
    private let clock: VideoClock?

    init(url: URL, clock: VideoClock?, onReady: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.clock = clock
        super.init(frame: .zero)
        wantsLayer = true
        layer = playerLayer
        playerLayer.player = player
        player.automaticallyWaitsToMinimizeStalling = clock == nil

        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        self.looper = looper
        observations = [
            looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let message = looper.error?.localizedDescription ?? "无法循环播放该视频。"
                DispatchQueue.main.async { self?.reportFailure(message, onError: onError) }
            },
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self, let item = self.player.currentItem else { return }
                    self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                        let status = item.status
                        let message = item.error?.localizedDescription ?? "无法播放该视频。"
                        DispatchQueue.main.async {
                            guard let self, self.player.currentItem === item else { return }
                            switch status {
                            case .readyToPlay:
                                if !self.ready {
                                    self.ready = true
                                    self.playIfReady()
                                    onReady()
                                }
                            case .failed:
                                self.reportFailure(message, onError: onError)
                            default:
                                break
                            }
                        }
                    }
                }
            }
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(fit: VideoFit, volume: Double, playing: Bool) {
        playerLayer.videoGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
        player.volume = Float(min(1, max(0, volume)))
        guard self.playing != playing else { return }
        self.playing = playing
        if playing { playIfReady() } else { player.pause() }
    }

    private func playIfReady() {
        guard playing, ready, !failed else { return }
        if let clock { clock.start(player) } else { player.play() }
    }

    private func reportFailure(_ message: String, onError: (String) -> Void) {
        guard !failed else { return }
        failed = true
        player.pause()
        onError(message)
    }
}

@MainActor
final class StaticImageView: NSView {
    private let image: CGImage
    var fit: VideoFit {
        didSet { if fit != oldValue { needsDisplay = true } }
    }

    init?(url: URL, fit: VideoFit) {
        guard let image = loadWallpaperImage(url) else { return nil }
        self.image = image
        self.fit = fit
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contents = image
        layer?.contentsGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
    }
}

enum DesktopPointer: String {
    case move, down, up, leave
}

@MainActor
final class WebView: WKWebView, WKNavigationDelegate {
    private let source: WallpaperSource
    private let onReady: () -> Void
    private let onError: (String) -> Void

    init(source: WallpaperSource, onReady: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.source = source
        self.onReady = onReady
        self.onError = onError
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.pointerBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
        )
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        switch source {
        case .localWeb(let entry, let root):
            loadFileURL(entry, allowingReadAccessTo: root ?? entry)
        case .remoteWeb(let url):
            load(URLRequest(url: url))
        case .video, .image:
            break
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func sendPointer(_ action: DesktopPointer, x: CGFloat, y: CGFloat) {
        evaluateJavaScript("globalThis.wallpaperPointer?.('\(action.rawValue)', \(Double(x)), \(Double(y)))",
                           in: nil, in: .defaultClient, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onReady() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onError("网页渲染进程已退出。请重载壁纸。") }

    private func report(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        onError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, action.targetFrame != nil else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        if action.targetFrame?.isMainFrame == false, ["http", "https"].contains(url.scheme?.lowercased()) { return .allow }
        if let access = source.webReadAccess {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let root = access.resolvingSymlinksInPath().standardizedFileURL.path
            return url.isFileURL && (path == root || path.hasPrefix(root + "/")) ? .allow : .cancel
        }
        return ["http", "https"].contains(url.scheme?.lowercased()) ? .allow : .cancel
    }

    private static let pointerBridge = """
    (() => {
        let previous = null;
        let pressed = null;
        const send = (node, name, x, y, buttons) => {
            if (!node) return;
            const EventType = name.startsWith('pointer') ? PointerEvent : MouseEvent;
            const bubbles = !name.endsWith('enter') && !name.endsWith('leave');
            node.dispatchEvent(new EventType(name, { bubbles, cancelable: true, clientX: x,
                clientY: y, buttons, pointerId: 1, pointerType: 'mouse', isPrimary: true }));
        };
        globalThis.wallpaperPointer = (phase, x, y) => {
            const target = phase === 'leave' ? null : document.elementFromPoint(x, y);
            if (target !== previous) {
                for (const event of ['pointerout', 'pointerleave', 'mouseout', 'mouseleave']) send(previous, event, x, y, 0);
                for (const event of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter']) send(target, event, x, y, 0);
                previous = target;
            }
            if (phase === 'leave') { pressed = null; return; }
            if (phase === 'move') {
                send(target, 'pointermove', x, y, pressed ? 1 : 0);
                send(target, 'mousemove', x, y, pressed ? 1 : 0);
            } else if (phase === 'down') {
                pressed = target;
                send(target, 'pointerdown', x, y, 1);
                send(target, 'mousedown', x, y, 1);
            } else if (phase === 'up') {
                send(target, 'pointerup', x, y, 0);
                send(target, 'mouseup', x, y, 0);
                if (target === pressed) send(target, 'click', x, y, 0);
                pressed = null;
            }
        };
    })();
    """
}
