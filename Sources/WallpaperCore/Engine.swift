import CoreGraphics
import Foundation

public enum WallpaperSource: Codable, Equatable, Sendable {
    case video(URL)
    case image(URL)
    case localWeb(entry: URL, root: URL?)
    case remoteWeb(URL)

    public var url: URL {
        switch self {
        case .video(let url), .image(let url), .localWeb(let url, _), .remoteWeb(let url):
            return url
        }
    }

    public var webReadAccess: URL? {
        guard case .localWeb(let entry, let root) = self else { return nil }
        return root ?? entry
    }
}

public enum VideoFit: String, Codable, CaseIterable, Identifiable, Sendable {
    case fill, fit
    public var id: Self { self }
}

public struct Wallpaper: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let source: WallpaperSource
    public var fit: VideoFit
    public var volume: Double
    public var interactive: Bool

    public init(title: String, source: WallpaperSource, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.source = source
        self.fit = .fill
        self.volume = 0
        self.interactive = false
    }
}

public enum Assignment: Codable, Hashable, Sendable {
    case off
    case wallpaper(UUID)
    case automatic
}

public enum DisplayLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case independent, span
    public var id: Self { self }
}

public struct ScheduleRule: Codable, Equatable, Identifiable, Sendable {
    public let minute: Int
    public let wallpaperID: UUID?
    public var id: Int { minute }

    public init(minute: Int, wallpaperID: UUID?) {
        self.minute = minute
        self.wallpaperID = wallpaperID
    }
}

public struct ApplicationRule: Codable, Equatable, Identifiable, Sendable {
    public let bundleID: String
    public let name: String
    public let wallpaperID: UUID
    public var id: String { bundleID }

    public init(bundleID: String, name: String, wallpaperID: UUID) {
        self.bundleID = bundleID
        self.name = name
        self.wallpaperID = wallpaperID
    }
}

public struct EngineSettings: Codable, Equatable, Sendable {
    public var wallpapers: [Wallpaper] = []
    public var layout: DisplayLayout = .independent
    public var defaultAssignment: Assignment = .off
    public var displayAssignments: [String: Assignment] = [:]
    public var spanAssignment: Assignment = .off
    public var playlist: [UUID] = []
    public var playlistStart = Date()
    public var intervalSeconds = 300
    public var schedule: [ScheduleRule] = []
    public var apps: [ApplicationRule] = []
    public var pauseOnFullscreen = true
    public var pauseOnBattery = false
    public var manuallyPaused = false

    public init() {}

    public func assignment(for displayID: String) -> Assignment {
        if layout == .span { return spanAssignment }
        return displayAssignments[displayID] ?? defaultAssignment
    }

    public func wallpaper(_ id: UUID) -> Wallpaper? {
        wallpapers.first { $0.id == id }
    }

    public func resolve(
        _ assignment: Assignment,
        at date: Date,
        frontmost: String?,
        calendar: Calendar = .current
    ) -> Wallpaper? {
        switch assignment {
        case .off:
            return nil
        case .wallpaper(let id):
            return wallpaper(id)
        case .automatic:
            if let frontmost, let rule = apps.first(where: { $0.bundleID == frontmost }),
               let item = wallpaper(rule.wallpaperID) {
                return item
            }

            let clock = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
            let availableRules = schedule.filter { rule in
                (0..<1440).contains(rule.minute) && (rule.wallpaperID.map { wallpaper($0) != nil } ?? true)
            }
            let current = availableRules.filter { $0.minute <= minute }.max { $0.minute < $1.minute }
            if let rule = current ?? availableRules.max(by: { $0.minute < $1.minute }),
               let id = rule.wallpaperID {
                return wallpaper(id)
            }

            let items = playlist.compactMap { wallpaper($0) }
            guard !items.isEmpty else { return nil }
            let elapsed = max(0, date.timeIntervalSince(playlistStart))
            let duration = Double(max(1, intervalSeconds))
            let position = elapsed.truncatingRemainder(dividingBy: duration * Double(items.count))
            return items[Int(position / duration)]
        }
    }

    public mutating func applyWallpaper(_ id: UUID) {
        if layout == .span {
            spanAssignment = .wallpaper(id)
        } else {
            defaultAssignment = .wallpaper(id)
            displayAssignments.removeAll()
        }
    }

    public mutating func removeWallpaper(_ id: UUID) {
        wallpapers.removeAll { $0.id == id }
        if defaultAssignment == .wallpaper(id) { defaultAssignment = .off }
        if spanAssignment == .wallpaper(id) { spanAssignment = .off }
        displayAssignments = displayAssignments.filter { $0.value != .wallpaper(id) }
        playlist.removeAll { $0 == id }
        schedule.removeAll { $0.wallpaperID == id }
        apps.removeAll { $0.wallpaperID == id }
    }
}

public enum Layout {
    public static func viewport(for display: CGRect, canvas: CGRect) -> CGRect {
        CGRect(x: canvas.minX - display.minX, y: canvas.minY - display.minY,
               width: canvas.width, height: canvas.height)
    }

    public static func isFullscreen(window: CGRect, display: CGRect) -> Bool {
        window.insetBy(dx: -2, dy: -2).contains(display)
    }
}

public struct SettingsFile {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> EngineSettings {
        do {
            return try JSONDecoder().decode(EngineSettings.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return EngineSettings()
        }
    }

    public func save(_ settings: EngineSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
