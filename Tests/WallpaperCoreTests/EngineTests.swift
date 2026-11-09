import CoreGraphics
import Foundation
import Testing
@testable import WallpaperCore

struct EngineTests {
    private let first = Wallpaper(title: "First", source: .remoteWeb(URL(string: "https://example.com/first")!))
    private let second = Wallpaper(title: "Second", source: .remoteWeb(URL(string: "https://example.com/second")!))
    private let third = Wallpaper(title: "Third", source: .remoteWeb(URL(string: "https://example.com/third")!))
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let midnight = Date(timeIntervalSince1970: 0)

    @Test func testForegroundRuleTakesPrecedenceOverTimeAndPlaylist() {
        var settings = EngineSettings()
        settings.wallpapers = [first, second, third]
        settings.playlist = [first.id]
        settings.schedule = [ScheduleRule(minute: 0, wallpaperID: second.id)]
        settings.apps = [ApplicationRule(bundleID: "com.example.player", name: "Player", wallpaperID: third.id)]
        #expect(settings.resolve(.automatic, at: midnight, frontmost: "com.example.player", calendar: utc) == third)
        #expect(settings.resolve(.automatic, at: midnight, frontmost: nil, calendar: utc) == second)
        #expect(settings.resolve(.wallpaper(first.id), at: midnight, frontmost: "com.example.player", calendar: utc) == first)
    }

    @Test func testScheduleUsesPreviousEveningBeforeFirstSlot() {
        var settings = EngineSettings()
        settings.wallpapers = [first, second]
        settings.schedule = [
            ScheduleRule(minute: 20 * 60, wallpaperID: second.id),
            ScheduleRule(minute: 8 * 60, wallpaperID: first.id)
        ]
        #expect(settings.resolve(.automatic, at: midnight, frontmost: nil, calendar: utc) == second)
        #expect(settings.resolve(.automatic, at: midnight.addingTimeInterval(8 * 3600), frontmost: nil, calendar: utc) == first)
    }

    @Test func testPlaylistSkipsStaleIDsAndLoopsFromSavedStart() {
        var settings = EngineSettings()
        settings.wallpapers = [first, second]
        settings.playlist = [first.id, third.id, second.id]
        settings.playlistStart = midnight
        settings.intervalSeconds = 60
        #expect(settings.resolve(.automatic, at: midnight.addingTimeInterval(60), frontmost: nil, calendar: utc) == second)
        #expect(settings.resolve(.automatic, at: midnight.addingTimeInterval(120), frontmost: nil, calendar: utc) == first)
    }

    @Test func testDailySlotCanReturnToPlaylist() {
        var settings = EngineSettings()
        settings.wallpapers = [first, second]
        settings.playlist = [first.id]
        settings.schedule = [
            ScheduleRule(minute: 8 * 60, wallpaperID: second.id),
            ScheduleRule(minute: 20 * 60, wallpaperID: nil)
        ]
        #expect(settings.resolve(.automatic, at: midnight, frontmost: nil, calendar: utc) == first)
        #expect(settings.resolve(.automatic, at: midnight.addingTimeInterval(8 * 3600), frontmost: nil, calendar: utc) == second)
    }

    @Test func testDisplayOverridesDefaultOnlyInIndependentMode() {
        var settings = EngineSettings()
        settings.defaultAssignment = .wallpaper(first.id)
        settings.displayAssignments = ["external": .off]
        settings.spanAssignment = .wallpaper(second.id)
        #expect(settings.assignment(for: "external") == .off)
        #expect(settings.assignment(for: "new") == .wallpaper(first.id))
        settings.layout = .span
        #expect(settings.assignment(for: "external") == .wallpaper(second.id))
    }

    @Test func testRemovingWallpaperClearsEveryReferenceToIt() {
        var settings = EngineSettings()
        settings.wallpapers = [first, second]
        settings.defaultAssignment = .wallpaper(first.id)
        settings.spanAssignment = .wallpaper(first.id)
        settings.displayAssignments = ["external": .wallpaper(first.id), "built-in": .wallpaper(second.id)]
        settings.playlist = [first.id, second.id, first.id]
        settings.schedule = [ScheduleRule(minute: 0, wallpaperID: first.id)]
        settings.apps = [ApplicationRule(bundleID: "test", name: "Test", wallpaperID: first.id)]
        settings.removeWallpaper(first.id)
        #expect(settings.wallpapers == [second])
        #expect(settings.defaultAssignment == .off)
        #expect(settings.spanAssignment == .off)
        #expect(settings.displayAssignments == ["built-in": .wallpaper(second.id)])
        #expect(settings.playlist == [second.id])
        #expect(settings.schedule.isEmpty)
        #expect(settings.apps.isEmpty)
    }

    @Test func testSpanViewportUsesGlobalOffsetsInAppKitCoordinates() {
        let left = CGRect(x: -1280, y: 180, width: 1280, height: 800)
        let right = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let canvas = left.union(right)
        #expect(Layout.viewport(for: left, canvas: canvas) == CGRect(x: 0, y: -180, width: 3200, height: 1080))
        #expect(Layout.viewport(for: right, canvas: canvas) == CGRect(x: -1280, y: 0, width: 3200, height: 1080))
    }

    @Test func testFullscreenNeedsToCoverAllFourDisplayEdges() {
        let display = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        #expect(Layout.isFullscreen(window: display, display: display))
        #expect(Layout.isFullscreen(window: CGRect(x: -1279, y: 1, width: 1278, height: 798), display: display))
        #expect(!Layout.isFullscreen(window: CGRect(x: -1280, y: 25, width: 1280, height: 775), display: display))
        #expect(!Layout.isFullscreen(window: CGRect(x: -2560, y: 0, width: 1280, height: 800), display: display))
    }

    @Test func testSettingsPersistAndCorruptSettingsAreReported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SettingsFile(url: directory.appendingPathComponent("settings.json"))
        var settings = EngineSettings()
        settings.wallpapers = [first, second]
        settings.defaultAssignment = .wallpaper(first.id)
        settings.spanAssignment = .automatic
        settings.playlistStart = midnight
        try file.save(settings)
        #expect(try file.load() == settings)
        try Data("invalid JSON".utf8).write(to: file.url)
        #expect(throws: (any Error).self) { try file.load() }
    }

    @Test func testSingleHTMLFileDoesNotGrantReadAccessToItsParent() {
        let html = URL(fileURLWithPath: "/tmp/other-private-files/wallpaper.html")
        let folder = URL(fileURLWithPath: "/tmp/other-private-files", isDirectory: true)
        #expect(WallpaperSource.localWeb(entry: html, root: nil).webReadAccess == html)
        #expect(WallpaperSource.localWeb(entry: html, root: folder).webReadAccess == folder)
    }
}
