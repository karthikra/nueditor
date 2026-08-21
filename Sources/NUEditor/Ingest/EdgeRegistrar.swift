import Foundation

/// Registers locally-prepared footage with the tower: metadata plus the small derivatives.
/// The camera original never crosses the network — that is the entire point of edge ingest.
///
/// Offline is a normal state, not a failure: with no tower, no link, or no answer, the footage
/// stays fully usable here and registers on a later pass.
enum EdgeRegistrar {
    /// What the tower needs alongside the metadata. Preview is sent when we have it (it makes a
    /// better web-side scrub), but vlm + audio are what the pipeline actually reads.
    static let uploadedKinds: [ProxyKind] = [.vlm, .audio, .preview]

    enum Outcome: Sendable, Equatable {
        case registered(footageId: String, duplicate: Bool)
        /// Nothing was attempted: no tower configured, no project link, or no derivatives yet.
        case skipped(String)
        case failed(String)
    }

    struct Request: Sendable {
        let projectId: String
        let filename: String
        let durationMilliseconds: Int
        let identity: FootageIdentity
        let frameRate: Double?
        let width: Int?
        let height: Int?
        let hasAudio: Bool
        let derivatives: [ProxyKind: URL]
    }

    static func register(
        _ request: Request,
        client: NUEDITBackendClient = .shared,
        stagingDirectory: URL = FileManager.default.temporaryDirectory
    ) async -> Outcome {
        guard await client.currentSettings().isConfigured else {
            return .skipped("No tower configured.")
        }
        var derivatives: [NUEDITBackendClient.Derivative: URL] = [:]
        for kind in uploadedKinds {
            guard let url = request.derivatives[kind], let derivative = kind.backendDerivative,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            derivatives[derivative] = url
        }
        guard derivatives[.vlmProxy] != nil || derivatives[.audio] != nil else {
            return .skipped("No derivative to send yet.")
        }

        let metadata = NUEDITBackendClient.EdgeIngestMeta(
            filename: request.filename,
            duration_ms: request.durationMilliseconds,
            checksum: request.identity.checksum,
            codec: request.identity.codec,
            frame_rate: request.frameRate,
            resolution_width: request.width,
            resolution_height: request.height,
            file_size_bytes: request.identity.fileSizeBytes,
            has_audio: request.hasAudio,
            volume_uuid: request.identity.volumeUUID,
            volume_label: request.identity.volumeLabel,
            volume_relative_path: request.identity.volumeRelativePath,
            mount_point: request.identity.mountPoint
        )
        do {
            let response = try await client.edgeRegister(
                projectId: request.projectId,
                metadata: metadata,
                derivatives: derivatives,
                stagingDirectory: stagingDirectory
            )
            return .registered(footageId: response.id, duplicate: response.isDuplicate)
        } catch is CancellationError {
            return .skipped("Cancelled.")
        } catch let error as BackendError {
            // A transport failure means the tower is away; the footage is not damaged by that.
            if case .transport(let message) = error { return .skipped(message) }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
