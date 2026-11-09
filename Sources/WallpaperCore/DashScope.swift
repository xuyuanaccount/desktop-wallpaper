import Foundation

public enum DashScopeRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case beijing, singapore
    public var id: Self { self }

    func endpoint(_ path: String) -> URL {
        let host = self == .beijing ? "dashscope.aliyuncs.com" : "dashscope-intl.aliyuncs.com"
        return URL(string: "https://\(host)/api/v1")!.appending(path: path)
    }
}

enum DashScope {
    static func isSignedResultURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels[0].hasPrefix("dashscope-") && labels[1].hasPrefix("oss-")
            && labels[2] == "aliyuncs" && labels[3] == "com"
    }
}

final class DenyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
