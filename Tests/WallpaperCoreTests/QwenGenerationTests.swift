import Foundation
import Testing
@testable import DesktopWallpaper
@testable import WallpaperCore

struct QwenGenerationTests {
    @Test func beijingAndSingaporeUseTheirOwnDashScopeEndpoints() throws {
        let beijing = try ImageGenerationClient.request(
            prompt: "  宁静的山谷  ", size: .ultrawide, quality: .high, key: "beijing-key", target: .qwenBeijing
        )
        let singapore = try ImageGenerationClient.request(
            prompt: "山谷", size: .desktop, quality: .medium, key: "singapore-key", target: .qwenSingapore
        )
        #expect(beijing.url?.absoluteString == "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        #expect(singapore.url?.absoluteString == "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        #expect(beijing.value(forHTTPHeaderField: "Authorization") == "Bearer beijing-key")
        #expect(singapore.value(forHTTPHeaderField: "Authorization") == "Bearer singapore-key")
        let bytes = try #require(beijing.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(body["model"] as? String == "qwen-image-3.0-pro")
        let input = try #require(body["input"] as? [String: Any])
        let messages = try #require(input["messages"] as? [[String: Any]])
        let message = try #require(messages.first)
        let role = message["role"] as? String
        let content = message["content"] as? [[String: String]]
        #expect(role == "user")
        #expect(content == [["text": "宁静的山谷"]])
        let parameters = try #require(body["parameters"] as? [String: Any])
        #expect(parameters["size"] as? String == "1792*768")
        #expect(parameters["n"] as? Int == 1)
        #expect(parameters["quality"] == nil)
    }

    @Test func downloadsSignedPNGWithoutSendingTheDashScopeKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureQwenProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ImageGenerationClient(session: session)
        let result = try await client.generate(
            prompt: "山谷", size: .desktop, quality: .medium, key: "fixture-key", target: .qwenBeijing
        )
        #expect(result == wallpaperPNGFixture)
    }

    @Test func rejectsUnexpectedImageHostsAndReadsDashScopeErrorCodes() {
        let unexpectedURL = Data(#"{"output":{"choices":[{"message":{"content":[{"image":"https://other.aliyuncs.com/file.png"}]}}]}}"#.utf8)
        #expect(throws: ImageGenerationError.invalidResponse) {
            try ImageGenerationClient.qwenImageURL(unexpectedURL, status: 200)
        }
        let invalidKey = Data(#"{"code":"InvalidApiKey","message":"Invalid API-key provided."}"#.utf8)
        #expect(throws: ImageGenerationError.qwen(status: 401, code: "InvalidApiKey")) {
            try ImageGenerationClient.qwenImageURL(invalidKey, status: 401)
        }
        let blocked = Data(#"{"code":"DataInspectionFailed","message":"Rejected"}"#.utf8)
        #expect(throws: ImageGenerationError.qwen(status: 200, code: "DataInspectionFailed")) {
            try ImageGenerationClient.qwenImageURL(blocked, status: 200)
        }
    }

    @Test func keychainPreservesOpenAIIdentityAndSeparatesQwenRegions() {
        #expect(ImageGenerationKeychain.service(for: .openAI) == "local.desktopwallpaper.engine.openai")
        #expect(ImageGenerationKeychain.service(for: .qwenBeijing) != ImageGenerationKeychain.service(for: .openAI))
        #expect(ImageGenerationKeychain.service(for: .qwenBeijing) != ImageGenerationKeychain.service(for: .qwenSingapore))
    }
}

private final class FixtureQwenProtocol: URLProtocol {
    private static let imageURL = "https://dashscope-a717.oss-accelerate.aliyuncs.com/wallpaper.png?Expires=1794130000"

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
        case ("POST", "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation", "Bearer fixture-key"):
            data = Data("""
            {"output":{"choices":[{"message":{"content":[{"image":"\(Self.imageURL)"}]}}]}}
            """.utf8)
        case ("GET", Self.imageURL, nil):
            data = wallpaperPNGFixture
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
