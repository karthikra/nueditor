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

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Re-reads Settings and the address SSOT on the next call.
    func invalidateSettings() { settings = nil }

    /// Pins settings explicitly instead of resolving them from Settings and the address SSOT.
    func use(_ settings: NUEDITBackendSettings) { self.settings = settings }

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
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
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

    // MARK: - Plumbing

    private func request(path: String, method: String) async throws -> URLRequest {
        let settings = await currentSettings()
        guard let baseURL = settings.baseURL else { throw BackendError.notConfigured }
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw BackendError.transport("Bad backend URL for \(path).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = settings.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
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
