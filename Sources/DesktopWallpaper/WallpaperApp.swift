import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

@MainActor
final class WallpaperApp: NSObject, NSApplicationDelegate {
    private let model = ControlModel()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = EditingMenu.makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "动态壁纸")
        item.button?.toolTip = "动态壁纸"
        let menu = NSMenu()
        menu.delegate = self
        let commands: [(String, Selector, String)] = [
            ("打开动态壁纸", #selector(showSettings), ""),
            ("暂停播放", #selector(togglePause), ""),
            ("重载壁纸", #selector(reload), ""),
            ("退出", #selector(quit), "q")
        ]
        for (title, action, key) in commands {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item

        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) == nil {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginStatus() }
    func applicationWillTerminate(_ notification: Notification) { model.engine.stop() }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: ControlView(model: model, engine: model.engine)
            ))
            window.title = "动态壁纸"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 580))
            window.contentMinSize = NSSize(width: 680, height: 520)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func togglePause() { model.update { $0.manuallyPaused.toggle() } }
    @objc private func reload() { model.engine.reload() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension WallpaperApp: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(at: 1)?.title = model.settings.manuallyPaused ? "继续播放" : "暂停播放"
    }
}

enum GenerationSheet: String, Identifiable {
    case image, video
    var id: Self { self }
}

@MainActor
final class ControlModel: NSObject, ObservableObject, NSWindowDelegate {
    let engine = DesktopEngine()
    let generation = WallpaperGeneration()
    let videoGeneration: WallpaperVideoGeneration
    @Published private(set) var settings = EngineSettings()
    @Published var selectedID: UUID?
    @Published var urlSheet = false
    @Published var generationSheet: GenerationSheet?
    @Published var urlText = ""
    @Published var ruleDate = Date()
    @Published var chosenWallpaper: UUID?
    @Published var message: String?
    @Published private(set) var importing = false
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered

    private let file: SettingsFile
    private let generatedImages: GeneratedImageStore
    private var writable = true
    private var previewWindow: NSWindow?

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("DesktopWallpaper", isDirectory: true)) {
        file = SettingsFile(url: directory.appendingPathComponent("settings.json"))
        generatedImages = GeneratedImageStore(directory: directory.appendingPathComponent("Generated", isDirectory: true))
        videoGeneration = WallpaperVideoGeneration(directory: directory.appendingPathComponent("VideoDraft", isDirectory: true))
        super.init()
    }

    var selected: Wallpaper? { selectedID.flatMap(settings.wallpaper) }

    func start() {
        do {
            settings = try file.load()
            selectedID = settings.wallpapers.first?.id
        } catch {
            writable = false
            message = "设置读取失败。原始文件保留在 \(file.url.path)。\n\(error.localizedDescription)"
        }
        refreshLoginStatus()
        engine.start(with: settings)
    }

    func update(_ edit: (inout EngineSettings) -> Void) {
        do {
            try commit(edit)
        } catch {
            message = "保存失败。\n\(error.localizedDescription)"
        }
    }

    private func commit(_ edit: (inout EngineSettings) -> Void) throws {
        guard writable else {
            throw AppError("修复设置文件并重新启动后即可保存。\n\(file.url.path)")
        }
        var edited = settings
        edit(&edited)
        guard edited != settings else { return }
        try file.save(edited)
        settings = edited
        engine.update(edited)
    }

    func saveGenerated(_ preview: GeneratedWallpaperPreview, apply: Bool) throws {
        let url = try generatedImages.save(preview.png)
        try addGenerated(Wallpaper(title: preview.title, source: .image(url)), apply: apply)
    }

    func saveGeneratedVideo(_ preview: GeneratedVideoPreview, apply: Bool) throws {
        guard writable else { throw AppError("请先修复壁纸库设置，再保存生成的视频。") }
        let id = preview.task.wallpaperID
        if settings.wallpaper(id) != nil {
            if apply { try commit { $0.applyWallpaper(id) } }
            selectedID = id
            return
        }
        let directory = generatedImages.directory
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("mp4")
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        do {
            try files.copyItem(at: preview.url, to: url)
        } catch {
            try? files.removeItem(at: url)
            throw error
        }
        try addGenerated(Wallpaper(title: preview.task.title, source: .video(url), id: id), apply: apply)
    }

    private func addGenerated(_ item: Wallpaper, apply: Bool) throws {
        do {
            try commit { settings in
                settings.wallpapers.append(item)
                if apply { settings.applyWallpaper(item.id) }
            }
        } catch {
            try? FileManager.default.removeItem(at: item.source.url)
            throw error
        }
        selectedID = item.id
    }

    func changeWallpaper(_ id: UUID, _ edit: (inout Wallpaper) -> Void) {
        update { settings in
            if let index = settings.wallpapers.firstIndex(where: { $0.id == id }) {
                edit(&settings.wallpapers[index])
            }
        }
    }

    func remove(_ id: UUID) {
        update { $0.removeWallpaper(id) }
        if settings.wallpaper(id) == nil && selectedID == id { selectedID = settings.wallpapers.first?.id }
    }

    func addLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .html, .jpeg, .png]
        if let alternateJPEG = UTType(filenameExtension: "jepg") {
            panel.allowedContentTypes.append(alternateJPEG)
        }
        panel.prompt = "导入"
        panel.message = "选择 JPG、JPEG、PNG 图片、视频、HTML 文件，或包含 index.html 的网页文件夹。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let source: WallpaperSource
                if directory {
                    let entry = url.appendingPathComponent("index.html")
                    let resolvedRoot = url.resolvingSymlinksInPath().path
                    guard entry.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/"),
                          FileManager.default.isReadableFile(atPath: entry.path),
                          try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw AppError("文件夹中需要有可读取的 index.html。")
                    }
                    source = .localWeb(entry: entry, root: url)
                } else if ["html", "htm"].contains(url.pathExtension.lowercased()) {
                    source = .localWeb(entry: url, root: nil)
                } else if ["jpg", "jpeg", "jepg", "png"].contains(url.pathExtension.lowercased()) {
                    guard loadWallpaperImage(url) != nil else {
                        throw AppError("无法读取图片。请选择有效的 JPEG 或 PNG 文件。")
                    }
                    source = .image(url)
                } else {
                    try await PlayableVideo.check(url)
                    source = .video(url)
                }
                add(source, title: directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
            } catch {
                message = "导入失败。\n\(error.localizedDescription)"
            }
        }
    }

    func addRemote(_ value: String) {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            message = "请输入有效的 HTTP 或 HTTPS 地址。"
            return
        }
        add(.remoteWeb(url), title: host)
    }

    func addDemo() {
        guard let url = Bundle.main.url(forResource: "Demo", withExtension: "html") else {
            message = "找不到内置演示，请通过打包后的 .app 启动。"
            return
        }
        add(.localWeb(entry: url, root: nil), title: "极光演示", interactive: true)
    }

    private func add(_ source: WallpaperSource, title: String, interactive: Bool = false) {
        if let existing = settings.wallpapers.first(where: { $0.source == source }) {
            selectedID = existing.id
            return
        }
        var item = Wallpaper(title: title, source: source)
        item.interactive = interactive
        update { $0.wallpapers.append(item) }
        if settings.wallpaper(item.id) != nil { selectedID = item.id }
    }

    func addApplicationRule(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "添加规则"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            message = "无法读取这个应用的标识。"
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
        update { settings in
            settings.apps.removeAll { $0.bundleID == bundleID }
            settings.apps.append(ApplicationRule(bundleID: bundleID, name: name, wallpaperID: id))
        }
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "登录自启设置失败。\n\(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    func preview(_ item: Wallpaper) {
        previewWindow?.close()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 405),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "预览 · \(item.title)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let view: NSView
        let onError: (String) -> Void = { [weak self] in self?.message = $0 }
        switch item.source {
        case .video(let url):
            let video = VideoView(url: url, clock: nil, onReady: {}, onError: onError)
            video.update(fit: item.fit, volume: item.volume, playing: true)
            view = video
        case .image(let url):
            guard let image = StaticImageView(url: url, fit: item.fit) else {
                message = "无法读取壁纸图片。"
                return
            }
            view = image
        case .localWeb, .remoteWeb:
            view = WebView(source: item.source, onReady: {}, onError: onError)
        }
        window.contentView = view
        window.center()
        previewWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === previewWindow {
            window.contentView = nil
            previewWindow = nil
        }
    }

    func exportSaver(_ item: Wallpaper) {
        guard let template = Bundle.main.url(forResource: "WallpaperSaver", withExtension: "saver") else {
            message = "找不到屏保模板，请通过打包后的 .app 启动。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "saver") ?? .bundle]
        panel.nameFieldStringValue = "DesktopWallpaper.saver"
        panel.prompt = "导出屏保"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SaverExport.write(item: item, template: template, destination: url)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                message = "屏保导出失败。\n\(error.localizedDescription)"
            }
        }
    }
}

struct AppError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
