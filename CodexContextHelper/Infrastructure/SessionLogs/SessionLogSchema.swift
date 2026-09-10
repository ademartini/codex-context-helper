import Foundation

/// A numeric-only projection: unknown payload keys are never hydrated into application objects.
enum SessionLogSchema {
    static let version = "session-0.153.4-v1"
    // The required four /status oracle comparisons are not yet available. Never infer this from a setting.
    static let occupancyVerified = false

    enum Record {
        case metadata(id: String, version: String, agentName: String?, parentID: String?, forkID: String?)
        case model(String)
        case counters(ContextSnapshot, Date)
        case contextReset
        case ignored
    }
    private struct Counters: Decodable {
        let input_tokens: Int64
        let cached_input_tokens: Int64
        let output_tokens: Int64
        let reasoning_output_tokens: Int64
        let total_tokens: Int64
        func validated() throws -> TokenCounters {
            let sum = input_tokens.addingReportingOverflow(output_tokens)
            guard !sum.overflow, sum.partialValue == total_tokens,
                  let result = TokenCounters(input: input_tokens, cachedInput: cached_input_tokens, output: output_tokens,
                                             reasoningOutput: reasoning_output_tokens, total: total_tokens) else { throw SchemaError.invalid }
            return result
        }
    }
    private struct Info: Decodable {
        let last_token_usage: Counters
        let total_token_usage: Counters
        let model_context_window: Int64
    }
    private struct Envelope: Decodable {
        let record: Record
        enum Keys: String, CodingKey { case type, payload, timestamp }
        enum Payload: String, CodingKey { case type, id, cli_version, model, info, agent_nickname, parent_thread_id, forked_from_id }
        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: Keys.self)
            let type = try root.decode(String.self, forKey: .type)
            // Compacted history replaces the context. Its summary/content is deliberately never decoded.
            if type == "compacted" { record = .contextReset; return }
            guard ["session_meta", "turn_context", "event_msg"].contains(type) else { record = .ignored; return }
            let payload = try root.nestedContainer(keyedBy: Payload.self, forKey: .payload)
            switch type {
            case "session_meta":
                record = .metadata(id: try payload.decode(String.self, forKey: .id), version: try payload.decode(String.self, forKey: .cli_version),
                                   agentName: try payload.decodeIfPresent(String.self, forKey: .agent_nickname).map { String($0.prefix(256)) },
                                   parentID: try payload.decodeIfPresent(String.self, forKey: .parent_thread_id),
                                   forkID: try payload.decodeIfPresent(String.self, forKey: .forked_from_id))
            case "turn_context": record = .model(try payload.decode(String.self, forKey: .model))
            default:
                guard try payload.decode(String.self, forKey: .type) == "token_count" else { record = .ignored; return }
                // A null info is an account-limit-only event, not a context observation.
                guard let info = try payload.decodeIfPresent(Info.self, forKey: .info) else { record = .ignored; return }
                let timestamp = try root.decode(String.self, forKey: .timestamp)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fractional = formatter.date(from: timestamp)
                formatter.formatOptions = [.withInternetDateTime]
                guard let date = fractional ?? formatter.date(from: timestamp),
                      let context = try ContextSnapshot(latestResponse: info.last_token_usage.validated(),
                                                       cumulative: info.total_token_usage.validated(), modelContextWindow: info.model_context_window) else {
                    throw SchemaError.invalid
                }
                record = .counters(context, date)
            }
        }
    }
    enum SchemaError: Error { case invalid }
    static func decode(_ data: Data) throws -> Record { try JSONDecoder().decode(Envelope.self, from: data).record }
}
