import Foundation

enum BackendError: LocalizedError {
    case notConfigured
    case transport(String)
    case unauthorized(AuthFailure)
    case api(status: Int, code: String, message: String)

    enum AuthFailure: Sendable, Equatable {
        /// No credential reached the tower.
        case missingKey
        /// The tower knows the key is bad, revoked, or its user is inactive.
        case rejectedKey
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Backend not configured."
        case .transport(let message): message
        case .unauthorized(.missingKey): "The tower needs an agent key. Add one in Settings → Backend."
        case .unauthorized(.rejectedKey): "The tower rejected this Mac's agent key. Re-authorize this Mac in Settings → Backend."
        case .api(_, _, let message): message
        }
    }
}
