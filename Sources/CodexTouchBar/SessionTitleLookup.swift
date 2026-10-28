import Foundation
import Darwin
import SQLite3

enum SessionTitleMatch: Equatable {
    case matched(String), unknown, ambiguous, unavailable
}

/// Queue-confined read-only connection. data_version invalidates the small
/// in-memory title map without repeating the full title query every 500ms.
final class SessionTitleLookup {
    private let url: URL
    private var database: OpaquePointer?
    private var titleStatement: OpaquePointer?
    private var versionStatement: OpaquePointer?
    private var identity: UInt64 = 0
    private var version: Int32?
    private var cached: [String: SessionTitleMatch] = [:]
    private(set) var queryCount = 0

    init(home: URL) { url = home.appendingPathComponent("state_5.sqlite") }
    deinit { close() }
    private func close() {
        sqlite3_finalize(titleStatement); titleStatement = nil
        sqlite3_finalize(versionStatement); versionStatement = nil
        if let database { sqlite3_close(database) }; database = nil
        version = nil; cached.removeAll()
    }
    private func open() -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { close(); return false }
        if database != nil && identity == UInt64(info.st_ino) { return true }
        close(); identity = UInt64(info.st_ino)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { close(); return false }
        sqlite3_busy_timeout(database, 100)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        let sql = "SELECT id FROM threads WHERE archived = 0 AND TRIM(COALESCE(NULLIF(TRIM(name), ''), title)) = ? LIMIT 2"
        guard sqlite3_prepare_v2(database, sql, -1, &titleStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "PRAGMA data_version", -1, &versionStatement, nil) == SQLITE_OK else { close(); return false }
        return true
    }
    func lookup(_ title: String) -> SessionTitleMatch {
        guard !title.isEmpty, title.count <= 4_096 else { return .unknown }
        guard open() else { return .unavailable }
        sqlite3_reset(versionStatement)
        guard sqlite3_step(versionStatement) == SQLITE_ROW else { return .unavailable }
        let current = sqlite3_column_int(versionStatement, 0)
        sqlite3_reset(versionStatement)
        if version != current { version = current; cached.removeAll() }
        if let value = cached[title] { return value }
        sqlite3_reset(titleStatement); sqlite3_clear_bindings(titleStatement)
        defer { sqlite3_reset(titleStatement); sqlite3_clear_bindings(titleStatement) }
        guard sqlite3_bind_text(titleStatement, 1, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { return .unavailable }
        queryCount += 1
        let result: SessionTitleMatch
        switch sqlite3_step(titleStatement) {
        case SQLITE_DONE: result = .unknown
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(titleStatement, 0) else { return .unavailable }
            let id = String(cString: text)
            guard !id.isEmpty, id.count <= 128 else { return .unavailable }
            switch sqlite3_step(titleStatement) {
            case SQLITE_DONE: result = .matched(id)
            case SQLITE_ROW: result = .ambiguous
            default: return .unavailable
            }
        default: return .unavailable
        }
        if cached.count >= 8 { cached.removeAll() }
        cached[title] = result
        return result
    }
}
