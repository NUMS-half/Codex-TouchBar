import Foundation
import SQLite3

/// Synthetic sessions and a fake IPC connection; no real window or session is read.
enum SessionSelectionChecks {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var title: String? = "A"
        private var value = SessionTPSSnapshot()
        private var connection: Connection?
        private var builds = 0
        private var probesOnMainThread = false
        private var probes = 0
        private var emptyPublications = 0
        func setTitle(_ title: String?) { lock.lock(); self.title = title; lock.unlock() }
        func visibleTitle() -> String? {
            lock.lock(); defer { lock.unlock() }
            probes += 1
            probesOnMainThread = probesOnMainThread || Thread.isMainThread
            return title
        }
        func newReader(url: URL, id: String) -> SessionRolloutReader { lock.lock(); builds += 1; lock.unlock(); return SessionRolloutReader(url: url, conversationID: id) }
        func buildCount() -> Int { lock.lock(); defer { lock.unlock() }; return builds }
        func usedMainThreadProbe() -> Bool { lock.lock(); defer { lock.unlock() }; return probesOnMainThread }
        func publish(_ value: SessionTPSSnapshot) { lock.lock(); self.value = value; if value.tokensPerSecond == nil { emptyPublications += 1 }; lock.unlock() }
        func probeCount() -> Int { lock.lock(); defer { lock.unlock() }; return probes }
        func emptyCount() -> Int { lock.lock(); defer { lock.unlock() }; return emptyPublications }
        func snapshot() -> SessionTPSSnapshot { lock.lock(); defer { lock.unlock() }; return value }
        func setConnection(_ connection: Connection) { lock.lock(); self.connection = connection; lock.unlock() }
        func emit(_ event: CodexFollowingEvent) {
            lock.lock(); let connection = connection; lock.unlock()
            connection?.emit(event)
        }
        func disconnectAfter(_ event: CodexFollowingEvent) {
            lock.lock(); let connection = connection; lock.unlock()
            connection?.disconnectAfter(event)
        }
    }
    final class Connection: SessionConnecting {
        var onFollowing: ((CodexFollowingEvent) -> Void)?
        var onDisconnect: (() -> Void)?
        let queue: DispatchQueue
        let initial: CodexFollowingEvent
        init(queue: DispatchQueue, initial: CodexFollowingEvent) { self.queue = queue; self.initial = initial }
        func connect() -> Bool { queue.async { [self] in onFollowing?(initial) }; return true }
        func stop() {}
        func emit(_ event: CodexFollowingEvent) { queue.async { [self] in onFollowing?(event) } }
        func disconnectAfter(_ event: CodexFollowingEvent) {
            queue.async { [self] in onFollowing?(event); onDisconnect?() }
        }
    }
    static func event(_ id: String, following: Bool = true, source: String = "window") throws -> CodexFollowingEvent {
        let data = try JSONSerialization.data(withJSONObject: ["type": "broadcast", "method": "thread-stream-following-changed",
            "sourceClientId": source, "params": ["conversationId": id, "hostId": "local", "following": following]])
        return try JSONDecoder().decode(CodexFollowingEvent.self, from: data)
    }
    static func fixture(_ home: URL) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else { throw SessionRolloutReader.ReaderError.unavailable }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER, title TEXT, name TEXT)", nil, nil, nil)
        for (id, rate) in [("A", 100), ("B", 200), ("C", 300), ("D", 400), ("E", 500), ("F", 600), ("G", 700)] {
            let log = home.appendingPathComponent("sessions/\(id).jsonl")
            var data = try SessionTPSChecks.line("session_meta", ["id": id, "originator": "codex_work_desktop", "source": "vscode"]); data.append(10)
            for (type, payload) in [("event_msg", ["type": "task_started", "turn_id": id] as [String: Any]),
                ("event_msg", ["type": "item_completed", "turn_id": id, "item": ["id": "output", "type": "AgentMessage"], "started_at_ms": 0, "completed_at_ms": 1_000]),
                ("token_usage_record", ["turn_id": id, "response_id": id, "usage": ["output_tokens": rate], "thread_token_usage": ["output_tokens": rate]]),
                ("event_msg", ["type": "task_complete", "turn_id": id])] {
                data.append(try SessionTPSChecks.line(type, payload)); data.append(10)
            }
            try data.write(to: log)
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?, ?, 0, ?, NULL)", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id, -1, transient); sqlite3_bind_text(statement, 2, log.path, -1, transient)
            sqlite3_bind_text(statement, 3, id, -1, transient); sqlite3_step(statement); sqlite3_finalize(statement)
        }
    }
    @MainActor static func run() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tps-selection-" + UUID().uuidString)
        try fixture(home)
        defer { try? FileManager.default.removeItem(at: home) }
        let state = State()
        let initial = try event("A")
        let worker = SessionTPSWorker(home: home, publish: { state.publish($0) }, makeConnection: { queue in
            let connection = Connection(queue: queue, initial: initial); state.setConnection(connection); return connection
        }, visibleTitle: { state.visibleTitle() }, makeReader: { state.newReader(url: $0, id: $1) })
        defer { worker.stop() }
        worker.start()
        func expect(_ rate: Double?, _ message: String) async throws {
            for _ in 0..<30 {
                if state.snapshot().tokensPerSecond == rate { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            try SessionTPSChecks.check(false, message)
        }
        try await expect(100, "first visit A displays A")
        state.disconnectAfter(try event("pending-before-disconnect"))
        try await expect(nil, "disconnect clears the old selection")
        try await expect(100, "reconnect restores the selected conversation")
        // The initial 50 ms timer has just observed A; the next periodic sample
        // is 500 ms away, so this checks the event-triggered selection path.
        state.setTitle("B"); state.emit(try event("B"))
        for _ in 0..<3 {
            if state.snapshot().tokensPerSecond == 200 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try SessionTPSChecks.check(state.snapshot().tokensPerSecond == 200,
                                   "a queued selection during disconnect must not block event-triggered selection after reconnect")
        state.setTitle("A")
        try await expect(100, "return to A after reconnect")
        state.setTitle("B")
        try await expect(200, "switch to B before missing-log check")
        let missingLog = home.appendingPathComponent("sessions/A.jsonl")
        let hiddenLog = home.appendingPathComponent("sessions/A.hidden")
        try FileManager.default.moveItem(at: missingLog, to: hiddenLog)
        state.setTitle("A")
        try await expect(nil, "revisiting a cached conversation with an unavailable log must not retain B's speed")
        try FileManager.default.moveItem(at: hiddenLog, to: missingLog)
        state.setTitle("B")
        try await expect(200, "return to B after restoring A's log")
        state.setTitle("A")
        try await expect(100, "restored A log reuses the correct cached reader")
        let heldFile = try FileHandle(forWritingTo: missingLog)
        try heldFile.seekToEnd()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: missingLog.path)
        try heldFile.write(contentsOf: Data([10]))
        try await expect(nil, "a read failure is shown instead of the old rate")
        try await Task.sleep(for: .milliseconds(500))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: missingLog.path)
        try heldFile.close()
        try await expect(100, "restoring read access refreshes the current session without a new log append")
        let emptyBeforeTransient = state.emptyCount()
        state.setTitle(nil)
        try await Task.sleep(for: .milliseconds(700))
        try SessionTPSChecks.check(state.snapshot().tokensPerSecond == 100, "brief title read failure while typing must not flash a dash")
        try SessionTPSChecks.check(state.emptyCount() == emptyBeforeTransient, "transient title failure publishes no empty intermediate value")
        state.setTitle("A")
        try await Task.sleep(for: .milliseconds(600))
        state.setTitle("B"); state.emit(try event("B"))
        try await expect(200, "first visit B displays B")
        let emptyBeforeRevisit = state.emptyCount()
        state.setTitle("A") // Cached view: no new subscription event.
        try await expect(100, "A-B-A must restore A without another subscription event")
        try SessionTPSChecks.check(state.emptyCount() == emptyBeforeRevisit, "warm revisit publishes value without a waiting dash")
        try SessionTPSChecks.check(state.buildCount() == 2, "A-B-A must reuse readers instead of replaying A again")
        state.setTitle("B")
        try await expect(200, "repeated B uses visible conversation rather than last new subscription")
        state.setTitle("C"); state.emit(try event("C"))
        try await expect(300, "first visit C displays C")
        state.setTitle("A")
        try await expect(100, "A remains correct after visiting C")
        state.emit(try event("B", following: false))
        try await Task.sleep(for: .milliseconds(600))
        try SessionTPSChecks.check(state.snapshot().tokensPerSecond == 100, "unfollowing B does not discard A's subscription from the same client")
        // More than 64 cached subscriptions must not force a reconnect loop.
        let probesBeforeBurst = state.probeCount()
        for index in 0..<80 { state.emit(try event("cached-\(index)")) }
        try await Task.sleep(for: .milliseconds(800))
        try SessionTPSChecks.check(state.snapshot().tokensPerSecond == 100, "large cached subscription replay preserves visible A")
        try SessionTPSChecks.check(state.probeCount() - probesBeforeBurst <= 4, "80 subscription events coalesce instead of performing 80 window probes")
        state.setTitle("Unknown")
        try await expect(nil, "unknown visible view must not reuse A's speed")
        state.setTitle("A")
        try await expect(100, "returning from unknown view restores A")
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else { throw SessionRolloutReader.ReaderError.unavailable }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "INSERT INTO threads VALUES ('duplicate', '', 0, 'A', NULL)", nil, nil, nil)
        try await expect(nil, "duplicate titles must not select a cached or newest conversation")
        sqlite3_exec(db, "UPDATE threads SET name = 'Renamed' WHERE id = 'A'", nil, nil, nil)
        state.setTitle("Renamed")
        try await expect(100, "custom name uniquely resolves the same conversation")
        state.setTitle("A")
        try await expect(nil, "old generated title cannot override custom name")
        try SessionTPSChecks.check(SessionLogIndex(home: home).conversationID(windowTitle: "x' OR 1=1--") == nil,
                                   "window title lookup uses SQL binding")
        state.setTitle("Renamed")
        try await expect(100, "restore A before focus checks")
        worker.setActive(false)
        try await Task.sleep(for: .milliseconds(150))
        let pausedProbes = state.probeCount(), pausedBuilds = state.buildCount()
        try await Task.sleep(for: .milliseconds(700))
        try SessionTPSChecks.check(state.probeCount() == pausedProbes && state.snapshot().tokensPerSecond == 100,
                                   "background focus pauses window probing and retains confirmed value")
        worker.setActive(true)
        try await Task.sleep(for: .milliseconds(700))
        try SessionTPSChecks.check(state.probeCount() > pausedProbes && state.buildCount() == pausedBuilds,
                                   "focus return reuses worker and reader without replay")
        state.setTitle("C")
        try await expect(300, "switch away before background log append")
        let log = home.appendingPathComponent("sessions/A.jsonl")
        let file = try FileHandle(forWritingTo: log); try file.seekToEnd()
        var startData = try SessionTPSChecks.line("event_msg", ["type": "task_started", "turn_id": "next"]); startData.append(10)
        try file.write(contentsOf: startData); try file.close()
        state.setTitle("Renamed")
        try await expect(nil, "cached A detects a newly started turn instead of displaying stale final value")
        try SessionTPSChecks.check(state.buildCount() == pausedBuilds, "new turn in cached log is consumed incrementally")
        let tailFile = try FileHandle(forWritingTo: log); try tailFile.seekToEnd()
        for (type, payload) in [("event_msg", ["type": "item_completed", "turn_id": "next", "item": ["id": "next", "type": "AgentMessage"], "started_at_ms": 0, "completed_at_ms": 1_000] as [String: Any]),
            ("token_usage_record", ["turn_id": "next", "response_id": "next", "usage": ["output_tokens": 100], "thread_token_usage": ["output_tokens": 200]]),
            ("event_msg", ["type": "task_complete", "turn_id": "next"])] {
            var line = try SessionTPSChecks.line(type, payload); line.append(10); try tailFile.write(contentsOf: line)
        }
        try tailFile.close()
        try await expect(100, "incremental watcher updates final value after cached turn completes")
        state.setTitle(nil)
        try await expect(nil, "persistent selection loss eventually clears rather than retaining stale data forever")
        state.setTitle("Renamed")
        try await expect(100, "selection recovery reuses cached parser")
        try SessionTPSChecks.check(!state.usedMainThreadProbe(), "all window probing runs off the UI thread")
        for (id, rate) in [("D", 400.0), ("E", 500), ("F", 600), ("G", 700)] {
            state.setTitle(id); state.emit(try event(id))
            try await expect(rate, "visit beyond the recent-reader cache")
        }
        let buildsAfterEviction = state.buildCount()
        state.setTitle("Renamed")
        try await expect(100, "evicted reader reloads safely")
        try SessionTPSChecks.check(state.buildCount() == buildsAfterEviction + 1, "reader cache remains bounded at four conversations")
        let lookup = SessionTitleLookup(home: home)
        for _ in 0..<100 { try SessionTPSChecks.check(lookup.lookup("Renamed") == .matched("A"), "stable exact title match") }
        try SessionTPSChecks.check(lookup.queryCount == 1, "100 stable samples execute only one title query")
        sqlite3_exec(db, "UPDATE threads SET name = 'Renamed' WHERE id = 'duplicate'", nil, nil, nil)
        try SessionTPSChecks.check(lookup.lookup("Renamed") == .ambiguous && lookup.queryCount == 2,
                                   "database changes invalidate the title map immediately")
        print("TPS performance checks: A-B-A reader builds=2; 100 title samples SQL queries=1; no transient dash; no foreground replay; UI-thread probes=0")
        print("Session selection self-test passed (A-B-A, cached revisits, multiple subscriptions, custom/duplicate/unknown titles, bound lookup)")

    }
}
