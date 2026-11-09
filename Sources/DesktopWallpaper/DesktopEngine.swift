import AppKit
import IOKit.ps
import WallpaperCore

struct Display: Equatable, Identifiable {
    let id: String
    let name: String
    let frame: CGRect
    let quartzFrame: CGRect

    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = number.uint32Value
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            id = CFUUIDCreateString(nil, uuid) as String
        } else {
            id = String(displayID)
        }
        name = screen.localizedName
        frame = screen.frame
        quartzFrame = CGDisplayBounds(displayID)
    }
}

private struct VisibleWindow {
    let bounds: CGRect
    let level: Int

    static func all() -> [Self] {
        let dictionaries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return dictionaries.compactMap { window in
            guard let level = window[kCGWindowLayer as String] as? Int,
                  level >= Int(CGWindowLevelForKey(.normalWindow)),
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let values = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: values as CFDictionary),
                  !bounds.isEmpty else { return nil }
            return Self(bounds: bounds, level: level)
        }
    }
}

@MainActor
final class DesktopEngine: ObservableObject {
    @Published private(set) var displays: [Display] = []
    @Published private(set) var status = "桌面壁纸未启用"
    @Published private(set) var issues: [UUID: String] = [:]

    private var settings = EngineSettings()
    private var surfaces: [String: DesktopSurface] = [:]
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var mouseMonitor: Any?
    private weak var pointerSurface: DesktopSurface?
    private var lastMouseMove = 0.0
    private var spanClock: VideoClock?
    private var spanWallpaperID: UUID?
    private var lastExternalBundle: String?
    private var screenSleeping = false
    private var sessionInactive = false
    private var systemSleeping = false

    func start(with settings: EngineSettings) {
        self.settings = settings
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didChangeScreenParametersNotification, in: .default) { $0.refresh() }
        observe(NSWorkspace.didActivateApplicationNotification, in: workspace) { $0.refresh() }
        observe(NSWorkspace.screensDidSleepNotification, in: workspace) { $0.screenSleeping = true; $0.refresh() }
        observe(NSWorkspace.screensDidWakeNotification, in: workspace) { $0.screenSleeping = false; $0.refresh() }
        observe(NSWorkspace.sessionDidResignActiveNotification, in: workspace) { $0.sessionInactive = true; $0.refresh() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, in: workspace) { $0.sessionInactive = false; $0.refresh() }
        observe(NSWorkspace.willSleepNotification, in: workspace) { $0.systemSleeping = true; $0.refresh() }
        observe(NSWorkspace.didWakeNotification, in: workspace) { $0.systemSleeping = false; $0.refresh() }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
    }

    func update(_ settings: EngineSettings) {
        if settings.layout != self.settings.layout { closeSurfaces() }
        self.settings = settings
        let validIDs = Set(settings.wallpapers.map(\.id))
        if issues.keys.contains(where: { !validIDs.contains($0) }) {
            issues = issues.filter { validIDs.contains($0.key) }
        }
        refresh()
    }

    func reload() {
        closeSurfaces()
        issues = [:]
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        closeSurfaces()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter, perform: @escaping (DesktopEngine) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { perform(self) }
            }
        }
        observers.append((center, observer))
    }

    private func closeSurfaces() {
        for surface in surfaces.values { surface.close() }
        surfaces.removeAll()
        spanClock = nil
        spanWallpaperID = nil
    }

    private func refresh() {
        let screens = NSScreen.screens.compactMap(Display.init)
        if displays != screens { displays = screens }
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalBundle = application.bundleIdentifier
        }

        let now = Date()
        let assignments: [(Display, Wallpaper)] = screens.compactMap { screen in
            guard let item = settings.resolve(settings.assignment(for: screen.id), at: now, frontmost: lastExternalBundle) else { return nil }
            if item.source.url.isFileURL && !FileManager.default.isReadableFile(atPath: item.source.url.path) {
                setIssue("找不到壁纸文件或没有读取权限。", for: item.id)
                return nil
            }
            return (screen, item)
        }
        let connectedIDs = Set(assignments.map { $0.0.id })
        for id in Array(surfaces.keys) where !connectedIDs.contains(id) {
            surfaces.removeValue(forKey: id)?.close()
        }

        let globalPause = settings.manuallyPaused || screenSleeping || systemSleeping || sessionInactive ||
            (settings.pauseOnBattery && Self.onBattery)
        let fullscreen: Set<String>
        if settings.pauseOnFullscreen && !globalPause && !assignments.isEmpty {
            let normal = Int(CGWindowLevelForKey(.normalWindow))
            let windows = VisibleWindow.all().filter { $0.level == normal }
            fullscreen = Set(screens.filter { display in
                windows.contains { Layout.isFullscreen(window: $0.bounds, display: display.quartzFrame) }
            }.map(\.id))
        } else {
            fullscreen = []
        }
        let spanning = settings.layout == .span
        let spanPaused = globalPause || !fullscreen.isEmpty
        let span = spanning ? screens.reduce(CGRect.null) { $0.union($1.frame) } : .null
        if spanning && spanWallpaperID != assignments.first?.1.id {
            spanWallpaperID = assignments.first?.1.id
            spanClock = spanWallpaperID == nil ? nil : VideoClock()
        }
        spanClock?.setPaused(spanPaused)

        var activeCount = 0
        for (index, (display, item)) in assignments.enumerated() {
            if surfaces[display.id]?.wallpaper.id != item.id {
                surfaces.removeValue(forKey: display.id)?.close()
                setIssue(nil, for: item.id)
                surfaces[display.id] = DesktopSurface(wallpaper: item, displayFrame: display.frame,
                                                       clock: spanClock, onError: { [weak self] message in
                    self?.setIssue(message, for: item.id)
                })
            }
            let paused = spanning ? spanPaused : globalPause || fullscreen.contains(display.id)
            if !paused { activeCount += 1 }
            surfaces[display.id]?.update(wallpaper: item, displayFrame: display.frame, canvas: spanning ? span : display.frame,
                                         paused: paused, audio: !spanning || index == 0)
        }

        let text: String
        if assignments.isEmpty { text = "桌面壁纸未启用" }
        else if activeCount == 0 { text = "播放已暂停" }
        else if activeCount < assignments.count { text = "\(activeCount) 个显示器播放中，其余暂停" }
        else { text = "\(activeCount) 个显示器播放中" }
        if status != text { status = text }
        updateMouseMonitor(enabled: assignments.contains { $0.1.interactive })
    }

    private func setIssue(_ message: String?, for id: UUID) {
        if issues[id] != message { issues[id] = message }
    }

    private func updateMouseMonitor(enabled: Bool) {
        if !enabled {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            pointerSurface = nil
        } else if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.relayPointer(event) }
            }
        }
    }

    private func relayPointer(_ event: NSEvent) {
        let action: DesktopPointer
        switch event.type {
        case .leftMouseDown: action = .down
        case .leftMouseUp: action = .up
        default:
            guard event.timestamp - lastMouseMove >= 1.0 / 24 else { return }
            lastMouseMove = event.timestamp
            action = .move
        }
        let point = NSEvent.mouseLocation
        guard let top = NSScreen.screens.first?.frame.maxY else { return }
        let quartzPoint = CGPoint(x: point.x, y: top - point.y)
        var target = surfaces.values.first { $0.interactive && $0.displayFrame.contains(point) }
        if target != nil && VisibleWindow.all().contains(where: { $0.bounds.contains(quartzPoint) }) {
            target = nil
        }
        if settings.layout == .span {
            if target != nil {
                for surface in surfaces.values where surface.interactive { surface.sendPointer(action, at: point) }
            } else if pointerSurface != nil {
                for surface in surfaces.values where surface.interactive { surface.sendPointer(.leave, at: point) }
            }
        } else {
            if pointerSurface !== target { pointerSurface?.sendPointer(.leave, at: point) }
            target?.sendPointer(action, at: point)
        }
        pointerSurface = target
    }

    private static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
