import Foundation
import Security

import WallpaperCore

enum ImageGenerationKeychain {
    static func service(for target: ImageGenerationTarget) -> String {
        switch target {
        case .openAI: "local.desktopwallpaper.engine.openai"
        case .qwenBeijing: "local.desktopwallpaper.engine.qwen.beijing"
        case .qwenSingapore: "local.desktopwallpaper.engine.qwen.singapore"
        }
    }

    private static func item(for target: ImageGenerationTarget) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: target),
            kSecAttrAccount as String: "image-generation"
        ]
    }

    static func containsKey(for target: ImageGenerationTarget) throws -> Bool {
        let status = SecItemCopyMatching(item(for: target) as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    static func load(for target: ImageGenerationTarget) throws -> String? {
        var query = item(for: target)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AppError("无法读取已保存的 API 密钥。请更换密钥。")
        }
        return key
    }

    static func save(_ key: String, for target: ImageGenerationTarget) throws {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let query = item(for: target)
        var entry = query
        entry[kSecAttrLabel as String] = "DesktopWallpaper \(target.model) API Key"
        entry.merge(attributes) { _, new in new }
        let status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
        } else {
            try check(status)
        }
    }

    static func remove(for target: ImageGenerationTarget) throws {
        let status = SecItemDelete(item(for: target) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
            throw AppError("无法访问 macOS 钥匙串。\n\(detail)")
        }
    }
}
