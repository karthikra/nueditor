import Foundation

// MARK: - Shared value types

enum AnthropicModel: String, CaseIterable, Sendable {
    case sonnet55 = "claude-sonnet-5-5"
    case opus55 = "claude-opus-5-5"
    case haiku55 = "claude-haiku-5-5"

    var displayName: String {
        switch self {
        case .sonnet55: "Sonnet 5.5"
        case .opus55: "Opus 5.5"
        case .haiku55: "Haiku 5.5"
        }
    }

    /// Global cross-region inference profile; the raw value stays the persisted selection.
    var bedrockModelID: String { "global.anthropic.\(rawValue)" }

    var requestExtras: [String: Any] {
        switch self {
        case .sonnet55: ["output_config": ["effort": "low"]]
        default: [:]
        }
    }
}

enum AnthropicStopReason: String, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case pauseTurn = "pause_turn"
    case refusal = "refusal"
    case other
}

struct AnthropicMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [[String: Any]]
}

struct AnthropicToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum AnthropicStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case messageStop(stopReason: AnthropicStopReason)
}

enum AgentClientError: LocalizedError, Equatable {
    case notConnected(String)
    case httpError(status: Int, message: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let message): "Bedrock is not connected: \(message)"
        case .httpError(let status, let message): "Bedrock error (\(status)): \(message)"
        case .streamError(let message): "Stream error: \(message)"
        }
    }
}

/// Terminal failure of an agent stream, surfaced in the panel's error banner.
struct AgentStreamError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

// MARK: - Client protocol

protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error>
}

// MARK: - Usage logging

enum AgentUsageLog {
    static func record(_ usage: [String: Any]) {
        #if DEBUG
        let input = usage["input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let billed = input + cacheWrite + cacheRead
        let readPct = billed > 0 ? Int((Double(cacheRead) / Double(billed)) * 100) : 0
        print("[agent cache] input=\(input) cacheWrite=\(cacheWrite) cacheRead=\(cacheRead) (\(readPct)% read)")
        #endif
    }
}

// MARK: - Stream event parser

/// Turns Anthropic Messages stream events into agent events, assembling tool input across deltas.
struct AnthropicStreamParser {
    private var pendingTools: [Int: (id: String, name: String, json: String)] = [:]

    mutating func consume(_ event: [String: Any]) throws -> [AnthropicStreamEvent] {
        guard let type = event["type"] as? String else { return [] }
        switch type {
        case "message_start":
            if let message = event["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                AgentUsageLog.record(usage)
            }

        case "content_block_start":
            if let index = event["index"] as? Int,
               let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                pendingTools[index] = (id, name, "")
            }

        case "content_block_delta":
            guard let index = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { break }
            if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                return [.textDelta(text)]
            }
            if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String,
               var accumulated = pendingTools[index] {
                accumulated.json += partial
                pendingTools[index] = accumulated
            }

        case "content_block_stop":
            if let index = event["index"] as? Int, let tool = pendingTools.removeValue(forKey: index) {
                return [.toolUseComplete(id: tool.id, name: tool.name, inputJSON: tool.json.isEmpty ? "{}" : tool.json)]
            }

        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let raw = delta["stop_reason"] as? String {
                return [.messageStop(stopReason: AnthropicStopReason(rawValue: raw) ?? .other)]
            }

        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown stream error."
            throw AgentClientError.streamError(message)

        default: break
        }
        return []
    }
}

// MARK: - Request body builder

enum AnthropicRequestBody {
    static func build(
        model: AnthropicModel,
        maxTokens: Int,
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> [String: Any] {
        var toolBlocks: [[String: Any]] = tools.map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
        }
        // Prompt-cache boundary covers system + tools.
        if var last = toolBlocks.popLast() {
            last["cache_control"] = ["type": "ephemeral"]
            toolBlocks.append(last)
        }
        // Prompt-cache the conversation prefix
        var messageBlocks: [[String: Any]] = messages.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        if var lastMsg = messageBlocks.popLast(),
           var content = lastMsg["content"] as? [[String: Any]],
           var lastBlock = content.popLast() {
            lastBlock["cache_control"] = ["type": "ephemeral"]
            content.append(lastBlock)
            lastMsg["content"] = content
            messageBlocks.append(lastMsg)
        }
        // Bedrock takes the model in the URL and streams by endpoint, so neither is in the body.
        var body: [String: Any] = [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": maxTokens,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messageBlocks,
        ]
        if !toolBlocks.isEmpty { body["tools"] = toolBlocks }
        for (key, value) in model.requestExtras { body[key] = value }
        return body
    }
}
