import Foundation

@MainActor
final class UsageStore {
    private let provider: any UsageProvider
    private let cache: UsageCache

    private(set) var snapshot: UsageSnapshot?
    private(set) var freshness: SnapshotFreshness = .cached
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false

    var onChange: (() -> Void)?

    init(
        provider: any UsageProvider = CodexUsageService(),
        cache: UsageCache = .init()
    ) {
        self.provider = provider
        self.cache = cache
        if let cached = cache.loadIfFresh() {
            snapshot = cached
            freshness = .cached
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        notify()

        Task { [weak self, provider] in
            guard let self else { return }
            do {
                let value = try await provider.fetch()
                self.snapshot = value
                self.freshness = .live
                self.errorMessage = nil
                self.cache.save(value)
            } catch {
                let message = error.localizedDescription
                self.errorMessage = message
                if self.snapshot != nil {
                    self.freshness = .stale(message)
                }
            }
            self.isRefreshing = false
            self.notify()
        }
    }

    private func notify() {
        onChange?()
    }
}

/// Persists only values already displayed by the UI. It intentionally excludes
/// account identifiers, credentials, raw JSON-RPC payloads, and task content.
struct UsageCache: Sendable {
    private static let maxAge: TimeInterval = 24 * 60 * 60
    private let fileURL: URL
    private let now: @Sendable () -> Date

    init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL ?? Self.defaultURL()
        self.now = now
    }

    func loadIfFresh() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data),
              now().timeIntervalSince(snapshot.fetchedAt) <= Self.maxAge else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: UsageSnapshot) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A cache write failure must never make a successful live read fail.
        }
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("com.wyx.CodexTouchBar", isDirectory: true)
            .appendingPathComponent("usage-snapshot.json")
    }
}
