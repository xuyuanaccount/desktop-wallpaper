import AppKit
import AVFoundation
import ScreenSaver
import Testing
import WallpaperCore
@testable import DesktopWallpaper

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_GUI_TESTS"] == "1"))
@MainActor
struct DesktopSmokeTests {
    @Test func launchInstallsNativeCopyAndPasteShortcuts() throws {
        let app = NSApplication.shared
        let originalMenu = app.mainMenu
        defer { app.mainMenu = originalMenu }
        app.mainMenu = nil

        let delegate: NSApplicationDelegate = WallpaperApp()
        delegate.applicationWillFinishLaunching?(Notification(name: NSApplication.willFinishLaunchingNotification, object: app))

        let menu = try #require(app.mainMenu)
        let edit = try #require(menu.item(withTitle: "编辑")?.submenu)
        let copy = try #require(edit.items.first { $0.action == #selector(NSText.copy(_:)) })
        let paste = try #require(edit.items.first { $0.action == #selector(NSText.paste(_:)) })
        #expect(copy.keyEquivalent == "c")
        #expect(paste.keyEquivalent == "v")
        #expect(copy.keyEquivalentModifierMask == .command)
        #expect(paste.keyEquivalentModifierMask == .command)
        #expect(copy.target == nil)
        #expect(paste.target == nil)
    }

    @Test func clipboardShortcutsActOnTheWindowEditor() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = IsolatedClipboardEditor(frame: frame)
        defer { editor.board.releaseGlobally() }
        window.contentView = editor
        try #require(window.makeFirstResponder(editor))
        editor.string = "壁纸测试"

        func command(_ key: String, code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code
            ))
        }

        editor.setSelectedRange(NSRange(location: 0, length: 2))
        let copy = try command("c", code: 8)
        #expect(EditingMenu.performShortcut(copy))
        #expect(editor.board.string(forType: .string) == "壁纸")

        editor.setSelectedRange(NSRange(location: 4, length: 0))
        let paste = try command("v", code: 9)
        #expect(EditingMenu.performShortcut(paste))
        #expect(editor.string == "壁纸测试壁纸")
    }

    @Test func localHTMLAppearsAtDesktopLevelAndCanPause() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var wallpaper = Wallpaper(title: "Test", source: .localWeb(entry: source, root: nil))
        wallpaper.interactive = true
        let frame = CGRect(x: screen.frame.minX + 32, y: screen.frame.minY + 96, width: 320, height: 180)
        var failure: String?
        let surface = DesktopSurface(wallpaper: wallpaper, displayFrame: frame, clock: nil) { failure = $0 }
        defer { surface.close() }
        surface.update(wallpaper: wallpaper, displayFrame: frame, canvas: frame, paused: false, audio: false)
        let window = try #require(NSApp.windows.first { $0.title == "DesktopWallpaper • Desktop" })
        await wait { window.isVisible || failure != nil }
        #expect(failure == nil)
        #expect(window.isVisible)
        #expect(window.level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)))
        #expect(window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
        #expect(window.ignoresMouseEvents)
        let web = try #require(window.contentView?.subviews.compactMap { $0 as? WebView }.first)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        surface.sendPointer(.down, at: point)
        surface.sendPointer(.up, at: point)
        let clicks = try await web.evaluateJavaScript("window.clicks") as? Int
        #expect(clicks == 1)
        surface.update(wallpaper: wallpaper, displayFrame: frame, canvas: frame, paused: true, audio: false)
        #expect(!window.isVisible)
        #expect(window.contentView?.subviews.isEmpty == true)
        surface.update(wallpaper: wallpaper, displayFrame: frame, canvas: frame, paused: false, audio: false)
        await wait { window.isVisible }
        #expect(window.isVisible)
    }

    @Test func videoRendererPlaysAndPausesARealVideo() async throws {
        _ = NSApplication.shared
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.mp4")
        try await writeVideo(to: url)
        var ready = false
        var failure: String?
        let view = VideoView(url: url, clock: nil, onReady: { ready = true }, onError: { failure = $0 })
        view.update(fit: .fill, volume: 0, playing: true)
        let player = try #require((view.layer as? AVPlayerLayer)?.player as? AVQueuePlayer)
        await wait { player.currentTime().seconds > 0.15 || failure != nil }
        #expect(failure == nil)
        #expect(ready)
        #expect(player.currentTime().seconds > 0.15)
        let initialItem = player.currentItem
        await wait { player.currentItem != initialItem }
        #expect(player.currentItem != initialItem)
        view.update(fit: .fill, volume: 0, playing: false)
        #expect(player.rate == 0)
    }

    @Test func generatedMP4CanBeSavedAndAppliedWithoutCreatingDuplicates() async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("draft.mp4")
        try await writeVideo(to: source)
        try await PlayableVideo.check(source)

        let model = ControlModel(directory: directory)
        defer { model.engine.stop() }
        let task = PendingVideoTask(taskID: "wan-task-1", region: .beijing, title: "AI 视频 · 云")
        let preview = GeneratedVideoPreview(task: task, url: source)
        try model.saveGeneratedVideo(preview, apply: false)
        #expect(model.settings.defaultAssignment == .off)
        try model.saveGeneratedVideo(preview, apply: true)

        let item = try #require(model.selected)
        #expect(model.settings.wallpapers.count == 1)
        #expect(model.settings.defaultAssignment == .wallpaper(task.wallpaperID))
        #expect(item.id == task.wallpaperID)
        guard case .video(let saved) = item.source else {
            Issue.record("Generated MP4 should use the ordinary video wallpaper source")
            return
        }
        #expect(saved != source)
        #expect(try Data(contentsOf: saved) == Data(contentsOf: source))
        let settingsFile = SettingsFile(url: directory.appendingPathComponent("settings.json"))
        #expect(try settingsFile.load().wallpapers == [item])
        await wait { NSApp.windows.contains { window in
            window.isVisible && window.contentView?.subviews.contains(where: { $0 is VideoView }) == true
        } }
        #expect(NSApp.windows.contains { window in
            window.isVisible && window.contentView?.subviews.contains(where: { $0 is VideoView }) == true
        })
    }

    @Test func savedAIWallpaperAppliesAtDesktopLevelAndPersists() async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ControlModel(directory: directory)
        defer { model.engine.stop() }
        let png = wallpaperPNGFixture
        let preview = GeneratedWallpaperPreview(title: "AI · 山谷", image: try #require(NSImage(data: png)), png: png)
        try model.saveGenerated(preview, apply: true)

        let item = try #require(model.selected)
        #expect(item.title == "AI · 山谷")
        #expect(model.settings.defaultAssignment == .wallpaper(item.id))
        #expect(try Data(contentsOf: item.source.url) == png)
        let settingsFile = SettingsFile(url: directory.appendingPathComponent("settings.json"))
        #expect(try settingsFile.load().wallpapers == [item])

        let window = try #require(NSApp.windows.first {
            $0.isVisible && $0.contentView?.subviews.contains(where: { $0 is StaticImageView }) == true
        })
        #expect(window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
        let view = try #require(window.contentView?.subviews.compactMap { $0 as? StaticImageView }.first)
        await wait { view.layer?.contents != nil }
        #expect(view.layer?.contents != nil)
        #expect(view.layer?.contentsGravity == .resizeAspectFill)
        model.changeWallpaper(item.id) { $0.fit = .fit }
        await wait { view.layer?.contentsGravity == .resizeAspect }
        #expect(view.layer?.contentsGravity == .resizeAspect)
    }

    @Test func exportedSaverContainsLocalContentAndLoads() async throws {
        _ = NSApplication.shared
        let templatePath = try #require(ProcessInfo.processInfo.environment["WALLPAPER_SAVER_TEMPLATE"])
        let template = URL(fileURLWithPath: templatePath)
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = source.deletingLastPathComponent().appendingPathComponent("Test.saver")
        let item = Wallpaper(title: "Test", source: .localWeb(entry: source, root: nil))
        try SaverExport.write(item: item, template: template, destination: output)
        let html = output.appendingPathComponent("Contents/Resources/wallpaper.html")
        #expect(try Data(contentsOf: html) == Data(contentsOf: source))
        let bundle = try #require(Bundle(url: output))
        try bundle.loadAndReturnError()
        let viewClass = try #require(bundle.principalClass as? ScreenSaverView.Type)
        let view = try #require(viewClass.init(frame: CGRect(x: 0, y: 0, width: 320, height: 180), isPreview: true))
        view.startAnimation()
        #expect(view.isAnimating)
        #expect(view.subviews.count == 1)
        view.stopAnimation()
        #expect(!view.isAnimating)
    }

    private func scratchDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func fixture() throws -> URL {
        let source = try scratchDirectory().appendingPathComponent("test.html")
        try """
        <body style="margin:0;min-height:100vh;background:#234">
        <script>window.clicks=0; document.body.addEventListener('click', () => ++window.clicks);</script>
        </body>
        """.write(to: source, atomically: true, encoding: .utf8)
        return source
    }

    private func wait(until condition: () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(pixels.pixelBufferPool)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        if let bytes = CVPixelBufferGetBaseAddress(image) {
            memset(bytes, 155, CVPixelBufferGetDataSize(image))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        for frame in 0..<12 {
            await wait { input.isReadyForMoreMediaData }
            try #require(pixels.append(image, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}


@MainActor
private final class IsolatedClipboardEditor: NSTextView {
    let board = NSPasteboard.withUniqueName()

    override func copy(_ sender: Any?) {
        let selectedText = (string as NSString).substring(with: selectedRange())
        board.clearContents()
        board.setString(selectedText, forType: .string)
    }

    override func paste(_ sender: Any?) {
        if let text = board.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) { return board.string(forType: .string) != nil }
        return super.validateUserInterfaceItem(item)
    }
}
