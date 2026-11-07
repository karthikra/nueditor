import Foundation

extension Notification.Name {
    static let bedrockSettingsChanged = Notification.Name("bedrockSettingsChanged")
}

/// Which AWS account and region the agent reaches Claude through.
struct BedrockSettings: Sendable, Equatable {
    static let defaultRegion = "ap-northeast-1"
    static let profileKey = "bedrockProfile"
    static let regionKey = "bedrockRegion"

    /// Empty defers to the AWS CLI's default chain.
    var profile: String
    var region: String

    static func load(from defaults: UserDefaults = .standard) -> BedrockSettings {
        let profile = defaults.string(forKey: profileKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        let region = defaults.string(forKey: regionKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return BedrockSettings(profile: profile, region: isValidRegion(region) ? region : defaultRegion)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(profile, forKey: Self.profileKey)
        defaults.set(region, forKey: Self.regionKey)
        NotificationCenter.default.post(name: .bedrockSettingsChanged, object: nil)
    }

    /// The region becomes part of the endpoint host, so it is checked rather than trusted.
    static func isValidRegion(_ region: String) -> Bool {
        region.wholeMatch(of: /[a-z]{2}(-[a-z]+)+-[0-9]{1,2}/) != nil
    }

    var endpointHost: String { "bedrock-runtime.\(region).amazonaws.com" }
}

/// Streams the agent's turns from Claude on Amazon Bedrock, signed with the user's AWS credentials.
struct BedrockClient: AgentClient {
    let settings: BedrockSettings
    let model: AnthropicModel
    var credentials: AWSCredentialProvider = .shared
    var session: URLSession = .shared
    var maxTokens: Int = 8192

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func endpoint() -> URL? {
        let modelPath = AWSSigV4.uriEncode(model.bedrockModelID)
        return URL(string: "https://\(settings.endpointHost)/model/\(modelPath)/invoke-with-response-stream")
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard let url = endpoint() else { throw AgentClientError.notConnected("Invalid Bedrock region.") }
        let body = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(
                model: model, maxTokens: maxTokens, system: system, tools: tools, messages: messages
            ),
            options: [.sortedKeys]
        )
        let signingCredentials: AWSSigV4.Credentials
        do {
            signingCredentials = try await credentials.credentials(profile: settings.profile)
        } catch {
            throw AgentClientError.notConnected(error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "accept")
        AWSSigV4.sign(&request, body: body, credentials: signingCredentials, region: settings.region, service: "bedrock")

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            if http.statusCode == 403 { await credentials.invalidate(profile: settings.profile) }
            throw AgentClientError.httpError(status: http.statusCode, message: Self.errorMessage(from: data))
        }

        var decoder = AWSEventStream.Decoder()
        var parser = AnthropicStreamParser()
        for try await byte in bytes {
            guard let message = try decoder.append(byte) else { continue }
            try Task.checkCancellation()
            for event in try Self.events(in: message, parser: &parser) { continuation.yield(event) }
        }
        if decoder.hasPartialMessage {
            throw AWSEventStream.DecodingError(reason: "stream ended mid-frame")
        }
    }

    /// One Bedrock frame: a `chunk` carries one Anthropic stream event, base64 inside JSON.
    static func events(
        in message: AWSEventStream.Message,
        parser: inout AnthropicStreamParser
    ) throws -> [AnthropicStreamEvent] {
        if message.messageType == "exception" {
            let kind = message.exceptionType ?? "exception"
            throw AgentClientError.streamError("\(kind): \(errorMessage(from: message.payload))")
        }
        guard message.eventType == "chunk",
              let wrapper = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
              let encoded = wrapper["bytes"] as? String,
              let raw = Data(base64Encoded: encoded),
              let event = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return [] }
        return try parser.consume(event)
    }

    /// Bedrock errors are `{"message": …}` (sometimes `Message`).
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (object["message"] ?? object["Message"]) as? String {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No details." : String(text.prefix(500))
    }
}
