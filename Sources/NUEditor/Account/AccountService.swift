import Foundation

/// NUEditor runs local-only: there is no hosted identity, subscription, or credit
/// ledger, so every capability this gated is reported unavailable. Retained as the
/// single place the editor and the Agent tools ask "can we run hosted AI yet?",
/// which NUEDIT will answer once it owns generation.
@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

    private init() {}

    var isSignedIn: Bool { false }
    var isPaid: Bool { false }
    var hasCredits: Bool { false }
    var remainingCredits: Int { 0 }

    /// Gate for every hosted-AI affordance in the UI.
    var aiAllowed: Bool { false }
}
