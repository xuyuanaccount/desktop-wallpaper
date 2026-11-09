import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageGenerationTarget: String, CaseIterable, Identifiable, Sendable {
    case openAI, qwenBeijing, qwenSingapore

    public var id: Self { self }

    public var model: String {
        self == .openAI ? "gpt-image-2.6-flare" : "qwen-image-3.0-pro"
    }

    fileprivate var endpoint: URL {
        switch self {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/images/generations")!
        case .qwenBeijing:
            return DashScopeRegion.beijing.endpoint("services/aigc/multimodal-generation/generation")
        case .qwenSingapore:
            return DashScopeRegion.singapore.endpoint("services/aigc/multimodal-generation/generation")
        }
    }
}

public enum WallpaperImageSize: String, CaseIterable, Identifiable, Sendable {
    case desktop = "1536x864"
    case macBook = "1536x960"
    case ultrawide = "1792x768"
    case portrait = "864x1536"

    public var id: Self { self }
}

public enum WallpaperImageQuality: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    public var id: Self { self }
}

public enum ImageGenerationError: LocalizedError, Equatable {
    case emptyPrompt
    case missingKey
    case invalidResponse
    case invalidImage
    case imageDownloadFailed
    case service(status: Int, code: String?)
    case qwen(status: Int, code: String?)

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "请输入壁纸描述。"
        case .missingKey:
            return "请输入有效的 API 密钥。"
        case .invalidResponse:
            return "图片服务没有返回可读取的生成结果。"
        case .invalidImage:
            return "生成结果不是有效的 PNG 图片。"
        case .imageDownloadFailed:
            return "无法下载千问生成的图片。请检查网络后重试。"
        case .qwen(let status, let code):
            switch (status, code) {
            case (401, _), (_, "InvalidApiKey"):
                return "阿里云百炼拒绝了密钥。请确认密钥与所选地域一致。"
            case (_, "Arrearage"), (_, "AccountOverdue"):
                return "阿里云百炼账户余额不足。请检查计费设置。"
            case (_, "DataInspectionFailed"):
                return "这段描述无法生成图片。请修改后重试。"
            case (403, _), (404, _):
                return "当前百炼项目无法调用千问图片模型。请检查模型权限和地域。"
            case (429, _):
                return "阿里云百炼暂时限制了请求频率。请稍后再试。"
            case (500...599, _):
                return "阿里云百炼图片服务暂时不可用。请稍后再试。"
            default:
                return "千问图片请求失败（HTTP \(status)）。请检查描述和百炼项目设置。"
            }
        case .service(let status, let code):
            switch (status, code) {
            case (401, _):
                return "OpenAI 拒绝了密钥。请检查密钥或在这里更换。"
            case (403, _), (404, _):
                return "这个 API 项目无法使用图片模型。请检查项目权限和组织验证状态。"
            case (429, "insufficient_quota"):
                return "API 额度不足。请检查 OpenAI API 项目的计费设置。"
            case (429, _):
                return "OpenAI 暂时限制了请求频率。请稍后再试。"
            case (400, "content_policy_violation"), (400, "moderation_blocked"):
                return "这段描述无法生成图片。请修改后重试。"
            case (400, _):
                return "OpenAI 拒绝了生成参数。请尝试调整描述、比例或画质。"
            case (500...599, _):
                return "OpenAI 图片服务暂时不可用。请稍后再试。"
            default:
                return "OpenAI 图片请求失败（HTTP \(status)）。"
            }
        }
    }
}

public struct ImageGenerationClient {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 240
            configuration.timeoutIntervalForResource = 620
            self.session = URLSession(configuration: configuration)
        }
    }

    public func generate(
        prompt: String, size: WallpaperImageSize, quality: WallpaperImageQuality, key: String,
        target: ImageGenerationTarget = .openAI
    ) async throws -> Data {
        let request = try Self.request(prompt: prompt, size: size, quality: quality, key: key, target: target)
        let redirects = target == .openAI ? nil : DenyRedirects()
        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard let response = response as? HTTPURLResponse else { throw ImageGenerationError.invalidResponse }
        if target == .openAI {
            return try Self.decode(data, status: response.statusCode)
        }

        let imageURL = try Self.qwenImageURL(data, status: response.statusCode)
        try Task.checkCancellation()
        // The signed OSS URL authenticates the download by itself.
        let (png, downloadResponse) = try await session.data(from: imageURL, delegate: redirects)
        guard let download = downloadResponse as? HTTPURLResponse, (200..<300).contains(download.statusCode) else {
            throw ImageGenerationError.imageDownloadFailed
        }
        try Self.validatePNG(png)
        return png
    }

    static func request(
        prompt: String, size: WallpaperImageSize, quality: WallpaperImageQuality, key: String,
        target: ImageGenerationTarget = .openAI
    ) throws -> URLRequest {
        let description = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw ImageGenerationError.emptyPrompt }
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { throw ImageGenerationError.missingKey }

        var request = URLRequest(url: target.endpoint)
        request.timeoutInterval = target == .openAI ? 240 : 600
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if target == .openAI {
            request.httpBody = try JSONEncoder().encode([
                "model": target.model,
                "prompt": description,
                "size": size.rawValue,
                "quality": quality.rawValue,
                "output_format": "png",
                "background": "opaque"
            ])
        } else {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": target.model,
                "input": ["messages": [["role": "user", "content": [["text": description]]]]],
                "parameters": ["size": size.rawValue.replacingOccurrences(of: "x", with: "*"), "n": 1]
            ])
        }
        return request
    }

    static func qwenImageURL(_ data: Data, status: Int) throws -> URL {
        let decoder = JSONDecoder()
        let code = (try? decoder.decode(QwenError.self, from: data))?.code
        if !(200..<300).contains(status) || code?.isEmpty == false {
            throw ImageGenerationError.qwen(status: status, code: code)
        }

        guard let result = try? decoder.decode(QwenResponse.self, from: data),
              let url = result.output.choices.first?.message.content.compactMap(\.image).first,
              DashScope.isSignedResultURL(url) else { throw ImageGenerationError.invalidResponse }
        return url
    }

    static func decode(_ data: Data, status: Int) throws -> Data {
        let decoder = JSONDecoder()
        guard (200..<300).contains(status) else {
            let response = try? decoder.decode(ServiceError.self, from: data)
            throw ImageGenerationError.service(status: status, code: response?.error.code)
        }
        guard let response = try? decoder.decode(Response.self, from: data),
              let result = response.data.first,
              let png = Data(base64Encoded: result.b64_json) else { throw ImageGenerationError.invalidResponse }
        try validatePNG(png)
        return png
    }

    static func validatePNG(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ImageGenerationError.invalidImage
        }
    }

    private struct QwenResponse: Decodable {
        struct Output: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    struct Content: Decodable { let image: URL? }
                    let content: [Content]
                }
                let message: Message
            }
            let choices: [Choice]
        }
        let output: Output
    }

    private struct QwenError: Decodable { let code: String? }

    private struct Response: Decodable {
        struct Image: Decodable { let b64_json: String }
        let data: [Image]
    }

    private struct ServiceError: Decodable {
        struct Detail: Decodable { let code: String? }
        let error: Detail
    }
}

public struct GeneratedImageStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func save(_ png: Data) throws -> URL {
        try ImageGenerationClient.validatePNG(png)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try png.write(to: url, options: .atomic)
        return url
    }
}
