import Foundation
import Testing
@testable import NUEditor

@Suite("NUEDITBackendSettings — address resolution")
struct NUEDITBackendSettingsTests {

    private func hubTOML(_ contents: String) throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("hub.toml")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func readsTheTowerAddressFromTheMachineSSOT() async throws {
        let file = try hubTOML("""
            token = "nuh_secret"
            url = "http://100.96.118.41:8011/mcp"
            api_url = "http://100.96.118.41:8000"
            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let settings = await NUEDITBackendSettingsStore.resolve(defaults: defaults, hubTOML: file, hasStoredAgentKey: { false })
        #expect(settings.baseURL?.absoluteString == "http://100.96.118.41:8000")
        #expect(settings.agentKey == nil)
    }

    // Reading the secret can raise a Keychain prompt; resolving settings must only learn that it exists.
    @Test func aStoredKeyResolvesWithoutReadingTheSecret() async throws {
        let file = try hubTOML(#"api_url = "http://tower:8000""#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let settings = await NUEDITBackendSettingsStore.resolve(defaults: defaults, hubTOML: file, hasStoredAgentKey: { true })
        #expect(settings.agentKey == .stored)
    }

    @Test func settingsOverrideWinsOverTheSSOT() async throws {
        let file = try hubTOML(#"api_url = "http://tower:8000""#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        defaults.set("http://127.0.0.1:9000", forKey: NUEDITBackendSettingsStore.baseURLOverrideKey)
        let settings = await NUEDITBackendSettingsStore.resolve(defaults: defaults, hubTOML: file, hasStoredAgentKey: { false })
        #expect(settings.baseURL?.absoluteString == "http://127.0.0.1:9000")
    }

    // No address anywhere means unconfigured — never a guessed host.
    @Test func missingAddressLeavesTheBackendUnconfigured() async throws {
        let file = try hubTOML(#"url = "http://tower:8011/mcp""#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let settings = await NUEDITBackendSettingsStore.resolve(defaults: defaults, hubTOML: file, hasStoredAgentKey: { false })
        #expect(settings.baseURL == nil)
        #expect(!settings.isConfigured)
    }

    @Test(arguments: [
        ("http://tower:8000/", "http://tower:8000"),
        ("http://tower:8000/api/v1", "http://tower:8000"),
        ("http://tower:8000/api/v1/", "http://tower:8000"),
        ("  http://tower:8000  ", "http://tower:8000"),
    ])
    func normalizesTrailingSlashAndApiSuffix(raw: String, expected: String) {
        #expect(NUEDITBackendSettingsStore.normalizedBaseURL(raw)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "tower:8000", "not a url"])
    func rejectsAddressesWithoutASchemeOrHost(raw: String) {
        #expect(NUEDITBackendSettingsStore.normalizedBaseURL(raw) == nil)
    }
}

@Suite("MultipartFormData")
struct MultipartFormDataTests {

    private func scratch() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writesFieldsAndFilesInOneStreamedBody() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proxy = dir.appendingPathComponent("vlm.mp4")
        try Data("PROXYBYTES".utf8).write(to: proxy)

        let body = try MultipartFormData.write(
            fields: ["metadata": #"{"checksum":"abc"}"#],
            files: [.init(name: "vlm_proxy", filename: "vlm_proxy.mp4", contentType: "video/mp4", fileURL: proxy)],
            in: dir,
            boundary: "BOUND"
        )
        defer { try? FileManager.default.removeItem(at: body.fileURL) }
        let text = try String(contentsOf: body.fileURL, encoding: .utf8)

        #expect(body.contentType == "multipart/form-data; boundary=BOUND")
        #expect(text.contains(#"Content-Disposition: form-data; name="metadata""#))
        #expect(text.contains(#"{"checksum":"abc"}"#))
        #expect(text.contains(#"name="vlm_proxy"; filename="vlm_proxy.mp4""#))
        #expect(text.contains("Content-Type: video/mp4"))
        #expect(text.contains("PROXYBYTES"))
        #expect(text.hasSuffix("--BOUND--\r\n"))
    }

    // A body that can't be assembled must not leave a half-written file behind for the uploader.
    @Test func leavesNothingBehindWhenAFileIsMissing() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            _ = try MultipartFormData.write(
                fields: [:],
                files: [.init(name: "audio", filename: "a.wav", contentType: "audio/wav",
                              fileURL: dir.appendingPathComponent("gone.wav"))],
                in: dir
            )
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.isEmpty, "staged body survived a failure: \(leftovers)")
    }
}

@Suite("NUEDITBackendClient — responses")
struct NUEDITBackendClientResponseTests {

    private func response(_ status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "http://tower:8000")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func acceptsSuccess() throws {
        try NUEDITBackendClient.validate(response: response(202), data: Data())
    }

    // The tower explains itself in `detail`; a bare status code would make a bad checksum
    // indistinguishable from a bad project id.
    @Test func surfacesTheTowerExplanation() {
        let data = Data(#"{"detail":"checksum is required for edge ingest"}"#.utf8)
        #expect(NUEDITBackendClient.detail(from: data) == "checksum is required for edge ingest")
        #expect(throws: BackendError.self) {
            try NUEDITBackendClient.validate(response: response(400), data: data)
        }
    }

    @Test func flattensValidationErrorLists() {
        let data = Data(#"{"detail":[{"loc":["body"],"msg":"field required","type":"value_error"}]}"#.utf8)
        #expect(NUEDITBackendClient.detail(from: data) == "field required")
    }

    @Test(arguments: [
        (#"{"detail":"Invalid agent key"}"#, BackendError.AuthFailure.rejectedKey),
        (#"{"detail":"Not authenticated"}"#, .missingKey),
        ("", .missingKey),
    ])
    func mapsUnauthorizedToTheActionTheUserMustTake(body: String, expected: BackendError.AuthFailure) {
        #expect {
            try NUEDITBackendClient.validate(response: response(401), data: Data(body.utf8))
        } throws: { error in
            guard case BackendError.unauthorized(let failure) = error else { return false }
            return failure == expected
        }
    }

    @Test func duplicateIsSuccessNotFailure() throws {
        let data = Data(#"{"id":"f-1","status":"duplicate","filename":"a.mov"}"#.utf8)
        let decoded = try JSONDecoder().decode(NUEDITBackendClient.EdgeRegisterResponse.self, from: data)
        #expect(decoded.isDuplicate)
        #expect(decoded.id == "f-1")
    }

    @Test func derivativeNamesMatchTheTowerContract() {
        // Keys and filenames are DERIVATIVES in the tower's core/edge_ingest.py.
        #expect(NUEDITBackendClient.Derivative.vlmProxy.rawValue == "vlm_proxy")
        #expect(NUEDITBackendClient.Derivative.vlmProxy.filename == "vlm_proxy.mp4")
        #expect(NUEDITBackendClient.Derivative.audio.rawValue == "audio")
        #expect(NUEDITBackendClient.Derivative.audio.filename == "audio_cleaned.wav")
        #expect(NUEDITBackendClient.Derivative.previewProxy.filename == "preview_proxy.mp4")
        #expect(NUEDITBackendClient.Derivative.thumbnail.filename == "thumbnail.jpg")
    }
}

@Suite("NUEDITBackendClient — agent key check")
struct NUEDITBackendAgentKeyCheckTests {

    private func client(status: Int, body: String, agentKey: String?) async -> (NUEDITBackendClient, String) {
        let host = StubHTTP.host { _ in (status, Data(body.utf8)) }
        let client = NUEDITBackendClient(session: StubHTTP.session())
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://\(host)"), agentKey: agentKey.map { .value($0) }))
        return (client, host)
    }

    @Test func noStoredKeyIsMissingWithoutAskingTheTower() async {
        let (client, host) = await client(status: 200, body: "[]", agentKey: nil)
        #expect(await client.checkAgentKey() == .missing)
        #expect(StubHTTP.requests(to: host).isEmpty)
    }

    @Test func anAuthenticatedReadAcceptsTheKey() async throws {
        let (client, host) = await client(status: 200, body: "[]", agentKey: "k-1")
        #expect(await client.checkAgentKey() == .accepted)
        let request = try #require(StubHTTP.requests(to: host).first)
        #expect(request.url.path == "/api/v1/agent/status")
        #expect(request.headers["X-Agent-Key"] == "k-1")
    }

    @Test func theTowersInvalidKeyDetailRejectsTheKey() async {
        let (client, _) = await client(status: 401, body: #"{"detail":"Invalid agent key"}"#, agentKey: "k-1")
        #expect(await client.checkAgentKey() == .rejected)
    }

    @Test func anUnreachableTowerLeavesTheKeyUnchecked() async {
        let client = NUEDITBackendClient()
        await client.use(NUEDITBackendSettings(baseURL: URL(string: "http://127.0.0.1:1"), agentKey: .value("k-1")))
        guard case .unknown = await client.checkAgentKey() else {
            Issue.record("an unreachable tower must not judge the key")
            return
        }
    }
}
