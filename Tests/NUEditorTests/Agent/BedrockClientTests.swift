import Foundation
import Synchronization
import Testing
@testable import NUEditor

final class CallCounter: Sendable {
    private let calls = Mutex(0)
    func increment() { calls.withLock { $0 += 1 } }
    var count: Int { calls.withLock { $0 } }
}

/// Builds event-stream frames the way Bedrock sends them, so decoding is tested against real framing.
enum EventStreamFixture {
    static func frame(headers: [String: String], payload: Data) -> Data {
        var headerBytes = Data()
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            headerBytes.append(UInt8(name.utf8.count))
            headerBytes.append(contentsOf: Array(name.utf8))
            headerBytes.append(7)
            let utf8 = Array(value.utf8)
            headerBytes.append(UInt8(utf8.count >> 8))
            headerBytes.append(UInt8(utf8.count & 0xFF))
            headerBytes.append(contentsOf: utf8)
        }
        let total = 12 + headerBytes.count + payload.count + 4
        var frame = Data()
        frame.append(contentsOf: bigEndian(UInt32(total)))
        frame.append(contentsOf: bigEndian(UInt32(headerBytes.count)))
        frame.append(contentsOf: bigEndian(AWSEventStream.crc32(frame)))
        frame.append(headerBytes)
        frame.append(payload)
        frame.append(contentsOf: bigEndian(AWSEventStream.crc32(frame)))
        return frame
    }

    static func chunk(_ event: [String: Any]) -> Data {
        let raw = try! JSONSerialization.data(withJSONObject: event)
        let payload = try! JSONSerialization.data(withJSONObject: ["bytes": raw.base64EncodedString()])
        return frame(headers: [":message-type": "event", ":event-type": "chunk", ":content-type": "application/json"], payload: payload)
    }

    static func exception(_ type: String, message: String) -> Data {
        frame(
            headers: [":message-type": "exception", ":exception-type": type],
            payload: try! JSONSerialization.data(withJSONObject: ["message": message])
        )
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

@Suite("AWSSigV4 — matches botocore")
struct AWSSigV4Tests {
    // Reference signatures produced by botocore's SigV4Auth for the same request and clock.
    @Test(arguments: [
        (nil as String?, "accept;content-type;host;x-amz-content-sha256;x-amz-date",
         "7d684623af1c72fc78e9178b62233b06be7aca2731f470abe7c6966a68647143"),
        ("SESSIONTOKENEXAMPLE", "accept;content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token",
         "4453ec7a66b5604107faa472f42c4052fe497c126bfd7a149af8fa4807e85d17"),
    ])
    func signsBedrockRequestsLikeTheAWSSDK(token: String?, signedHeaders: String, signature: String) throws {
        let url = try #require(URL(string: "https://bedrock-runtime.ap-northeast-1.amazonaws.com/model/global.anthropic.claude-haiku-4-5-20251001-v1%3A0/invoke-with-response-stream"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "accept")
        let credentials = AWSSigV4.Credentials(
            accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: token
        )
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-07T05:30:00Z"))
        AWSSigV4.sign(&request, body: Data(#"{"max_tokens":1}"#.utf8), credentials: credentials,
                      region: "ap-northeast-1", service: "bedrock", date: date)
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261107/ap-northeast-1/bedrock/aws4_request, SignedHeaders=\(signedHeaders), Signature=\(signature)")
    }

    // Non-S3 services sign the already-encoded path encoded again: `:` → `%3A` → `%253A`.
    @Test func theCanonicalPathIsEncodedTwice() {
        #expect(AWSSigV4.canonicalURI("/model/a-v1%3A0/invoke") == "/model/a-v1%253A0/invoke")
        #expect(AWSSigV4.canonicalURI("") == "/")
    }
}

@Suite("AWSEventStream — Bedrock framing")
struct AWSEventStreamTests {
    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(AWSEventStream.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func decodesAFrameDeliveredOneByteAtATime() throws {
        let frame = EventStreamFixture.chunk(["type": "ping"])
        var decoder = AWSEventStream.Decoder()
        var messages: [AWSEventStream.Message] = []
        for byte in frame {
            if let message = try decoder.append(byte) { messages.append(message) }
        }
        #expect(messages.count == 1)
        #expect(messages.first?.eventType == "chunk")
        #expect(!decoder.hasPartialMessage)
    }

    @Test func decodesSeveralFramesInOneRead() throws {
        var decoder = AWSEventStream.Decoder()
        let data = EventStreamFixture.chunk(["type": "a"]) + EventStreamFixture.chunk(["type": "b"])
        #expect(try decoder.append(data).count == 2)
    }

    @Test func aCorruptedPayloadIsRejected() throws {
        var frame = EventStreamFixture.chunk(["type": "ping"])
        frame[frame.count - 6] ^= 0xFF
        var decoder = AWSEventStream.Decoder()
        #expect(throws: AWSEventStream.DecodingError.self) { _ = try decoder.append(frame) }
    }

    @Test func aFrameClaimingAnAbsurdLengthIsRejectedBeforeBuffering() throws {
        var decoder = AWSEventStream.Decoder()
        let prelude: [UInt8] = [0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(throws: AWSEventStream.DecodingError.self) { _ = try decoder.append(Data(prelude)) }
    }

    @Test func aTruncatedStreamLeavesAPartialFrame() throws {
        var decoder = AWSEventStream.Decoder()
        _ = try decoder.append(EventStreamFixture.chunk(["type": "ping"]).prefix(20))
        #expect(decoder.hasPartialMessage)
    }
}

@Suite("BedrockClient — requests and stream events")
struct BedrockClientTests {
    private func events(_ frames: [Data]) throws -> [AnthropicStreamEvent] {
        var decoder = AWSEventStream.Decoder()
        var parser = AnthropicStreamParser()
        var out: [AnthropicStreamEvent] = []
        for message in try decoder.append(frames.reduce(Data(), +)) {
            out += try BedrockClient.events(in: message, parser: &parser)
        }
        return out
    }

    @Test func textAndStopReasonComeThroughAChunk() throws {
        let out = try events([
            EventStreamFixture.chunk(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Cut"]]),
            EventStreamFixture.chunk(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]),
        ])
        #expect(out == [.textDelta("Cut"), .messageStop(stopReason: .endTurn)])
    }

    @Test func toolInputIsAssembledAcrossDeltas() throws {
        let out = try events([
            EventStreamFixture.chunk(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "t1", "name": "split_clip"]]),
            EventStreamFixture.chunk(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": #"{"frame":"#]]),
            EventStreamFixture.chunk(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "48}"]]),
            EventStreamFixture.chunk(["type": "content_block_stop", "index": 1]),
        ])
        #expect(out == [.toolUseComplete(id: "t1", name: "split_clip", inputJSON: #"{"frame":48}"#)])
    }

    @Test func aBedrockExceptionEndsTheStreamWithItsType() {
        #expect(throws: AgentClientError.streamError("throttlingException: Too many requests")) {
            _ = try events([EventStreamFixture.exception("throttlingException", message: "Too many requests")])
        }
    }

    @Test func theBodyIsBedrockShaped() {
        let body = AnthropicRequestBody.build(model: .sonnet55, maxTokens: 10, system: "s", tools: [], messages: [])
        #expect(body["anthropic_version"] as? String == "bedrock-2023-05-31")
        #expect(body["model"] == nil)
        #expect(body["stream"] == nil)
    }

    @Test(arguments: AnthropicModel.allCases)
    func everyModelUsesItsGlobalInferenceProfile(model: AnthropicModel) {
        let client = BedrockClient(settings: BedrockSettings(profile: "", region: "ap-northeast-1"), model: model)
        #expect(client.endpoint()?.absoluteString ==
            "https://bedrock-runtime.ap-northeast-1.amazonaws.com/model/global.anthropic.\(model.rawValue)/invoke-with-response-stream")
    }

    // A versioned id like `…-v1:0` must reach Bedrock escaped, or the path names a different resource.
    @Test func modelIdsAreEscapedInThePath() {
        #expect(AWSSigV4.uriEncode("claude-x-v1:0") == "claude-x-v1%3A0")
    }

    @Test(arguments: [
        ("ap-northeast-1", true), ("us-gov-west-1", true), ("eu-central-2", true),
        ("", false), ("ap-northeast", false), ("evil.com/x-1", false), ("AP-NORTHEAST-1", false),
    ])
    func regionsAreValidatedBecauseTheyBecomeTheHost(region: String, valid: Bool) {
        #expect(BedrockSettings.isValidRegion(region) == valid)
    }

    @Test func anInvalidStoredRegionFallsBackToTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("evil.com/x", forKey: BedrockSettings.regionKey)
        #expect(BedrockSettings.load(from: defaults).region == BedrockSettings.defaultRegion)
    }
}

@Suite("BedrockClient — over the wire")
struct BedrockStreamTests {
    private static let credentials = AWSCredentialProvider.Resolved(
        credentials: AWSSigV4.Credentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: nil),
        expiration: nil
    )

    /// A unique fake region so the endpoint host is this test's alone.
    private func region() -> String {
        "zz-" + String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(8)) + "-1"
    }

    private func client(region: String, resolves: CallCounter = CallCounter()) -> BedrockClient {
        let provider = AWSCredentialProvider { _ in
            resolves.increment()
            return Self.credentials
        }
        return BedrockClient(
            settings: BedrockSettings(profile: "", region: region), model: .sonnet55,
            credentials: provider, session: StubHTTP.session()
        )
    }

    private func collect(_ client: BedrockClient) async throws -> [AnthropicStreamEvent] {
        var out: [AnthropicStreamEvent] = []
        for try await event in client.stream(system: "s", tools: [], messages: []) { out.append(event) }
        return out
    }

    @Test func streamsASignedRequestAndDecodesTheReply() async throws {
        let region = region()
        let host = "bedrock-runtime.\(region).amazonaws.com"
        let body = EventStreamFixture.chunk(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Done"]])
            + EventStreamFixture.chunk(["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
        StubHTTP.register(host: host) { _ in (200, body) }

        let out = try await collect(client(region: region))
        #expect(out == [.textDelta("Done"), .messageStop(stopReason: .endTurn)])
        let request = try #require(StubHTTP.requests(to: host).first)
        #expect(request.url.path == "/model/global.anthropic.claude-sonnet-5-5/invoke-with-response-stream")
        #expect(request.headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/") == true)
        #expect(request.headers["Authorization"]?.contains("/\(region)/bedrock/aws4_request") == true)
    }

    // A rejected signature is often stale credentials; the next attempt must resolve them again.
    @Test func aForbiddenReplySurfacesBedrocksMessageAndDropsTheCredentials() async throws {
        let region = region()
        StubHTTP.register(host: "bedrock-runtime.\(region).amazonaws.com") { _ in
            (403, Data(#"{"message":"The security token included in the request is expired"}"#.utf8))
        }
        let resolves = CallCounter()
        let client = client(region: region, resolves: resolves)
        for _ in 0..<2 {
            await #expect(throws: AgentClientError.httpError(status: 403, message: "The security token included in the request is expired")) {
                _ = try await collect(client)
            }
        }
        #expect(resolves.count == 2)
    }

    @Test func aStreamCutMidFrameIsAnError() async throws {
        let region = region()
        let frame = EventStreamFixture.chunk(["type": "ping"])
        StubHTTP.register(host: "bedrock-runtime.\(region).amazonaws.com") { _ in (200, frame.prefix(frame.count - 3)) }
        await #expect(throws: AWSEventStream.DecodingError.self) { _ = try await collect(client(region: region)) }
    }
}

@Suite("AWSCredentialProvider")
struct AWSCredentialProviderTests {
    @Test func readsTemporaryCredentialsWithTheirExpiry() throws {
        let json = Data(#"{"Version":1,"AccessKeyId":"ASIA1","SecretAccessKey":"s","SessionToken":"t","Expiration":"2026-11-07T06:00:00+00:00"}"#.utf8)
        let resolved = try AWSCredentialProvider.parse(json)
        #expect(resolved.credentials == AWSSigV4.Credentials(accessKeyId: "ASIA1", secretAccessKey: "s", sessionToken: "t"))
        #expect(resolved.expiration != nil)
    }

    @Test func longTermKeysHaveNoTokenAndNeverExpire() throws {
        let resolved = try AWSCredentialProvider.parse(Data(#"{"Version":1,"AccessKeyId":"AKIA1","SecretAccessKey":"s"}"#.utf8))
        #expect(resolved.credentials.sessionToken == nil)
        #expect(!AWSCredentialProvider.needsRefresh(resolved))
    }

    @Test func malformedOutputIsReportedNotUsed() {
        #expect(throws: AWSCredentialProvider.Failure.unreadable) {
            _ = try AWSCredentialProvider.parse(Data(#"{"AccessKeyId":""}"#.utf8))
        }
    }

    @Test func credentialsCloseToExpiryAreRefreshed() {
        let now = Date()
        let soon = AWSCredentialProvider.Resolved(
            credentials: AWSSigV4.Credentials(accessKeyId: "a", secretAccessKey: "s", sessionToken: "t"),
            expiration: now.addingTimeInterval(60)
        )
        #expect(AWSCredentialProvider.needsRefresh(soon, now: now))
    }

    @Test func resolvedCredentialsAreReusedUntilInvalidated() async throws {
        let calls = CallCounter()
        let provider = AWSCredentialProvider { _ in
            calls.increment()
            return AWSCredentialProvider.Resolved(
                credentials: AWSSigV4.Credentials(accessKeyId: "a", secretAccessKey: "s", sessionToken: nil), expiration: nil
            )
        }
        _ = try await provider.credentials(profile: "p")
        _ = try await provider.credentials(profile: "p")
        #expect(calls.count == 1)
        await provider.invalidate(profile: "p")
        _ = try await provider.credentials(profile: "p")
        #expect(calls.count == 2)
    }
}
