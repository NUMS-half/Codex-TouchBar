import Foundation
import SQLite3

/// Synthetic records only; shared by XCTest and the executable diagnostics on CLT-only systems.
enum SessionTPSChecks {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        let result = try value()
        try UsageMonitoringDiagnostics.check(result, message)
    }
    static func record(_ type: String, _ payload: [String: Any]) throws -> SessionTPSRecord {
        try JSONDecoder().decode(SessionTPSRecord.self, from: line(type, payload))
    }
    static func line(_ type: String, _ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
    }
    static func start(_ id: String = "turn") throws -> SessionTPSRecord { try record("event_msg", ["type": "task_started", "turn_id": id]) }
    static func item(_ id: String, _ type: String, _ a: Int64, _ b: Int64, turn: String = "turn") throws -> SessionTPSRecord {
        try record("event_msg", ["type": "item_completed", "turn_id": turn, "item": ["type": type, "id": id], "started_at_ms": a, "completed_at_ms": b])
    }
    static func usage(_ output: Int64, total: Int64? = nil, response: String = "response", turn: String = "turn") throws -> SessionTPSRecord {
        let cumulative = total ?? output
        return try record("token_usage_record", ["turn_id": turn, "response_id": response,
            "usage": ["output_tokens": output], "thread_token_usage": ["output_tokens": cumulative],
            "turn_token_usage": ["output_tokens": cumulative]])
    }
    static func acceptUsage(_ calculator: inout SessionTPSCalculator, usage: SessionTPSRecord) throws {
        calculator.consume(usage)
        calculator.consume(try record("event_msg", ["type": "token_count", "turn_id": usage.payload.turn_id!,
            "info": ["total_token_usage": ["output_tokens": usage.payload.thread_token_usage!.output_tokens!]]]))
    }
    static func calculator() throws {
        try check(SessionTPSSnapshot(phase: .completed, tokensPerSecond: 243).displayText == "⚡ 243 tok/s", "TPS uses the requested lightning icon and tok/s unit")
        var value = SessionTPSCalculator()
        value.consume(try start())
        try check(value.snapshot.tokensPerSecond == nil, "new turn waits for output")
        value.consume(try item("r", "Reasoning", 1_000, 6_000))
        value.consume(try item("a", "AgentMessage", 5_000, 11_000))
        try acceptUsage(&value, usage: usage(1_000))
        try check(value.modelSeconds == 10 && value.snapshot.tokensPerSecond == 100, "overlapping model intervals count once; reasoning not added twice")
        let initialUpdates = value.intervalUpdates
        for _ in 0..<50 { _ = value.snapshot; _ = value.modelSeconds }
        try check(value.intervalUpdates == initialUpdates, "reading or rendering a snapshot never updates model intervals again")
        value.consume(try item("zero", "Reasoning", 11_000, 11_000))
        try check(value.snapshot.tokensPerSecond == 100 && value.modelSeconds == 10, "millisecond-rounded zero-length item contributes zero without invalidating valid sample")
        value.consume(try record("event_msg", ["type": "token_count", "info": ["total_token_usage": ["output_tokens": 1_000]]]))
        try acceptUsage(&value, usage: usage(1_000))
        value.consume(try item("a", "AgentMessage", 5_000, 11_000))
        try check(value.snapshot.tokensPerSecond == 100, "duplicate carriers, response ids and item ids do not double TPS")
        value.consume(try item("tool", "CommandExecution", 12_000, 92_000))
        try check(value.snapshot.phase == .held && value.snapshot.tokensPerSecond == 100, "tool execution holds model rate without adding tool time")
        value.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        try check(value.snapshot.phase == .completed && value.snapshot.tokensPerSecond == 100, "completion retains final rate")
        value.consume(try start("next"))
        try check(value.snapshot.tokensPerSecond == nil, "new turn never reuses previous speed")
        value.consume(try item("late", "AgentMessage", 0, 5_000))
        try acceptUsage(&value, usage: usage(5_000))
        try check(value.snapshot.tokensPerSecond == nil, "late records from prior turn ignored")
        value.consume(try item("next-a", "AgentMessage", 20_000, 22_000, turn: "next"))
        try acceptUsage(&value, usage: usage(400, total: 1_400, response: "next-response", turn: "next"))
        try check(value.snapshot.tokensPerSecond == 200, "thread cumulative copy in turn_token_usage never inflates later turn")

        var gap = SessionTPSCalculator()
        gap.consume(try start()); gap.consume(try item("x", "Reasoning", 1_000, 2_000))
        gap.consume(try item("tool", "McpToolCall", 2_000, 11_000))
        gap.consume(try item("y", "AgentMessage", 11_000, 13_000)); try acceptUsage(&gap, usage: usage(900))
        try check(gap.snapshot.tokensPerSecond == 300, "tools between model windows do not bridge intervals")
        var short = SessionTPSCalculator()
        short.consume(try start()); short.consume(try item("x", "AgentMessage", 1_000, 1_100)); try acceptUsage(&short, usage: usage(50))
        try check(short.snapshot.tokensPerSecond == nil, "very short sample suppressed")
        var restored = SessionTPSCalculator(fromBeginning: false)
        restored.consume(try item("x", "AgentMessage", 1_000, 3_000)); try acceptUsage(&restored, usage: usage(500))
        try check(restored.snapshot.tokensPerSecond == nil, "half-observed turn never reports a speed")
        var identical = SessionTPSCalculator()
        identical.consume(try start()); identical.consume(try item("x", "AgentMessage", 1_000, 3_000))
        try acceptUsage(&identical, usage: usage(200)); identical.consume(try item("y", "AgentMessage", 4_000, 6_000))
        try acceptUsage(&identical, usage: usage(200, total: 400, response: "second"))
        try check(identical.snapshot.tokensPerSecond == 100, "distinct responses with identical usage both count")
        try acceptUsage(&identical, usage: usage(200, total: 50, response: "reset"))
        try check(identical.snapshot.tokensPerSecond == nil, "cumulative reset invalidates turn")
        var legacy = SessionTPSCalculator()
        legacy.consume(try start()); legacy.consume(try item("x", "AgentMessage", 1_000, 3_000))
        legacy.consume(try record("event_msg", ["type": "token_count", "info": ["total_token_usage": ["output_tokens": 600]]]))
        try check(legacy.snapshot.tokensPerSecond == 300, "legacy cumulative-only usage supported")
        legacy.consume(try item("bad", "Reasoning", 3_000, 2_000))
        try check(legacy.snapshot.tokensPerSecond == nil, "invalid timing invalidates whole turn")
        var split = SessionTPSCalculator()
        split.consume(try start()); split.consume(try item("a", "AgentMessage", 0, 1_000))
        try acceptUsage(&split, usage: usage(100))
        split.consume(try item("b", "AgentMessage", 2_000, 3_000))
        try check(split.snapshot.tokensPerSecond == 100 && split.snapshot.phase == .held, "item before delayed usage holds confirmed rate")
        split.consume(try usage(100, total: 200, response: "b"))
        try check(split.snapshot.tokensPerSecond == 100, "usage awaits response boundary before commit")
        try acceptUsage(&split, usage: usage(100, total: 200, response: "b"))
        split.consume(try usage(200, total: 400, response: "c"))
        try check(split.snapshot.tokensPerSecond == 100 && split.snapshot.phase == .held, "usage before delayed item holds confirmed rate")
        split.consume(try item("c", "Reasoning", 4_000, 5_000))
        split.consume(try item("d", "AgentMessage", 5_000, 6_000))
        try acceptUsage(&split, usage: usage(200, total: 400, response: "c"))
        try check(split.snapshot.tokensPerSecond == 100, "only complete response progress becomes a measurement")
        split.consume(try record("event_msg", ["type": "item_completed", "item": ["id": "unclassified"]]))
        try check(split.snapshot.tokensPerSecond == nil, "missing item type invalidates turn instead of silently losing model time")
        var unknown = SessionTPSCalculator()
        unknown.consume(try start()); unknown.consume(try item("known", "AgentMessage", 0, 2_000))
        unknown.consume(try item("future", "NewModelOutputType", 2_000, 4_000))
        try acceptUsage(&unknown, usage: usage(800))
        try check(unknown.snapshot.tokensPerSecond == nil, "unknown item category cannot silently shrink denominator")
        var lostCounter = SessionTPSCalculator()
        lostCounter.consume(try record("event_msg", ["type": "token_count", "info": ["total_token_usage": ["output_tokens": 100]]]))
        lostCounter.invalidate() // The missing line could have contained a newer cumulative total.
        lostCounter.consume(try start()); lostCounter.consume(try item("a", "AgentMessage", 0, 1_000))
        lostCounter.consume(try record("event_msg", ["type": "token_count", "info": ["total_token_usage": ["output_tokens": 300]]]))
        try check(lostCounter.snapshot.tokensPerSecond == nil, "corruption revokes legacy baseline across next turn")
    }

    static func capacityAndIntervalOrder() throws {
        var ordered = SessionTPSCalculator()
        ordered.consume(try start())
        for (id, start, end) in [("later", 4_000, 7_000), ("early", 0, 2_000),
                                 ("bridge", 1_000, 5_000), ("separate", 9_000, 10_000),
                                 ("inside", 3_000, 4_000)] {
            ordered.consume(try item(id, "AgentMessage", Int64(start), Int64(end)))
        }
        try check(ordered.modelSeconds == 8, "out-of-order, overlapping and contained intervals form a correct union")
        var overlappingResponses = SessionTPSCalculator()
        overlappingResponses.consume(try start())
        overlappingResponses.consume(try item("first", "AgentMessage", 0, 2_000))
        try acceptUsage(&overlappingResponses, usage: usage(100))
        overlappingResponses.consume(try item("second", "Reasoning", 0, 2_000))
        try acceptUsage(&overlappingResponses, usage: usage(200, total: 300, response: "second"))
        overlappingResponses.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        try check(overlappingResponses.snapshot.tokensPerSecond == 150 && overlappingResponses.snapshot.phase == .completed,
                  "new output with fully overlapping timing updates the final average")

        var samples = SessionTPSCalculator()
        samples.consume(try start())
        var covered = Set<Int>(), random: UInt64 = 42
        for index in 0..<300 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let first = Int((random >> 16) % 5_000)
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let last = first + Int((random >> 16) % 500)
            covered.formUnion(first..<last)
            samples.consume(try item("random-\(index)", "AgentMessage", Int64(first), Int64(last)))
        }
        try check(abs(samples.modelSeconds - Double(covered.count) / 1_000) < 0.000_001,
                  "interval union agrees with independent millisecond coverage for mixed ordering")
        var extreme = SessionTPSCalculator()
        extreme.consume(try start())
        extreme.consume(try item("large timestamp", "AgentMessage", Int64.max - 1_000, Int64.max))
        try check(extreme.modelSeconds == 1, "large valid timestamps retain millisecond precision")

        var items = SessionTPSCalculator()
        items.consume(try start())
        for index in 0..<4_096 {
            let time = Int64(index) * 1_000
            items.consume(try item("item-\(index)", "AgentMessage", time, time + 1_000))
        }
        items.consume(try item("item-0", "AgentMessage", 0, 1_000))
        items.consume(try usage(4_096))
        items.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        try check(items.modelSeconds == 4_096 && items.snapshot.tokensPerSecond == 1,
                  "duplicate timing at the capacity limit remains valid and is not counted twice")
        items.consume(try item("overflow", "AgentMessage", 4_096_000, 4_097_000))
        try check(items.snapshot.tokensPerSecond == nil, "new timing beyond the limit invalidates safely")

        var responses = SessionTPSCalculator()
        responses.consume(try start())
        responses.consume(try item("output", "AgentMessage", 0, 1_000))
        for index in 0..<4_096 {
            responses.consume(try usage(1, total: Int64(index + 1), response: "response-\(index)"))
        }
        responses.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        responses.consume(try usage(1, total: 4_096, response: "response-0"))
        try check(responses.snapshot.tokensPerSecond == 4_096,
                  "duplicate usage at the capacity limit retains the final measurement")
        responses.consume(try usage(1, total: 4_097, response: "overflow"))
        try check(responses.snapshot.tokensPerSecond == nil, "new usage beyond the limit invalidates safely")
    }

    static func independentCarriers() throws {
        var value = SessionTPSCalculator()
        // These counters have different lifetime origins but identical per-turn deltas.
        value.consume(try start("previous"))
        value.consume(try usage(500, total: 5_000, turn: "previous"))
        value.consume(try record("event_msg", ["type": "token_count", "turn_id": "previous",
            "info": ["total_token_usage": ["output_tokens": 1_000]]]))
        value.consume(try start())
        value.consume(try item("a", "AgentMessage", 0, 2_000))
        value.consume(try usage(200, total: 5_200))
        value.consume(try record("event_msg", ["type": "token_count", "turn_id": "turn",
            "info": ["total_token_usage": ["output_tokens": 1_200]]]))
        try check(value.snapshot.tokensPerSecond == 100, "independent lifetime counters agree on turn delta without a false reset")
        value.consume(try item("b", "AgentMessage", 3_000, 4_000))
        value.consume(try usage(400, total: 5_600, response: "second"))
        value.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        try check(value.snapshot.tokensPerSecond == 200 && value.snapshot.phase == .completed,
                  "final modern usage supplies complete turn average before delayed legacy carrier")
        value.consume(try record("event_msg", ["type": "token_count", "turn_id": "turn",
            "info": ["total_token_usage": ["output_tokens": 1_600]]]))
        try check(value.snapshot.tokensPerSecond == 200, "late matching carrier retains final average")
        value.consume(try item("b", "AgentMessage", 3_000, 4_000))
        value.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        try check(value.snapshot.tokensPerSecond == 200, "duplicate completion does not clear final value")
        value.consume(try start("next"))
        try check(value.snapshot.tokensPerSecond == nil && value.snapshot.phase == .waiting, "next turn clears previous final value immediately")
        var delayed = SessionTPSCalculator()
        delayed.consume(try start())
        delayed.consume(try item("first", "AgentMessage", 0, 2_000))
        try acceptUsage(&delayed, usage: usage(200))
        delayed.consume(try item("last", "AgentMessage", 3_000, 4_000))
        delayed.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        try check(delayed.snapshot.tokensPerSecond == 100 && delayed.snapshot.phase == .held,
                  "completion before final usage holds confirmed value rather than a dash")
        delayed.consume(try usage(200))
        try check(delayed.snapshot.tokensPerSecond == 100 && delayed.snapshot.phase == .held,
                  "duplicate old usage cannot finalize a pending denominator")
        delayed.consume(try usage(400, total: 600, response: "last"))
        try check(delayed.snapshot.tokensPerSecond == 200 && delayed.snapshot.phase == .completed,
                  "delayed usage upgrades held value to the final average")
        var delayedItem = SessionTPSCalculator()
        delayedItem.consume(try start())
        delayedItem.consume(try item("first", "AgentMessage", 0, 2_000))
        try acceptUsage(&delayedItem, usage: usage(200))
        delayedItem.consume(try usage(400, total: 600, response: "last"))
        delayedItem.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        try check(delayedItem.snapshot.tokensPerSecond == 100, "usage before final timing does not invent a shorter denominator")
        delayedItem.consume(try item("first", "AgentMessage", 0, 2_000))
        try check(delayedItem.snapshot.tokensPerSecond == 100 && delayedItem.snapshot.phase == .held,
                  "duplicate old timing cannot finalize pending usage")
        delayedItem.consume(try item("last", "AgentMessage", 3_000, 4_000))
        try check(delayedItem.snapshot.tokensPerSecond == 200 && delayedItem.snapshot.phase == .completed,
                  "delayed final item after completion updates final average")
        var lateTiming = SessionTPSCalculator()
        lateTiming.consume(try start())
        lateTiming.consume(try item("first", "AgentMessage", 0, 1_000))
        lateTiming.consume(try usage(300))
        lateTiming.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        try check(lateTiming.snapshot.tokensPerSecond == 300, "completion commits currently available complete counters")
        lateTiming.consume(try item("last", "AgentMessage", 1_000, 3_000))
        try check(lateTiming.snapshot.tokensPerSecond == 100 && lateTiming.snapshot.phase == .completed,
                  "late timing alone corrects final denominator without new token count")
        var lateUsage = SessionTPSCalculator()
        lateUsage.consume(try start())
        lateUsage.consume(try item("all", "AgentMessage", 0, 3_000))
        lateUsage.consume(try usage(300))
        lateUsage.consume(try record("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        lateUsage.consume(try usage(300, total: 600, response: "last"))
        try check(lateUsage.snapshot.tokensPerSecond == 200 && lateUsage.snapshot.phase == .completed,
                  "late usage alone corrects final numerator without new model time")
        // A regression within either carrier still invalidates this turn.
        value.consume(try item("next", "AgentMessage", 5_000, 6_000, turn: "next"))
        value.consume(try usage(100, total: 5_500, turn: "next"))
        try check(value.snapshot.tokensPerSecond == nil, "real modern counter regression remains rejected")
    }

    static func frames() throws {
        let message: [String: Any] = ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": "window",
            "params": ["conversationId": "fixture", "hostId": "local", "following": true]]
        let body = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(body.count).littleEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }; packet.append(body)
        var decoder = CodexIPCFrames()
        try check(try decoder.append(packet.prefix(2)).isEmpty, "partial frame header retained")
        try check(try decoder.append(packet.dropFirst(2).prefix(9)).isEmpty, "partial frame body retained")
        var rest = Data(packet.dropFirst(11)); rest.append(packet)
        let events = try decoder.append(rest)
        try check(events.count == 2 && events.allSatisfy { $0.params?.conversationId == "fixture" }, "fragmented and coalesced frames decoded")
        do { _ = try decoder.append(Data([255,255,255,255])); throw UsageMonitoringDiagnostics.CheckFailure(message: "oversized frame accepted") }
        catch CodexIPCFrames.FrameError.invalid {}
    }

    static func reader() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tps-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rollout.jsonl")
        let meta = try line("session_meta", ["id": "fixture", "originator": "codex_work_desktop", "source": "vscode"])
        func serialized(_ record: SessionTPSRecord) throws -> Data {
            let p = record.payload
            var payload: [String: Any] = [:]
            if let type = p.type { payload["type"] = type }
            if let turn = p.turn_id { payload["turn_id"] = turn }
            if let item = p.item { payload["item"] = ["id": item.id!, "type": item.type!] }
            if let a = p.started_at_ms { payload["started_at_ms"] = a }
            if let b = p.completed_at_ms { payload["completed_at_ms"] = b }
            if let total = p.thread_token_usage?.output_tokens { payload["thread_token_usage"] = ["output_tokens": total] }
            if let output = p.usage?.output_tokens { payload["usage"] = ["output_tokens": output] }
            if let response = p.response_id { payload["response_id"] = response }
            return try line(record.type, payload)
        }
        var data = meta; data.append(10)
        for record in [try start(), try item("a", "AgentMessage", 1_000, 3_000)] { data.append(try serialized(record)); data.append(10) }
        let output = try serialized(usage(600)); data.append(output.prefix(output.count / 2))
        try data.write(to: url)
        let reader = SessionRolloutReader(url: url, conversationID: "fixture")
        try check(try reader.update().tokensPerSecond == nil, "half-written usage is retained, not parsed")
        let previousRecoveryPasses = reader.recoveryPasses
        reader.prepareForCaching() // Drop partial raw text; resume from its original file offset.
        let file = try FileHandle(forWritingTo: url); try file.seekToEnd()
        var tail = Data(output.dropFirst(output.count / 2)); tail.append(10)
        tail.append(try line("event_msg", ["type": "task_complete", "turn_id": "turn"])); tail.append(10)
        try file.write(contentsOf: tail); try file.close()
        try check(try reader.update().tokensPerSecond == 300, "incremental reader completes partial line")
        try check(reader.recoveryPasses == previousRecoveryPasses, "partial checkpoint resumes without a recovery replay")
        let previousBytes = reader.bytesRead, previousRecords = reader.decodedRecords
        reader.prepareForCaching()
        try check(try reader.update().tokensPerSecond == 300, "unchanged file keeps reading stable")
        try check(reader.bytesRead == previousBytes && reader.decodedRecords == previousRecords,
                  "unchanged cached log reads zero bytes and decodes zero records")
        let previousIdentity = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        let original = try Data(contentsOf: url)
        let rewritten = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "600", with: "300").utf8)
        try check(rewritten.count == original.count, "same-length rewrite fixture")
        let overwrite = try FileHandle(forWritingTo: url); try overwrite.write(contentsOf: rewritten); try overwrite.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: url.path)
        try check((try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber) == previousIdentity,
                  "rewrite keeps inode")
        try check(try reader.update().tokensPerSecond == 150, "same-inode same-length rewrite invalidates cached calculator")
        try (meta + Data([10])).write(to: url)
        try check(try reader.update().tokensPerSecond == nil, "truncation clears old sample")
        var damaged = meta + Data([10])
        for record in [try start(), try item("valid", "AgentMessage", 0, 2_000)] {
            damaged.append(try serialized(record)); damaged.append(10)
        }
        let malformed = try line("event_msg", ["type": "item_completed", "turn_id": "turn", "item": ["id": "bad", "type": "AgentMessage"], "started_at_ms": "corrupt"])
        var ending = try serialized(usage(1_000)); ending.append(10)
        ending.append(try line("event_msg", ["type": "task_complete", "turn_id": "turn"])); ending.append(10)
        try (damaged + malformed + Data([10]) + ending).write(to: url, options: .atomic)
        try check(try reader.update().tokensPerSecond == nil, "malformed model item invalidates current turn")
        let oversized = Data(repeating: 120, count: SessionRolloutReader.chunkLimit + 1)
        try (damaged + oversized + Data([10]) + ending).write(to: url, options: .atomic)
        try check(try reader.update().tokensPerSecond == nil, "oversized skipped record invalidates current turn")
        let sub = try line("session_meta", ["id": "fixture", "originator": "codex_work_desktop", "source": ["subagent": "test"]]) + Data([10])
        try sub.write(to: url, options: .atomic)
        do { _ = try reader.update(); throw UsageMonitoringDiagnostics.CheckFailure(message: "subagent accepted") }
        catch SessionRolloutReader.ReaderError.unsupported {}
        do { _ = try reader.update(); throw UsageMonitoringDiagnostics.CheckFailure(message: "repeated invalid identity accepted") }
        catch SessionRolloutReader.ReaderError.unsupported {}
    }

    static func index() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tps-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var database: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else { throw SessionRolloutReader.ReaderError.unavailable }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER)", nil, nil, nil)
        let log = home.appendingPathComponent("sessions/fixture.jsonl")
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "INSERT INTO threads VALUES ('fixture', ?, 0)", -1, &statement, nil)
        sqlite3_bind_text(statement, 1, log.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(statement); sqlite3_finalize(statement)
        let index = SessionLogIndex(home: home)
        try check(index.resolve(conversationID: "fixture") == log.resolvingSymlinksInPath(), "read-only index resolves exact thread")
        try check(index.resolve(conversationID: "x' OR 1=1--") == nil, "thread id is bound, never SQL syntax")
        let outside = home.appendingPathComponent("outside.jsonl")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: log.path, withDestinationPath: outside.path)
        try check(index.resolve(conversationID: "fixture") == nil, "symlink escaping sessions root rejected")
    }

    static func run() -> Bool {
        do { try calculator(); try capacityAndIntervalOrder(); try independentCarriers(); try frames(); try reader(); try index(); print("Session TPS self-test passed (union timing, capacity boundaries, response boundaries, carriers, turns, frames, incremental/untrusted files, read-only index)"); return true }
        catch { print("Session TPS self-test failed: \(error)"); return false }
    }
}
