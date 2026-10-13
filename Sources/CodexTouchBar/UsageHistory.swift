import Foundation
import SQLite3

struct UsageHistoryResult: Sendable {
    let points: [UsageObservation]
    let notice: String?
}

/// All SQLite access stays on one utility queue, including open, recovery and close.
final class UsageHistoryRepository: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexTouchBar.UsageHistory", qos: .utility)
    private let database: UsageHistoryDatabase
    init(url: URL = UsageHistoryDatabase.defaultURL) { database = UsageHistoryDatabase(url: url) }

    func append(_ points: [UsageObservation], now: Date) async throws {
        try await execute { try $0.append(points, now: now) }
    }
    func read(_ kind: UsageWindowKind, now: Date) async throws -> UsageHistoryResult {
        try await execute { database in
            try database.pruneIfNeeded(now: now)
            return UsageHistoryResult(points: try database.read(kind, now: now), notice: database.notice)
        }
    }
    func prune(now: Date) async throws { try await execute { try $0.pruneIfNeeded(now: now) } }
    func clear() async throws { try await execute { try $0.clear() } }
    private func execute<T: Sendable>(_ operation: @escaping @Sendable (UsageHistoryDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [database] in
                do { continuation.resume(returning: try database.recovering { try operation(database) }) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Synchronous core, also exercised by the command-line self-test on temporary files.
final class UsageHistoryDatabase: @unchecked Sendable {
    struct Failure: Error { let code: Int32 }
    let url: URL
    private var db: OpaquePointer?
    private var lastPrune: Date?
    private(set) var notice: String?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static var defaultURL: URL {
        ApplicationIdentity.supportDirectory.appendingPathComponent("usage-history.sqlite")
    }
    init(url: URL) { self.url = url }
    deinit { if let db { sqlite3_close(db) } }

    func recovering<T>(_ operation: () throws -> T) throws -> T {
        do { try open(); return try operation() }
        catch let error as Failure where [SQLITE_CORRUPT, SQLITE_NOTADB].contains(error.code & 0xff) {
            if let db { sqlite3_close(db) }; db = nil
            let suffix = ".damaged-" + UUID().uuidString
            // Keep sidecars alongside the damaged database, never delete the user's evidence.
            for extensionName in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + extensionName)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source,
                        to: URL(fileURLWithPath: url.path + suffix + extensionName))
                }
            }
            lastPrune = nil
            notice = "历史数据库损坏，已保留备份并重新记录。"
            try open()
            return try operation()
        }
    }

    private func open() throws {
        if db != nil { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw Failure(code: code)
        }
        do {
            sqlite3_busy_timeout(db, 1_000)
            try sql("PRAGMA journal_mode=WAL")
            try sql("PRAGMA synchronous=NORMAL")
            try sql("CREATE TABLE IF NOT EXISTS observations (kind TEXT NOT NULL, minute INTEGER NOT NULL, time REAL NOT NULL, remaining INTEGER NOT NULL, duration INTEGER, reset REAL, plan TEXT, limit_name TEXT, rise INTEGER NOT NULL, discontinuity INTEGER NOT NULL, PRIMARY KEY(kind, minute))")
            try sql("PRAGMA user_version=1")
        } catch {
            if let db { sqlite3_close(db) }; db = nil
            throw error
        }
    }

    func append(_ points: [UsageObservation], now: Date) throws {
        try pruneIfNeeded(now: now)
        try sql("BEGIN IMMEDIATE")
        do {
            for var point in points {
                guard point.time <= now.addingTimeInterval(60), point.time >= now.addingTimeInterval(-point.kind.historyDuration) else { continue }
                if let previous = try latest(point.kind) {
                    guard point.time > previous.time else { continue }
                    point.discontinuity = point.changedScope(from: previous)
                    point.rise = point.recoveryGain(from: previous) != nil
                }
                let statement = try prepare("INSERT INTO observations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(kind, minute) DO UPDATE SET time=excluded.time, remaining=excluded.remaining, duration=excluded.duration, reset=excluded.reset, plan=excluded.plan, limit_name=excluded.limit_name, rise=MAX(observations.rise, excluded.rise), discontinuity=MAX(observations.discontinuity, excluded.discontinuity)")
                defer { sqlite3_finalize(statement) }
                bind(point.kind.rawValue, to: statement, at: 1)
                sqlite3_bind_int64(statement, 2, Int64(floor(point.time.timeIntervalSince1970 / 60)))
                sqlite3_bind_double(statement, 3, point.time.timeIntervalSince1970)
                sqlite3_bind_int(statement, 4, Int32(point.remaining))
                if let duration = point.duration { sqlite3_bind_int(statement, 5, Int32(duration)) }
                if let reset = point.reset { sqlite3_bind_double(statement, 6, reset.timeIntervalSince1970) }
                bind(point.plan, to: statement, at: 7); bind(point.limitName, to: statement, at: 8)
                sqlite3_bind_int(statement, 9, point.rise ? 1 : 0)
                sqlite3_bind_int(statement, 10, point.discontinuity ? 1 : 0)
                try finish(statement)
            }
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }

    func pruneIfNeeded(now: Date) throws {
        if let lastPrune, now.timeIntervalSince(lastPrune) >= 0, now.timeIntervalSince(lastPrune) < 3_600 { return }
        for kind in UsageWindowKind.allCases {
            let statement = try prepare("DELETE FROM observations WHERE kind=? AND (time < ? OR time > ?)")
            defer { sqlite3_finalize(statement) }
            bind(kind.rawValue, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970 - kind.historyDuration)
            sqlite3_bind_double(statement, 3, now.timeIntervalSince1970 + 60)
            try finish(statement)
        }
        lastPrune = now
    }

    func read(_ kind: UsageWindowKind, now: Date) throws -> [UsageObservation] {
        let statement = try prepare("SELECT kind, time, remaining, duration, reset, plan, limit_name, rise, discontinuity FROM observations WHERE kind=? AND time>=? AND time<=? ORDER BY minute")
        defer { sqlite3_finalize(statement) }
        bind(kind.rawValue, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970 - kind.historyDuration)
        sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
        return try rows(statement)
    }

    private func latest(_ kind: UsageWindowKind) throws -> UsageObservation? {
        let statement = try prepare("SELECT kind, time, remaining, duration, reset, plan, limit_name, rise, discontinuity FROM observations WHERE kind=? ORDER BY minute DESC LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(kind.rawValue, to: statement, at: 1)
        return try rows(statement).first
    }

    func clear() throws {
        try sql("DELETE FROM observations")
        try sql("PRAGMA wal_checkpoint(TRUNCATE)")
        notice = nil
    }
    private func rows(_ statement: OpaquePointer) throws -> [UsageObservation] {
        var result: [UsageObservation] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw Failure(code: code) }
            guard let name = string(statement, 0), let kind = UsageWindowKind(rawValue: name) else { continue }
            result.append(.init(kind: kind, time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                remaining: Int(sqlite3_column_int(statement, 2)),
                                duration: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 3)),
                                reset: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                                plan: string(statement, 5), limitName: string(statement, 6),
                                rise: sqlite3_column_int(statement, 7) != 0, discontinuity: sqlite3_column_int(statement, 8) != 0))
        }
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        if let value { sqlite3_bind_text(statement, index, value, -1, transient) }
        else { sqlite3_bind_null(statement, index) }
    }
    private func prepare(_ text: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, text, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw Failure(code: code) }
        return statement
    }
    private func finish(_ statement: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw Failure(code: code) }
    }
    private func sql(_ text: String) throws {
        let code = sqlite3_exec(db, text, nil, nil, nil)
        guard code == SQLITE_OK else { throw Failure(code: code) }
    }
}
