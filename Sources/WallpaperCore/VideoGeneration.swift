import Foundation

public enum WallpaperVideoResolution: String, CaseIterable, Identifiable, Sendable {
    case hd = "720P"
    case fullHD = "1080P"
    public var id: Self { self }
}

public enum WallpaperVideoRatio: String, CaseIterable, Identifiable, Sendable {
    case landscape = "16:9"
    case portrait = "9:16"
    case square = "1:1"
    case classicLandscape = "4:3"
    case classicPortrait = "3:4"
    public var id: Self { self }
}

public enum VideoTaskState: Equatable, Sendable {
    case pending, running, succeeded(URL)
}

public enum VideoGenerationError: LocalizedError, Equatable {
    case invalidDuration, invalidResponse, downloadFailed, timedOut, taskUnavailable, taskCanceled
    case taskFailed(String?)
    case service(status: Int, code: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidDuration: "请选择 2–15 秒的视频时长。"
        case .invalidResponse: "百炼没有返回可识别的视频任务结果。"
        case .downloadFailed: "视频已生成，但下载失败。可继续查询并重新下载。"
        case .timedOut: "本轮查询已超时。可继续查询原任务。"
        case .taskUnavailable: "百炼任务已过期或找不到。"
        case .taskCanceled: "百炼任务已取消。"
        case .taskFailed("DataInspectionFailed"), .taskFailed("IPInfringementSuspect"):
            "这段描述无法生成视频。请修改后重试。"
        case .taskFailed: "百炼视频生成任务失败。"
        case .service(401, _), .service(_, "InvalidApiKey"):
            "百炼拒绝了密钥。请确认密钥与所选地域一致。"
        case .service(_, "Arrearage"), .service(_, "AccountOverdue"):
            "百炼账户余额不足。请检查计费设置。"
        case .service(403, _), .service(404, _):
            "无法访问百炼视频服务。请检查地域和项目的模型权限。"
        case .service(429, _): "百炼暂时限制了请求频率。请稍后再试。"
        case .service(500...599, _): "百炼视频服务暂时不可用。"
        case .service(let status, _): "百炼视频请求失败（HTTP \(status)）。"
        }
    }

    public var isTerminalTask: Bool {
        switch self {
        case .taskFailed, .taskCanceled, .taskUnavailable: true
        default: false
        }
    }
}

public struct WanVideoClient {
    public static let model = "wan2.7-t2v"
    private let session: URLSession
    private let pollInterval: Duration

    public init(session: URLSession? = nil, pollInterval: Duration = .seconds(15)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        self.session = session ?? URLSession(configuration: configuration)
        self.pollInterval = pollInterval
    }

    public func submit(
        prompt: String, resolution: WallpaperVideoResolution, ratio: WallpaperVideoRatio,
        duration: Int, region: DashScopeRegion, key: String
    ) async throws -> String {
        let request = try Self.submission(prompt: prompt, resolution: resolution, ratio: ratio,
                                          duration: duration, region: region, key: key)
        let (data, status) = try await send(request)
        let output = try Self.decode(data, status: status)
        guard let id = output.task_id, Self.isValidTaskID(id) else { throw VideoGenerationError.invalidResponse }
        return id
    }

    public func waitForResult(
        taskID: String, region: DashScopeRegion, key: String,
        progress: @MainActor (VideoTaskState) -> Void
    ) async throws -> URL {
        guard Self.isValidTaskID(taskID) else { throw VideoGenerationError.invalidResponse }
        let request = try Self.authorizedRequest(region.endpoint("tasks/\(taskID)"), key: key)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(900))
        while clock.now < deadline {
            try Task.checkCancellation()
            let (data, status) = try await send(request)
            let state = try Self.taskState(data, status: status, expectedID: taskID)
            if case .succeeded(let url) = state { return url }
            await progress(state)
            try await Task.sleep(for: pollInterval)
        }
        throw VideoGenerationError.timedOut
    }

    public func download(_ url: URL, to destination: URL) async throws {
        guard DashScope.isSignedResultURL(url) else { throw VideoGenerationError.invalidResponse }
        let (file, response) = try await session.download(from: url, delegate: DenyRedirects())
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VideoGenerationError.downloadFailed
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    static func submission(
        prompt: String, resolution: WallpaperVideoResolution, ratio: WallpaperVideoRatio,
        duration: Int, region: DashScopeRegion, key: String
    ) throws -> URLRequest {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImageGenerationError.emptyPrompt }
        guard (2...15).contains(duration) else { throw VideoGenerationError.invalidDuration }
        var request = try authorizedRequest(region.endpoint("services/aigc/video-generation/video-synthesis"), key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": ["prompt": text],
            "parameters": ["resolution": resolution.rawValue, "ratio": ratio.rawValue, "duration": duration]
        ])
        return request
    }

    static func taskState(_ data: Data, status: Int, expectedID: String) throws -> VideoTaskState {
        let output = try decode(data, status: status)
        guard output.task_id == expectedID else { throw VideoGenerationError.invalidResponse }
        switch output.task_status {
        case "PENDING": return .pending
        case "RUNNING": return .running
        case "SUCCEEDED":
            guard let url = output.video_url, DashScope.isSignedResultURL(url) else {
                throw VideoGenerationError.invalidResponse
            }
            return .succeeded(url)
        case "FAILED": throw VideoGenerationError.taskFailed(output.code)
        case "CANCELED": throw VideoGenerationError.taskCanceled
        case "UNKNOWN": throw VideoGenerationError.taskUnavailable
        default: throw VideoGenerationError.invalidResponse
        }
    }

    private static func authorizedRequest(_ url: URL, key: String) throws -> URLRequest {
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { throw ImageGenerationError.missingKey }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request, delegate: DenyRedirects())
        guard let http = response as? HTTPURLResponse else { throw VideoGenerationError.invalidResponse }
        return (data, http.statusCode)
    }

    private static func decode(_ data: Data, status: Int) throws -> Response.Output {
        let response = try? JSONDecoder().decode(Response.self, from: data)
        if !(200..<300).contains(status) || response?.code?.isEmpty == false {
            throw VideoGenerationError.service(status: status, code: response?.code)
        }
        guard let output = response?.output else { throw VideoGenerationError.invalidResponse }
        return output
    }

    private static func isValidTaskID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private struct Response: Decodable {
        struct Output: Decodable {
            let task_id: String?
            let task_status: String?
            let video_url: URL?
            let code: String?
        }
        let output: Output?
        let code: String?
    }
}

public struct PendingVideoTask: Codable, Equatable, Sendable {
    public let taskID: String
    public let region: DashScopeRegion
    public let title: String
    public let wallpaperID: UUID

    public init(taskID: String, region: DashScopeRegion, title: String) {
        self.taskID = taskID
        self.region = region
        self.title = title
        self.wallpaperID = UUID()
    }
}

public struct VideoDraftStore {
    public let directory: URL
    private var record: URL { directory.appendingPathComponent("pending.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> PendingVideoTask? {
        do {
            return try JSONDecoder().decode(PendingVideoTask.self, from: Data(contentsOf: record))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    public func save(_ task: PendingVideoTask) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(task).write(to: record, options: .atomic)
    }

    public func preview(for task: PendingVideoTask) -> URL {
        directory.appendingPathComponent(task.wallpaperID.uuidString).appendingPathExtension("mp4")
    }

    public func clear(_ task: PendingVideoTask) throws {
        let file = preview(for: task)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        if try load() == task { try FileManager.default.removeItem(at: record) }
    }
}
