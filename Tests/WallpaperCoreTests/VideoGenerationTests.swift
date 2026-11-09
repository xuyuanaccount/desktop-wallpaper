import Foundation
import os
import Testing
@testable import WallpaperCore

struct VideoGenerationTests {
    @Test func submitsWan27UsingResolutionRatioAndAsyncHeader() throws {
        let request = try WanVideoClient.submission(
            prompt: "  云层缓缓流动  ", resolution: .hd, ratio: .landscape,
            duration: 5, region: .beijing, key: "fixture-key"
        )
        #expect(request.url?.absoluteString == "https://dashscope.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request.value(forHTTPHeaderField: "X-DashScope-Async") == "enable")
        let bytes = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let input = try #require(body["input"] as? [String: String])
        let parameters = try #require(body["parameters"] as? [String: Any])
        #expect(body["model"] as? String == "wan2.7-t2v")
        #expect(input["prompt"] == "云层缓缓流动")
        #expect(parameters["resolution"] as? String == "720P")
        #expect(parameters["ratio"] as? String == "16:9")
        #expect(parameters["duration"] as? Int == 5)
        #expect(parameters["size"] == nil)
        #expect(throws: VideoGenerationError.invalidDuration) {
            try WanVideoClient.submission(prompt: "云", resolution: .hd, ratio: .portrait,
                                          duration: 16, region: .beijing, key: "fixture-key")
        }
    }

    @Test @MainActor func pollsExistingTaskAndDownloadsWithoutSendingTheAPIKey() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureVideoProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = WanVideoClient(session: session, pollInterval: .zero)
        let id = try await client.submit(prompt: "云", resolution: .fullHD, ratio: .landscape,
                                         duration: 5, region: .singapore, key: "fixture-key")
        #expect(id == "wan-task-1")
        var progress: [VideoTaskState] = []
        let url = try await client.waitForResult(taskID: id, region: .singapore, key: "fixture-key") { progress.append($0) }
        #expect(progress == [.running])
        #expect(url.absoluteString == FixtureVideoProtocol.videoURL)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await client.download(url, to: output)
        #expect(try Data(contentsOf: output) == FixtureVideoProtocol.videoBytes)
    }

    @Test func expiredAndFailedTasksHaveDistinctTerminalStates() throws {
        let failed = Data(#"{"output":{"task_id":"wan-task-1","task_status":"FAILED","code":"DataInspectionFailed"}}"#.utf8)
        let expired = Data(#"{"output":{"task_id":"wan-task-1","task_status":"UNKNOWN"}}"#.utf8)
        let processing = Data(#"{"output":{"task_id":"wan-task-1","task_status":"RUNNING"}}"#.utf8)
        #expect(throws: VideoGenerationError.taskFailed("DataInspectionFailed")) {
            try WanVideoClient.taskState(failed, status: 200, expectedID: "wan-task-1")
        }
        #expect(throws: VideoGenerationError.taskUnavailable) {
            try WanVideoClient.taskState(expired, status: 200, expectedID: "wan-task-1")
        }
        #expect(try WanVideoClient.taskState(processing, status: 200, expectedID: "wan-task-1") == .running)
        let externalURL = Data(#"{"output":{"task_id":"wan-task-1","task_status":"SUCCEEDED","video_url":"https://example.com/clip.mp4"}}"#.utf8)
        #expect(throws: VideoGenerationError.invalidResponse) {
            try WanVideoClient.taskState(externalURL, status: 200, expectedID: "wan-task-1")
        }
    }

    @Test func draftCanResumeAfterReopeningWithoutThePromptOrKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VideoDraftStore(directory: directory)
        #expect(try store.load() == nil)
        let task = PendingVideoTask(taskID: "wan-task-1", region: .singapore, title: "AI 视频 · 云")
        try store.save(task)
        #expect(try VideoDraftStore(directory: directory).load() == task)
        #expect(store.preview(for: task).pathExtension == "mp4")
        try store.clear(task)
        #expect(try store.load() == nil)
    }
}

private final class FixtureVideoProtocol: URLProtocol {
    static let videoURL = "https://dashscope-result-sh.oss-accelerate.aliyuncs.com/clip.mp4?Expires=1794130000"
    static let videoBytes = Data("fixture video transfer".utf8)
    private static let pollCount = OSAllocatedUnfairLock(initialState: 0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let data: Data
        switch (request.httpMethod, url.absoluteString, request.value(forHTTPHeaderField: "Authorization")) {
        case ("POST", "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/video-generation/video-synthesis", "Bearer fixture-key"):
            Self.pollCount.withLock { $0 = 0 }
            data = Data(#"{"output":{"task_id":"wan-task-1","task_status":"PENDING"}}"#.utf8)
        case ("GET", "https://dashscope-intl.aliyuncs.com/api/v1/tasks/wan-task-1", "Bearer fixture-key"):
            let poll = Self.pollCount.withLock { count in
                count += 1
                return count
            }
            if poll == 1 {
                data = Data(#"{"output":{"task_id":"wan-task-1","task_status":"RUNNING"}}"#.utf8)
            } else {
                data = Data("""
                {"output":{"task_id":"wan-task-1","task_status":"SUCCEEDED","video_url":"\(Self.videoURL)"}}
                """.utf8)
            }
        case ("GET", Self.videoURL, nil):
            data = Self.videoBytes
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
