import Foundation

/// REST client for the NUEDIT tower — the Phase-4 reverse channel.
///
/// One typed method per endpoint the editor actually calls; nothing speculative. Contract read
/// from the tower's own source (`app/views/v1/footage.py`, `app/core/edge_ingest.py`), which
/// outranks the spec doc wherever they disagree.
actor NUEDITBackendClient {
    static let shared = NUEDITBackendClient()

    private let session: URLSession
    private var settings: NUEDITBackendSettings?
    private var storedAgentKey: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Re-reads Settings and the address SSOT on the next call.
    func invalidateSettings() {
        settings = nil
        storedAgentKey = nil
    }

    /// Pins settings explicitly instead of resolving them from Settings and the address SSOT.
    func use(_ settings: NUEDITBackendSettings) {
        self.settings = settings
        storedAgentKey = nil
    }

    func currentSettings() async -> NUEDITBackendSettings {
        if let settings { return settings }
        let resolved = await NUEDITBackendSettingsStore.resolve()
        settings = resolved
        return resolved
    }

    // MARK: - Health

    /// True when the tower answers. Never throws: reachability is a state the UI shows, not an error.
    func isReachable() async -> Bool {
        guard let request = try? await request(path: "/health", method: "GET") else { return false }
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) { Log.app.warning("tower health HTTP \(status)") }
            return (200..<300).contains(status)
        } catch {
            Log.app.warning("tower health unreachable: \(Log.detail(error))")
            return false
        }
    }

    enum AgentKeyCheck: Sendable, Equatable {
        case accepted
        case missing
        case rejected
        /// The check itself could not run: no tower configured, or no answer.
        case unknown(String)
    }

    /// One parameter-free authenticated read, so Settings can judge the key before any upload.
    func checkAgentKey() async -> AgentKeyCheck {
        guard await currentSettings().agentKey != nil else { return .missing }
        do {
            let request = try await request(path: "/api/v1/agent/status", method: "GET")
            let (data, response) = try await data(for: request)
            try Self.validate(response: response, data: data)
            return .accepted
        } catch BackendError.unauthorized(let failure) {
            return failure == .rejectedKey ? .rejected : .missing
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    // MARK: - Edge ingest

    struct EdgeIngestMeta: Codable, Sendable, Equatable {
        var filename: String
        var duration_ms: Int
        var checksum: String
        var checksum_algo: String = "sha256"
        var codec: String?
        var frame_rate: Double?
        var resolution_width: Int?
        var resolution_height: Int?
        var file_size_bytes: Int?
        var has_audio: Bool = true
        var volume_uuid: String?
        var volume_label: String?
        var volume_relative_path: String?
        var mount_point: String?
    }

    /// The derivatives the tower accepts. The camera original is never one of them.
    enum Derivative: String, Sendable, CaseIterable {
        case vlmProxy = "vlm_proxy"
        case audio
        case previewProxy = "preview_proxy"
        case thumbnail

        var filename: String {
            switch self {
            case .vlmProxy: "vlm_proxy.mp4"
            case .previewProxy: "preview_proxy.mp4"
            case .audio: "audio_cleaned.wav"
            case .thumbnail: "thumbnail.jpg"
            }
        }

        var contentType: String {
            switch self {
            case .vlmProxy, .previewProxy: "video/mp4"
            case .audio: "audio/wav"
            case .thumbnail: "image/jpeg"
            }
        }
    }

    struct EdgeRegisterResponse: Codable, Sendable, Equatable {
        let id: String
        let status: String
        let filename: String?

        /// The tower returns `duplicate` when this checksum is already registered — success, and the
        /// reason a re-import must not upload again.
        var isDuplicate: Bool { status == "duplicate" }
    }

    /// Registers footage prepared here: metadata plus derivatives only. Requires at least one of
    /// `vlm_proxy` or `audio`, which the tower enforces and this checks first so a pointless
    /// upload never starts.
    ///
    /// `stagingDirectory` holds the multipart body while it uploads; it is removed on every path.
    func edgeRegister(
        projectId: String,
        metadata: EdgeIngestMeta,
        derivatives: [Derivative: URL],
        stagingDirectory: URL
    ) async throws -> EdgeRegisterResponse {
        guard derivatives[.vlmProxy] != nil || derivatives[.audio] != nil else {
            throw BackendError.api(
                status: 400, code: "no_derivative",
                message: "edge-register needs at least a vlm_proxy or an audio derivative."
            )
        }
        guard !metadata.checksum.isEmpty else {
            throw BackendError.api(
                status: 400, code: "no_checksum",
                message: "edge-register needs the original's checksum."
            )
        }
        let encoder = JSONEncoder()
        let metadataJSON = String(decoding: try encoder.encode(metadata), as: UTF8.self)
        let parts = derivatives.keys.sorted { $0.rawValue < $1.rawValue }.map { key in
            MultipartFormData.FilePart(
                name: key.rawValue, filename: key.filename,
                contentType: key.contentType, fileURL: derivatives[key]!
            )
        }
        let body = try MultipartFormData.write(
            fields: ["metadata": metadataJSON], files: parts, in: stagingDirectory
        )
        defer { try? FileManager.default.removeItem(at: body.fileURL) }

        var request = try await request(
            path: "/api/v1/projects/\(projectId)/footage/edge-register", method: "POST"
        )
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await upload(request, fromFile: body.fileURL)
        try Self.validate(response: response, data: data)
        return try decode(EdgeRegisterResponse.self, from: data)
    }

    struct FootageStatus: Codable, Sendable, Equatable {
        let id: String
        let filename: String?
        let status: String
        let proxy: String?
        let transcript: String?
        let embedding: String?
    }

    func footageStatus(projectId: String, footageId: String) async throws -> FootageStatus {
        let request = try await request(
            path: "/api/v1/projects/\(projectId)/footage/\(footageId)/status", method: "GET"
        )
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
        return try decode(FootageStatus.self, from: data)
    }

    // MARK: - Archive (camera originals → S3)

    enum ArchiveGrant: Sendable, Equatable {
        /// PUT the original to `url` sending exactly `headers`: the signature covers them.
        case upload(key: String, url: URL, headers: [String: String])
        /// The tower declined: already archived, opted out, or no checksum on record.
        case skipped(reason: String, archiveStatus: String?)
    }

    /// The header the tower's signer bakes in when its response doesn't list any.
    static let defaultArchiveHeaders = ["Content-Type": "application/octet-stream"]

    private struct ArchivePresignBody: Decodable {
        let key: String?
        let url: String?
        let headers: [String: String]?
        let skipped: Bool?
        let reason: String?
        let archive_status: String?
    }

    /// Moves the tower's row to `uploading`; every grant must be followed by `completeArchive`.
    func presignArchive(footageId: String, expiresIn: Int) async throws -> ArchiveGrant {
        let request = try await request(
            path: "/api/v1/footage/\(footageId)/archive/presign?expires_in=\(expiresIn)", method: "POST"
        )
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
        let body = try decode(ArchivePresignBody.self, from: data)
        if body.skipped == true {
            return .skipped(reason: body.reason ?? "skipped", archiveStatus: body.archive_status)
        }
        guard let key = body.key, let text = body.url, let url = URL(string: text) else {
            throw BackendError.transport("The tower's archive grant has no upload URL.")
        }
        return .upload(key: key, url: url, headers: body.headers ?? Self.defaultArchiveHeaders)
    }

    enum ArchiveCompletion: Sendable, Equatable {
        case archived(uri: String)
        case notArchived(String)
    }

    private struct ArchiveCompleteBody: Decodable {
        let archived: Bool?
        let uri: String?
        let error: String?
    }

    /// Asks the tower to verify the object in S3. Also the release after a failed PUT: with no
    /// object there the tower marks the row failed, which makes it retryable.
    func completeArchive(footageId: String, key: String) async throws -> ArchiveCompletion {
        var request = try await request(path: "/api/v1/footage/\(footageId)/archive/complete", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["key": key])
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
        let body = try decode(ArchiveCompleteBody.self, from: data)
        if body.archived == true, let uri = body.uri { return .archived(uri: uri) }
        return .notArchived(body.error ?? "The tower did not record the archive.")
    }

    // MARK: - Multipart archive (originals over S3's 5 GB single-PUT cap)

    struct MultipartPlan: Sendable, Equatable, Codable {
        let key: String
        let uploadId: String
        let partSize: Int
        let partCount: Int

        /// Every byte lands in exactly one part, and no part is empty.
        func covers(_ size: Int) -> Bool {
            guard partSize > 0, partCount > 0, size > 0 else { return false }
            let (total, overflow) = partSize.multipliedReportingOverflow(by: partCount)
            return !overflow && total >= size && total - partSize < size
        }
    }

    enum MultipartStart: Sendable, Equatable {
        case upload(MultipartPlan)
        case skipped(reason: String, archiveStatus: String?)
    }

    private struct MultipartStartBody: Decodable {
        let key: String?
        let upload_id: String?
        let part_size: Int?
        let part_count: Int?
        let skipped: Bool?
        let reason: String?
        let archive_status: String?
    }

    /// Moves the tower's row to `uploading`. The tower keeps no multipart state: the caller persists the plan.
    func startMultipartArchive(footageId: String) async throws -> MultipartStart {
        let request = try await request(path: "/api/v1/footage/\(footageId)/archive/multipart", method: "POST")
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
        let body = try decode(MultipartStartBody.self, from: data)
        if body.skipped == true {
            return .skipped(reason: body.reason ?? "skipped", archiveStatus: body.archive_status)
        }
        guard let key = body.key, let uploadId = body.upload_id, let partSize = body.part_size,
              let partCount = body.part_count, partSize > 0, partCount > 0 else {
            throw BackendError.transport("The tower's multipart plan is incomplete.")
        }
        return .upload(MultipartPlan(key: key, uploadId: uploadId, partSize: partSize, partCount: partCount))
    }

    struct PartGrant: Sendable, Equatable {
        let partNumber: Int
        let url: URL
        let headers: [String: String]
    }

    private struct PartsBody: Decodable {
        struct Part: Decodable {
            let part_number: Int
            let url: String
            let headers: [String: String]?
        }
        let parts: [Part]
    }

    /// Signs one part; the SHA-256 is bound into the signature, so S3 rejects bytes that differ.
    func presignArchivePart(
        footageId: String, uploadId: String, partNumber: Int, checksumSHA256: String, expiresIn: Int
    ) async throws -> PartGrant {
        var request = try await request(
            path: "/api/v1/footage/\(footageId)/archive/multipart/parts?expires_in=\(expiresIn)", method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "upload_id": uploadId,
            "parts": [["part_number": partNumber, "checksum_sha256": checksumSHA256]],
        ])
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
        let body = try decode(PartsBody.self, from: data)
        guard let part = body.parts.first(where: { $0.part_number == partNumber }), let url = URL(string: part.url) else {
            throw BackendError.transport("The tower did not sign part \(partNumber).")
        }
        return PartGrant(partNumber: partNumber, url: url, headers: part.headers ?? [:])
    }

    /// PUTs one part to S3 and returns its ETag, which `complete` needs.
    func uploadPart(_ bytes: Data, grant: PartGrant) async throws -> String {
        var request = URLRequest(url: grant.url)
        request.httpMethod = "PUT"
        for (name, value) in grant.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await upload(request, from: bytes)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("S3 returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = Self.s3ErrorCode(from: data) ?? "http_\(http.statusCode)"
            throw BackendError.api(
                status: http.statusCode, code: code,
                message: "S3 rejected part \(grant.partNumber) (HTTP \(http.statusCode), \(code))."
            )
        }
        guard let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
            throw BackendError.transport("S3 accepted part \(grant.partNumber) without an ETag.")
        }
        return etag
    }

    struct CompletedPart: Sendable, Equatable, Codable {
        let partNumber: Int
        let etag: String
        let checksumSHA256: String
    }

    /// Assembles the parts; the tower then verifies and records exactly as for a single PUT.
    func completeMultipartArchive(
        footageId: String, uploadId: String, parts: [CompletedPart]
    ) async throws -> ArchiveCompletion {
        var request = try await request(
            path: "/api/v1/footage/\(footageId)/archive/multipart/complete", method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "upload_id": uploadId,
            "parts": parts.sorted { $0.partNumber < $1.partNumber }.map {
                ["part_number": $0.partNumber, "etag": $0.etag, "checksum_sha256": $0.checksumSHA256]
            },
        ])
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
        let body = try decode(ArchiveCompleteBody.self, from: data)
        if body.archived == true, let uri = body.uri { return .archived(uri: uri) }
        return .notArchived(body.error ?? "The tower did not record the archive.")
    }

    /// Stops the parts billing; the tower marks the original retryable.
    func abortMultipartArchive(footageId: String, uploadId: String) async throws {
        var request = try await request(path: "/api/v1/footage/\(footageId)/archive/multipart/abort", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["upload_id": uploadId])
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
    }

    /// Streams the original from disk to a presigned URL. No tower credential: S3 rejects a request
    /// that carries a second authentication mechanism.
    func uploadOriginal(_ fileURL: URL, to url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await upload(request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("S3 returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.api(
                status: http.statusCode, code: Self.s3ErrorCode(from: data) ?? "http_\(http.statusCode)",
                message: "S3 rejected the upload (HTTP \(http.statusCode)\(Self.s3ErrorCode(from: data).map { ", \($0)" } ?? ""))."
            )
        }
    }

    /// S3 errors are XML: `<Error><Code>SignatureDoesNotMatch</Code>…`.
    static func s3ErrorCode(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<Code>"), let end = text.range(of: "</Code>", range: start.upperBound..<text.endIndex)
        else { return nil }
        let code = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    // MARK: - Plumbing

    static let agentKeyHeader = "X-Agent-Key"
    /// The tower's fixed 401 detail for a bad, revoked, or orphaned key (`views/v1/auth.py`).
    static let agentKeyInvalidDetail = "Invalid agent key"

    private func request(path: String, method: String) async throws -> URLRequest {
        let settings = await currentSettings()
        guard let baseURL = settings.baseURL else { throw BackendError.notConfigured }
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw BackendError.transport("Bad backend URL for \(path).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let agentKey = await agentKey(for: settings) {
            request.setValue(agentKey, forHTTPHeaderField: Self.agentKeyHeader)
        }
        return request
    }

    private func agentKey(for settings: NUEDITBackendSettings) async -> String? {
        switch settings.agentKey {
        case .value(let key): return key
        case nil: return nil
        case .stored:
            if let storedAgentKey { return storedAgentKey }
            let loaded = await NUEDITBackendSettingsStore.loadAgentKey()
            // Revalidate: Settings may have changed the key while the read waited on a prompt.
            guard self.settings == settings else { return loaded }
            storedAgentKey = loaded
            return loaded
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
    }

    private func upload(_ request: URLRequest, fromFile url: URL) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, fromFile: url)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
    }

    private func upload(_ request: URLRequest, from bytes: Data) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, from: bytes)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BackendError.transport("The tower returned a response this build can't read: \(error.localizedDescription)")
        }
    }

    /// FastAPI reports failures as `{"detail": ...}`; surface that rather than a bare status code.
    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transport("The tower returned a non-HTTP response.")
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 {
            throw BackendError.unauthorized(detail(from: data) == agentKeyInvalidDetail ? .rejectedKey : .missingKey)
        }
        throw BackendError.api(
            status: http.statusCode,
            code: "http_\(http.statusCode)",
            message: detail(from: data) ?? "The tower returned HTTP \(http.statusCode)."
        )
    }

    static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] else { return nil }
        if let text = detail as? String { return text }
        // Validation errors arrive as a list of {loc, msg, type}.
        if let items = detail as? [[String: Any]] {
            let messages = items.compactMap { $0["msg"] as? String }
            if !messages.isEmpty { return messages.joined(separator: "; ") }
        }
        return nil
    }
}
