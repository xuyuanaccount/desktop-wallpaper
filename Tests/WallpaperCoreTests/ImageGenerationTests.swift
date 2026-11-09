import Foundation
import Testing
@testable import WallpaperCore

// A real 1×1 PNG, embedded to keep the response fixture self-contained.
let wallpaperPNGFixture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQj6kEAAGqAP2fk/48AAAAAElFTkSuQmCC")!

struct ImageGenerationTests {
    @Test func requestUsesOpenAIEndpointAndWallpaperDimensions() throws {
        let request = try ImageGenerationClient.request(
            prompt: "  深蓝色的安静山谷  ", size: .desktop, quality: .medium, key: "test-key"
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/generations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let bytes = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: String])
        #expect(body["model"] == "gpt-image-2.6-flare")
        #expect(body["prompt"] == "深蓝色的安静山谷")
        #expect(body["size"] == "1536x864")
        #expect(body["quality"] == "medium")
        #expect(body["output_format"] == "png")
        #expect(!body.values.contains("test-key"))
    }

    @Test func sendsARequestAndReturnsPNGFromTheTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureImageProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ImageGenerationClient(session: session)
        let result = try await client.generate(prompt: "山谷", size: .macBook, quality: .high, key: "fixture-key")
        #expect(result == wallpaperPNGFixture)
    }

    @Test func blankPromptFailsBeforeSending() {
        #expect(throws: ImageGenerationError.emptyPrompt) {
            try ImageGenerationClient.request(prompt: " \n ", size: .desktop, quality: .medium, key: "test-key")
        }
    }

    @Test func decodesRealPNGFromOpenAIResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": wallpaperPNGFixture.base64EncodedString()]]])
        #expect(try ImageGenerationClient.decode(data, status: 200) == wallpaperPNGFixture)
    }

    @Test func rejectsInvalidImageAndMapsAPIErrors() throws {
        let invalid = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": Data("fake".utf8).base64EncodedString()]]])
        #expect(throws: ImageGenerationError.invalidImage) {
            try ImageGenerationClient.decode(invalid, status: 200)
        }
        #expect(throws: ImageGenerationError.service(status: 401, code: nil)) {
            try ImageGenerationClient.decode(Data(), status: 401)
        }
        let quota = Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8)
        #expect(throws: ImageGenerationError.service(status: 429, code: "insufficient_quota")) {
            try ImageGenerationClient.decode(quota, status: 429)
        }
    }

    @Test func generatedWallpaperPersistsAsAStaticSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedImageStore(directory: directory.appendingPathComponent("Generated"))
        #expect(throws: ImageGenerationError.invalidImage) { try store.save(Data()) }
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        let url = try store.save(wallpaperPNGFixture)
        let another = try store.save(wallpaperPNGFixture)
        #expect(url.pathExtension == "png")
        #expect(url != another)
        #expect(try Data(contentsOf: url) == wallpaperPNGFixture)
        let wallpaper = Wallpaper(title: "AI wallpaper", source: .image(url))
        var settings = EngineSettings()
        settings.wallpapers = [wallpaper]
        settings.defaultAssignment = .wallpaper(wallpaper.id)
        let settingsFile = SettingsFile(url: directory.appendingPathComponent("settings.json"))
        try settingsFile.save(settings)
        #expect(try settingsFile.load().resolve(.wallpaper(wallpaper.id), at: .now, frontmost: nil) == wallpaper)
    }
}


private final class FixtureImageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              url.absoluteString == "https://api.openai.com/v1/images/generations",
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
              let data = try? JSONSerialization.data(withJSONObject: ["data": [["b64_json": wallpaperPNGFixture.base64EncodedString()]]]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
