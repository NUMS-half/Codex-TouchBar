import Foundation
import SQLite3

struct SessionLogIndex {
    let home: URL
    /// The native title must identify exactly one local thread. Never choose the
    /// newest match, a partial title, or a previously visited conversation.
    func conversationID(windowTitle: String) -> String? {
        if case let .matched(id) = SessionTitleLookup(home: home).lookup(windowTitle) { return id }
        return nil
    }

    func resolve(conversationID: String) -> URL? {
        guard !conversationID.isEmpty, conversationID.count <= 128 else { return nil }
        let url = home.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT rollout_path FROM threads WHERE id = ? AND archived = 0 LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, conversationID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let resolved = URL(fileURLWithPath: String(cString: text)).resolvingSymlinksInPath().standardizedFileURL
        let root = home.appendingPathComponent("sessions").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard resolved.path.hasPrefix(root), resolved.pathExtension == "jsonl" else { return nil }
        return resolved
    }
}
