import Foundation
import WallpaperCore

enum SaverExport {
    static func write(item: Wallpaper, template: URL, destination: URL) throws {
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(UUID().uuidString).saver", isDirectory: true)
        defer { try? files.removeItem(at: staging) }

        if case .localWeb(_, let root?) = item.source {
            let folder = root.resolvingSymlinksInPath().standardizedFileURL.path
            let target = parent.resolvingSymlinksInPath().standardizedFileURL.path
            guard target != folder && !target.hasPrefix(folder + "/") else {
                throw AppError("请选择网页素材文件夹以外的保存位置。")
            }
            let entries = files.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            while let url = entries?.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw AppError("屏保素材文件夹包含符号链接。请将链接替换为实际文件后再导出。")
                }
            }
        }

        try files.copyItem(at: template, to: staging)
        let resources = staging.appendingPathComponent("Contents/Resources", isDirectory: true)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        var configuration = ["fit": item.fit.rawValue]
        switch item.source {
        case .video(let url):
            let name = "video." + url.pathExtension
            try files.copyItem(at: url.resolvingSymlinksInPath(), to: resources.appendingPathComponent(name))
            configuration["kind"] = "video"
            configuration["entry"] = name
        case .image(let url):
            let name = "wallpaper." + url.pathExtension
            try files.copyItem(at: url.resolvingSymlinksInPath(), to: resources.appendingPathComponent(name))
            configuration["kind"] = "image"
            configuration["entry"] = name
        case .localWeb(let entry, let root):
            if let root {
                try files.copyItem(at: root.resolvingSymlinksInPath(), to: resources.appendingPathComponent("web", isDirectory: true))
                configuration["entry"] = "web/index.html"
                configuration["root"] = "web"
            } else {
                try files.copyItem(at: entry.resolvingSymlinksInPath(), to: resources.appendingPathComponent("wallpaper.html"))
                configuration["entry"] = "wallpaper.html"
            }
            configuration["kind"] = "web"
        case .remoteWeb:
            throw AppError("请选用本地视频或本地网页导出屏保。")
        }
        let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
        try data.write(to: resources.appendingPathComponent("Wallpaper.plist"), options: .atomic)

        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", staging.path]
        try signer.run()
        signer.waitUntilExit()
        guard signer.terminationStatus == 0 else { throw AppError("macOS 无法签名导出的屏保模块。") }

        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: destination)
        }
    }
}
