import Foundation

enum AccountTier: String, Decodable, Sendable {
    case none, pro, max

    var isPaid: Bool { self != .none }

    var planLabel: String {
        switch self {
        case .none: return "Free"
        case .pro: return "Pro plan"
        case .max: return "Max plan"
        }
    }

    var upgradeLabel: String {
        switch self {
        case .none: return ""
        case .pro: return "Pro"
        case .max: return "Max"
        }
    }
}

struct AccountUser: Decodable, Sendable {
    let email: String?
    let name: String?
    let image: String?
    let tier: AccountTier
    let currentPeriodEnd: Double?
    let cancelAtPeriodEnd: Bool?
    let spentCreditsThisPeriod: Int?
    let purchasedCredits: Int?

    var displayName: String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var firstName: String? {
        displayName?.split(separator: " ").first.map(String.init)
    }
}

struct AccountPlan: Decodable, Sendable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let monthlyBudgetCredits: Int?
}

struct AvailablePlan: Decodable, Sendable, Identifiable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let discountedMonthlyPriceUsd: Int?
    let monthlyBudgetCredits: Int?

    var id: String { tier.rawValue }
    var effectiveMonthlyPriceUsd: Int {
        hasDiscount ? discountedMonthlyPriceUsd! : monthlyPriceUsd
    }
    var hasDiscount: Bool {
        guard let discounted = discountedMonthlyPriceUsd else { return false }
        return discounted < monthlyPriceUsd
    }
}

struct AccountResponse: Decodable, Sendable {
    let user: AccountUser
    let plan: AccountPlan?
}

enum TopOffLimits {
    static let minDollars = 5
    static let maxDollars = 1000
}

/// NUEditor runs local-only: there is no hosted identity, subscription, or credit
/// ledger. Retained as a facade so existing callers compile while the hosted
/// account surfaces are removed; NUEDIT is the backend from here on.
@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

    private init() {}

    var isLoading: Bool { false }
    var isMisconfigured: Bool { true }
    var account: AccountResponse? { nil }
    var availablePlans: [AvailablePlan] { [] }
    var lastError: String? { nil }
    var isSigningIn: Bool { false }
    var isBuyingCredits: Bool { false }

    var isSignedIn: Bool { false }
    var aiAllowed: Bool { false }
    var tier: AccountTier { .none }
    var isPaid: Bool { false }

    var spentCredits: Int { 0 }
    var budgetCredits: Int? { nil }
    var remainingCredits: Int { 0 }
    var hasCredits: Bool { false }

    func signInWithGoogle() async {}
    func signOut() async {}
    func subscribe(tier: AccountTier) async {}
    func buyCredits(dollars: Int) {}
    func manageSubscription() async {}

    func sendFeedback(
        message: String,
        email: String?,
        mayContact: Bool,
        screenshotPngBase64: String?,
        appVersion: String,
        osVersion: String
    ) async throws {
        throw BackendError.notConfigured
    }
}

// MARK: - Display helpers

extension AccountService {
    var displayPrimaryText: String { "Signed out" }
    var displaySecondaryText: String? { nil }
    var displayInitial: String { "" }

    func availablePlan(for tier: AccountTier) -> AvailablePlan? { nil }
}
