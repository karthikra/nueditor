import Foundation

/// Storyboard scripts: NUEDIT reads AV scripts and shot lists (Google Sheets / Docs links, CSV,
/// XLSX, HTML) into beats. The editor only hands over the source and renders what comes back.
extension NUEDITBackendClient {
    /// Roles the tower assigns to script columns. Raw values are the tower's stable names.
    enum ScriptColumnRole: String, Codable, Sendable, CaseIterable {
        case label, scene, visual, audio
        case onScreenText = "on_screen_text"
        case sound, duration, notes
    }

    enum ScriptSource: Sendable, Equatable {
        /// A Google Sheets or Google Docs link shared with "anyone with the link" or published.
        case link(String)
        case file(URL)

        var fileContentType: String? {
            guard case .file(let url) = self else { return nil }
            switch url.pathExtension.lowercased() {
            case "csv": return "text/csv"
            case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            case "html", "htm": return "text/html"
            default: return nil
            }
        }
    }

    struct ScriptImportResponse: Decodable, Sendable, Equatable {
        let dryRun: Bool
        let warnings: [String]
        let scripts: [ImportedScript]
    }

    struct ImportedScript: Decodable, Sendable, Equatable {
        struct Source: Decodable, Sendable, Equatable {
            let kind: String
            let url: String?
            let filename: String?
            let tableIndex: Int?
        }

        struct Column: Decodable, Sendable, Equatable {
            let header: String
            /// Unknown roles from a newer tower decode as nil rather than failing the import.
            let role: ScriptColumnRole?

            enum CodingKeys: String, CodingKey { case header, role }

            init(header: String, role: ScriptColumnRole?) {
                self.header = header
                self.role = role
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                header = try container.decode(String.self, forKey: .header)
                role = (try? container.decodeIfPresent(String.self, forKey: .role)).flatMap { $0.flatMap(ScriptColumnRole.init(rawValue:)) }
            }
        }

        struct Beat: Decodable, Sendable, Equatable {
            let order: Int
            let label: String
            let scene: String
            let visual: String
            let audio: String
            let onScreenText: String
            let sound: String
            let notes: String
            let durationSeconds: Double?
            let startSeconds: Double?
            let scriptGap: Bool
            let sourceRow: Int
        }

        /// Nil on a dry run: nothing was stored.
        let scriptId: String?
        let title: String
        let source: Source
        let headerRow: Int
        let columns: [Column]
        let unmapped: [String]
        /// A preview: the first beats only. `beatCount` is the whole script.
        let beats: [Beat]
        let beatCount: Int
        let totalSeconds: Double?
        let warnings: [String]
    }

    /// Imports a script into the linked NUEDIT project, or with `dryRun` only reports what it would import.
    ///
    /// `mapping` pins roles to header text; a nil value unmaps that role. `stagingDirectory` holds a
    /// file upload's multipart body and is cleaned on every path.
    func importScript(
        projectId: String,
        source: ScriptSource,
        mapping: [ScriptColumnRole: String?] = [:],
        dryRun: Bool,
        title: String? = nil,
        stagingDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> ScriptImportResponse {
        let path = "/api/v1/projects/\(projectId)/scripts/import"
        let mappingObject: [String: Any] = Dictionary(uniqueKeysWithValues: mapping.map { role, header in
            (role.rawValue, header.map { $0 as Any } ?? NSNull())
        })
        var request = try await request(path: path, method: "POST")
        let response: (Data, URLResponse)
        switch source {
        case .link(let url):
            var body: [String: Any] = ["source": ["url": url], "dry_run": dryRun]
            if !mappingObject.isEmpty { body["mapping"] = mappingObject }
            if let title { body["title"] = title }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            response = try await data(for: request)
        case .file(let url):
            guard let contentType = source.fileContentType else {
                throw BackendError.api(status: 0, code: "unsupported_format",
                                       message: "Choose a .csv, .xlsx, or .html file.")
            }
            var fields = ["dry_run": dryRun ? "true" : "false"]
            if !mappingObject.isEmpty {
                fields["mapping"] = String(decoding: try JSONSerialization.data(withJSONObject: mappingObject), as: UTF8.self)
            }
            if let title { fields["title"] = title }
            let body = try MultipartFormData.write(
                fields: fields,
                files: [.init(name: "file", filename: url.lastPathComponent, contentType: contentType, fileURL: url)],
                in: stagingDirectory
            )
            defer { try? FileManager.default.removeItem(at: body.fileURL) }
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            response = try await upload(request, fromFile: body.fileURL)
        }
        try Self.validate(response: response.1, data: response.0)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decode(ScriptImportResponse.self, from: response.0, decoder: decoder)
    }
}
