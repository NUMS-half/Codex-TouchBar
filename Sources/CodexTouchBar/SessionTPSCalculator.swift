import Foundation

/// Per-turn throughput from official counters and a union of model-output windows.
struct SessionTPSCalculator {
    private(set) var turnID: String?
    private var completeStart = false
    private var cumulative: Int64?
    private var baseline: Int64?
    private var legacyCumulative: Int64?
    private var legacyBaseline: Int64?
    private var hasModernUsage = false
    private var responses: [String: Int64] = [:]
    private var responseTotal: Int64 = 0
    private(set) var modelSeconds: Double = 0
    private(set) var intervalUpdates = 0
    private var intervals: [String: (Int64, Int64)] = [:]
    private var mergedIntervals: [(Int64, Int64)] = []
    private var modelMilliseconds: Int64 = 0
    private var invalid = false
    private var phase = SessionTPSSnapshot.Phase.waiting
    private var committed: (output: Int64, seconds: Double, itemCount: Int, value: Double)?

    init(fromBeginning: Bool = true) {
        cumulative = fromBeginning ? 0 : nil
        legacyCumulative = fromBeginning ? 0 : nil
    }

    var hasCompleteStart: Bool { completeStart }
    private mutating func addInterval(_ a: Int64, _ b: Int64) {
        guard b > a else { return }
        var lower = 0, upper = mergedIntervals.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if mergedIntervals[middle].1 < a { lower = middle + 1 } else { upper = middle }
        }
        var start = a, end = b, index = lower
        while index < mergedIntervals.count && mergedIntervals[index].0 <= end {
            let existing = mergedIntervals[index]
            modelMilliseconds -= existing.1 - existing.0
            start = min(start, existing.0); end = max(end, existing.1)
            index += 1
        }
        mergedIntervals.replaceSubrange(lower..<index, with: [(start, end)])
        modelMilliseconds += end - start
        modelSeconds = Double(modelMilliseconds) / 1_000
    }

    private var output: Int64? {
        // The two lifetime counters have independent origins. Prefer modern usage
        // for this turn, and compare its delta only with its own response records.
        let total = hasModernUsage ? cumulative : legacyCumulative
        let base = hasModernUsage ? baseline : legacyBaseline
        let delta = base.flatMap { base in total.flatMap { $0 >= base ? $0 - base : nil } }
        // A delayed carrier can temporarily disagree. Never pick the larger count and invent a rate.
        if let delta, !responses.isEmpty, responseTotal != delta {
            return nil
        }
        return delta ?? (responses.isEmpty ? nil : responseTotal)
    }

    var snapshot: SessionTPSSnapshot {
        guard turnID != nil else { return .init(phase: .waiting, detail: "等待当前对话输出") }
        guard completeStart, !invalid else { return .unavailable("当前轮次记录不完整，等待下一轮") }
        guard let committed else {
            return .init(phase: .waiting, detail: modelSeconds > 0 && modelSeconds < 0.5 ? "模型输出时间不足 0.5 秒" : "等待模型响应完成")
        }
        let pending = output != committed.output || modelSeconds != committed.seconds
        let displayPhase = pending ? SessionTPSSnapshot.Phase.held : phase
        let description: String
        switch displayPhase {
        case .completed: description = "上一轮 · 模型平均输出速度"
        case .held: description = phase == .completed ? "本轮结束 · 最终统计同步中，保留上次测量" : "上次测量 · 等待后续模型响应"
        default: description = "当前轮 · 模型平均输出速度"
        }
        return .init(phase: displayPhase, tokensPerSecond: committed.value, detail: description)
    }

    mutating func invalidate() {
        invalid = true; cumulative = nil; baseline = nil
        legacyCumulative = nil; legacyBaseline = nil
    }

    /// token_count is written at a model-response boundary after its items. Modern-only
    /// logs without this carrier are finalized at task_complete instead of guessing a boundary.
    private mutating func commitMeasurement(finalUpdate: Bool = false) {
        guard completeStart, !invalid, let output, output > 0, modelSeconds >= 0.5 else { return }
        if let committed {
            // A later response can be fully contained in an existing model window;
            // a newly observed item is still progress even when the union is unchanged.
            let responseProgress = output > committed.output
                && (modelSeconds > committed.seconds || intervals.count > committed.itemCount)
            // An event arriving after completion may fill in just the final timing
            // or usage. Recompute only forward progress; duplicates remain inert.
            let finalCorrection = finalUpdate && phase == .completed
                && output >= committed.output && modelSeconds >= committed.seconds
                && (output != committed.output || modelSeconds != committed.seconds)
            guard responseProgress || finalCorrection else { return }
        }
        let value = Double(output) / modelSeconds
        guard value.isFinite, value > 0, value <= 100_000 else { invalidate(); return }
        committed = (output, modelSeconds, intervals.count, value)
    }

    mutating func consume(_ record: SessionTPSRecord) {
        let p = record.payload
        if record.type == "event_msg", p.type == "task_started" {
            guard let id = p.turn_id, !id.isEmpty, id.count <= 128 else { invalidate(); return }
            guard turnID != id else { return }
            turnID = id; completeStart = true; baseline = cumulative
            legacyBaseline = legacyCumulative; hasModernUsage = false
            responses.removeAll(); responseTotal = 0; intervals.removeAll(); mergedIntervals.removeAll()
            modelMilliseconds = 0; modelSeconds = 0; invalid = false; phase = .waiting; committed = nil
            return
        }
        guard record.type == "event_msg" || record.type == "token_usage_record" else { return }
        if let id = p.turn_id, id != turnID {
            // Unseen start or a late record from a different turn: it must not contaminate this turn.
            if turnID != nil { return }
            turnID = id
        }
        if record.type == "token_usage_record" {
            let previousOutput = output
            if p.usage?.output_tokens != nil || p.thread_token_usage?.output_tokens != nil { hasModernUsage = true }
            if let id = p.response_id, let count = p.usage?.output_tokens {
                if count < 0 { invalidate() }
                else if let previous = responses[id], previous != count { invalidate() }
                else if responses[id] == nil {
                    let sum = responseTotal.addingReportingOverflow(count)
                    if responses.count >= 4_096 || sum.overflow { invalidate() }
                    else { responses[id] = count; responseTotal = sum.partialValue }
                }
            }
            updateCumulative(p.thread_token_usage?.output_tokens, modern: true)
            if phase == .completed { commitMeasurement(finalUpdate: output != previousOutput) }
            return
        }
        switch p.type {
        case "token_count":
            let previousOutput = output
            updateCumulative(p.info?.total_token_usage?.output_tokens, modern: false)
            commitMeasurement(finalUpdate: !hasModernUsage && output != previousOutput)
        case "item_completed":
            guard let kind = p.item?.type else { invalidate(); return }
            guard kind == "Reasoning" || kind == "AgentMessage" else {
                let tools = ["UserMessage", "CommandExecution", "McpToolCall", "FileChange", "WebSearch", "ImageView", "Extension", "Plan", "ContextCompaction", "SubAgentActivity"]
                if !tools.contains(kind) { invalidate(); return }
                if phase == .generating { phase = .held }; return
            }
            guard let id = p.item?.id, let a = p.started_at_ms, let b = p.completed_at_ms,
                  a >= 0, b >= a, b - a <= 86_400_000 else {
                invalidate(); return
            }
            if let old = intervals[id], old != (a, b) { invalidate(); return }
            let previousSeconds = modelSeconds
            if intervals[id] == nil {
                guard intervals.count < 4_096 else { invalidate(); return }
                intervals[id] = (a, b)
                addInterval(a, b); intervalUpdates += 1
            }
            if phase == .completed { commitMeasurement(finalUpdate: modelSeconds != previousSeconds) }
            else { phase = .generating }
        case "task_complete": phase = .completed; commitMeasurement()
        case "turn_aborted": invalidate()
        default: break
        }
    }

    private mutating func updateCumulative(_ count: Int64?, modern: Bool) {
        guard let count else { return }
        let previous = modern ? cumulative : legacyCumulative
        if count < 0 || previous.map({ count < $0 }) == true { invalidate(); return }
        if modern { cumulative = count } else { legacyCumulative = count }
    }
}
