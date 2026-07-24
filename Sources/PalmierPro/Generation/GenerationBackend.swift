import Combine
import Foundation

/// Generation ran through a hosted broker that NUEditor no longer talks to.
/// NUEDIT owns generation from here on and delivers results via `import_media`,
/// so every entry point reports unavailable rather than half-succeeding.
@MainActor
enum GenerationBackend {
    static func subscribe(
        jobId: String
    ) -> AnyPublisher<BackendGenerationJob?, Never>? {
        nil
    }

    static func uploadReference(
        fileURL: URL,
        contentType: String,
    ) async throws -> String {
        throw BackendError.notConfigured
    }

    static func submit(
        model: String,
        params: BackendGenerationParams,
        projectId: String? = nil,
    ) async throws -> String {
        throw BackendError.notConfigured
    }
}

// MARK: - Backend generation types

enum BackendGenerationParams: Encodable, Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .video(let p): try c.encode(p)
        case .image(let p): try c.encode(p)
        case .audio(let p): try c.encode(p)
        case .upscale(let p): try c.encode(p)
        }
    }
}

enum BackendGenerationStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendGenerationJob: Decodable, Sendable {
    let _id: String
    let status: BackendGenerationStatus
    let resultUrls: [String]?
    let errorMessage: String?
    let costCredits: Int?
    let completedAt: Double?
}
