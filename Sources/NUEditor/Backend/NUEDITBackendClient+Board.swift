import Foundation

/// The storyboard board: NUEDIT's beats, each with its coverage by footage, plus the footage no
/// beat uses. The tower scores and stores everything; the editor renders it and sends corrections.
extension NUEDITBackendClient {
    struct ScriptSummary: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let createdAt: String?
    }

    struct Board: Decodable, Sendable, Equatable {
        enum Matching: String, Decodable, Sendable {
            case done
            case notRun = "not_run"
            /// Matched before a scoring change; must be re-run.
            case stale
        }

        enum Coverage: String, Decodable, Sendable, CaseIterable {
            case covered, weak, missing
            case scriptGap = "script_gap"
        }

        struct Counts: Decodable, Sendable, Equatable {
            let covered: Int
            let weak: Int
            let missing: Int
            let scriptGap: Int
        }

        struct Match: Decodable, Sendable, Equatable {
            enum Source: String, Decodable, Sendable { case auto, override }
            let footageId: String
            let startMs: Int
            let endMs: Int
            /// The moment to show on a card; the editor grabs it from its own preview proxy.
            let frameMs: Int
            let confidence: Double?
            let source: Source
            let overrideId: String?
            let label: String?
        }

        struct Beat: Decodable, Sendable, Equatable, Identifiable {
            let sectionId: String
            let order: Int
            let label: String?
            let scene: String?
            let visual: String?
            let audio: String?
            let onScreenText: String?
            let sound: String?
            let notes: String?
            let durationSeconds: Double?
            let coverage: Coverage
            let bestConfidence: Double?
            let matches: [Match]
            /// False after a refresh changed the beat, until matching runs again; nil from older towers.
            let matched: Bool?

            var id: String { sectionId }
        }

        struct UnusedFootage: Decodable, Sendable, Equatable {
            let footageId: String
            let startMs: Int
            let endMs: Int
            let frameMs: Int
            let label: String?
            /// Left out on purpose by an `unused` override.
            let intentional: Bool
        }

        struct Override: Decodable, Sendable, Equatable {
            let overrideId: String
            let beatId: String?
            let action: String
            let footageId: String
            let startMs: Int?
            let endMs: Int?
        }

        let scriptId: String
        let title: String
        let threshold: Double
        let weakFloor: Double?
        let matching: Matching
        let counts: Counts
        let beats: [Beat]
        let unusedFootage: [UnusedFootage]
        let overrides: [Override]
    }

    enum OverrideAction: String, Sendable {
        /// This footage (range) is the beat.
        case assign
        /// Not this footage (range) for the beat.
        case reject
        /// This footage (range) is left out on purpose; no beat.
        case unused
    }

    /// Progress of a background job the tower reports as events.
    struct JobProgress: Decodable, Sendable, Equatable {
        struct Event: Decodable, Sendable, Equatable {
            let sequence: Int
            let event: String
            let status: String?
            let payload: [String: JSONValue]?
        }
        let events: [Event]
        let latestSequence: Int
        let isComplete: Bool
        /// Present for re-caption progress only.
        let running: Bool?
    }

    struct RecaptionStart: Decodable, Sendable, Equatable {
        /// `queued` or `nothing_to_do`.
        let status: String
        let footageCount: Int
        let sinceSequence: Int
    }

    func scripts(projectId: String) async throws -> [ScriptSummary] {
        try await get("/api/v1/projects/\(projectId)/scripts", as: [ScriptSummary].self)
    }

    func board(scriptId: String) async throws -> Board {
        try await get("/api/v1/scripts/\(scriptId)/board", as: Board.self)
    }

    func addOverride(
        scriptId: String, action: OverrideAction, beatId: String?, footageId: String, startMs: Int?, endMs: Int?
    ) async throws -> Board {
        var body: [String: Any] = ["action": action.rawValue, "footage_id": footageId]
        if let beatId { body["beat_id"] = beatId }
        if let startMs { body["start_ms"] = startMs }
        if let endMs { body["end_ms"] = endMs }
        return try await send("/api/v1/scripts/\(scriptId)/board/overrides", method: "POST", body: body, as: Board.self)
    }

    func removeOverride(scriptId: String, overrideId: String) async throws -> Board {
        try await send("/api/v1/scripts/\(scriptId)/board/overrides/\(overrideId)", method: "DELETE", body: nil, as: Board.self)
    }

    /// Starts matching every beat to the project's footage; follow it with `matchProgress`.
    func startMatching(scriptId: String, projectId: String) async throws {
        struct Started: Decodable { let status: String }
        _ = try await send("/api/v1/scripts/\(scriptId)/match?project_id=\(projectId)", method: "POST", body: nil, as: Started.self)
    }

    func matchProgress(scriptId: String, since: Int) async throws -> JobProgress {
        try await get("/api/v1/scripts/\(scriptId)/match_webhooks?since_sequence=\(since)", as: JobProgress.self)
    }

    /// Describes footage the captioner hasn't, so it can be matched. 409 while one is running.
    func startRecaption(projectId: String) async throws -> RecaptionStart {
        try await send("/api/v1/projects/\(projectId)/recaption", method: "POST", body: nil, as: RecaptionStart.self)
    }

    func recaptionProgress(projectId: String, since: Int) async throws -> JobProgress {
        try await get("/api/v1/projects/\(projectId)/recaption_webhooks?since_sequence=\(since)", as: JobProgress.self)
    }

    // MARK: - Refresh

    /// What a refresh did, or would do on a dry run, to the script's beats.
    struct RefreshReport: Decodable, Sendable, Equatable {
        struct BeatChange: Decodable, Sendable, Equatable {
            /// `added`, `changed`, or `unchanged`.
            let status: String
            let order: Int
            let label: String?
            let sectionId: String?
            let changes: [String]
        }

        struct RemovedBeat: Decodable, Sendable, Equatable {
            let sectionId: String
            let order: Int
            let label: String?
            let visual: String?
            let matchesLost: Int
            let overridesLost: Int
        }

        let dryRun: Bool
        let added: Int
        let changed: Int
        let unchanged: Int
        let removed: Int
        let beats: [BeatChange]
        let removedBeats: [RemovedBeat]
        /// Beats left without matches until matching runs again.
        let rematch: [String]
        let warnings: [String]
    }

    /// Re-reads the script's source and updates its beats in place. A linked Google source needs no
    /// file; a script imported from a file needs the revised file, else the tower answers `file_required`.
    func refreshScript(
        scriptId: String, file: URL?, dryRun: Bool, stagingDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> RefreshReport {
        let path = "/api/v1/scripts/\(scriptId)/refresh"
        var request = try await request(path: path, method: "POST")
        let response: (Data, URLResponse)
        if let file {
            guard let contentType = ScriptSource.file(file).fileContentType else {
                throw BackendError.api(status: 0, code: "unsupported_format", message: "Choose a .csv, .xlsx, or .html file.")
            }
            let body = try MultipartFormData.write(
                fields: ["dry_run": dryRun ? "true" : "false"],
                files: [.init(name: "file", filename: file.lastPathComponent, contentType: contentType, fileURL: file)],
                in: stagingDirectory
            )
            defer { try? FileManager.default.removeItem(at: body.fileURL) }
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            response = try await upload(request, fromFile: body.fileURL)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["dry_run": dryRun])
            response = try await data(for: request)
        }
        try Self.validate(response: response.1, data: response.0)
        return try decode(RefreshReport.self, from: response.0, decoder: Self.snakeCaseDecoder)
    }

    // MARK: - Plumbing

    private static var snakeCaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let request = try await request(path: path, method: "GET")
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
        return try decode(type, from: data, decoder: Self.snakeCaseDecoder)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any]?, as type: T.Type) async throws -> T {
        var request = try await request(path: path, method: method)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await data(for: request)
        try Self.validate(response: response, data: data)
        return try decode(type, from: data, decoder: Self.snakeCaseDecoder)
    }
}

/// Loosely typed JSON for event payloads whose shape varies by event.
enum JSONValue: Decodable, Sendable, Equatable {
    case number(Double), string(String), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    var number: Double? { if case .number(let value) = self { value } else { nil } }
}
