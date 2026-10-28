import Foundation

struct SessionTPSOptions: Equatable, Sendable {
    var menuBar = false
    var touchBar = false
    func needsObservation(touchBarAvailable: Bool, touchBarEnabled: Bool) -> Bool {
        menuBar || (touchBar && touchBarAvailable && touchBarEnabled)
    }
}

struct SessionTPSSnapshot: Equatable, Sendable {
    enum Phase: String, Sendable { case unavailable, waiting, generating, held, completed }
    var phase: Phase = .unavailable
    var tokensPerSecond: Double?
    var detail = "会话速度未开启"
    var rateText: String {
        guard let value = tokensPerSecond, value.isFinite, value > 0, value <= 100_000 else { return "—" }
        return "\(Int(value.rounded()))"
    }
    var displayText: String { "⚡ \(rateText) tok/s" }
    var toolTip: String { "\(detail)\n按本轮模型输出时间计算，含推理 token；在模型响应完成后更新。" }
    static func unavailable(_ reason: String) -> Self { .init(detail: reason) }
}

/// Only the numeric and identity fields needed by the observer are decoded.
/// Prompt, reasoning text, tool results and message content have no model here.
struct SessionTPSRecord: Decodable {
    let type: String
    let payload: Payload
    enum CodingKeys: String, CodingKey { case type, payload }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        if ["session_meta", "event_msg", "token_usage_record"].contains(type) {
            payload = try container.decode(Payload.self, forKey: .payload)
        } else { payload = Payload() }
    }
    struct Payload: Decodable {
        var type: String?
        var id: String?
        var originator: String?
        var source: String?
        var turn_id: String?
        var response_id: String?
        var started_at_ms: Int64?
        var completed_at_ms: Int64?
        var item: Item?
        var usage: Usage?
        var thread_token_usage: Usage?
        var info: Info?
        struct Item: Decodable { var type: String?; var id: String? }
        struct Usage: Decodable { var output_tokens: Int64? }
        struct Info: Decodable { var total_token_usage: Usage? }
        enum CodingKeys: String, CodingKey {
            case type, id, originator, source, turn_id, response_id, started_at_ms, completed_at_ms, item, usage, thread_token_usage, info
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            originator = try c.decodeIfPresent(String.self, forKey: .originator)
            // Subagent sources are objects, not strings, and deliberately do not qualify as root sessions.
            source = try? c.decode(String.self, forKey: .source)
            turn_id = try c.decodeIfPresent(String.self, forKey: .turn_id)
            response_id = try c.decodeIfPresent(String.self, forKey: .response_id)
            started_at_ms = try c.decodeIfPresent(Int64.self, forKey: .started_at_ms)
            completed_at_ms = try c.decodeIfPresent(Int64.self, forKey: .completed_at_ms)
            item = try c.decodeIfPresent(Item.self, forKey: .item)
            usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
            thread_token_usage = try c.decodeIfPresent(Usage.self, forKey: .thread_token_usage)
            info = try c.decodeIfPresent(Info.self, forKey: .info)
        }
    }
}
