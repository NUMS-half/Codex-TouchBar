import Foundation

enum AppProject {
    static let name = "Codex TouchBar"
    static let repository = URL(string: "https://github.com/NUMS-half/Codex-TouchBar")!
    static let help = URL(string: "https://github.com/NUMS-half/Codex-TouchBar#readme")!
    static let issues = repository.appendingPathComponent("issues")
    static let releases = repository.appendingPathComponent("releases")
    static let latestAPI = URL(string: "https://api.github.com/repos/NUMS-half/Codex-TouchBar/releases/latest")!
}

struct AppBuildInfo: Equatable, Sendable {
    let version: String
    let build: String
    static var current: Self {
        Self(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建",
             build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
    }
    var text: String { "版本 \(version)（\(build)）" }
}

struct AppVersion: Comparable, Sendable {
    private let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count else { return nil }
        parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppRelease: Equatable, Sendable {
    let tag: String
    let version: AppVersion
    var page: URL { AppProject.releases.appendingPathComponent("tag").appendingPathComponent(tag) }

    enum Comparison { case newer, same, older, unknown }
    func compare(to installed: String) -> Comparison {
        guard let current = AppVersion(installed) else { return .unknown }
        return version > current ? .newer : (version == current ? .same : .older)
    }
}

enum AppUpdateError: LocalizedError {
    case noRelease, rateLimited, unavailable, invalidRelease
    var errorDescription: String? {
        switch self {
        case .noRelease: return "暂未找到公开正式版本，可打开发布页面查看。"
        case .rateLimited: return "GitHub 请求较频繁，请稍后重试，或打开发布页面查看。"
        case .unavailable: return "暂时无法连接发布服务，请稍后重试。"
        case .invalidRelease: return "无法识别发布信息，请打开发布页面查看。"
        }
    }
}

struct AppReleaseClient: Sendable {
    static func decode(_ data: Data, status: Int) throws -> AppRelease {
        switch status {
        case 200: break
        case 404: throw AppUpdateError.noRelease
        case 403, 429: throw AppUpdateError.rateLimited
        default: throw AppUpdateError.unavailable
        }
        struct Payload: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
        guard data.count <= 1_048_576, let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.draft, !payload.prerelease, let version = AppVersion(payload.tag_name) else {
            throw AppUpdateError.invalidRelease
        }
        return AppRelease(tag: payload.tag_name, version: version)
    }

    func latest() async throws -> AppRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: AppProject.latestAPI, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexTouchBar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppUpdateError.unavailable }
        return try Self.decode(data, status: response.statusCode)
    }
}
