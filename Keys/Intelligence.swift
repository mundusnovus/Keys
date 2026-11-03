// Apple Intelligence for Keys 2.0: on-device Foundation Models and, when Apple has granted the managed
// entitlement, Private Cloud Compute.
//
// Non-negotiable privacy rules for a password manager:
//   * No password, username, site name, note, card number, or key ever reaches a model.
//   * Capture runs on the device only. Smart search runs on the device only.
//   * The security coach sends counts and finding kinds, never item names.
//   * A model only suggests. The person applies.
import Foundation
import FoundationModels

// MARK: - Availability

enum IntelligenceStatus: Equatable, Sendable {
    case available
    case deviceNotEligible
    case notEnabled
    case notReady
    case notEntitled
    case unavailable

    var isReady: Bool { self == .available }

    var explanation: String {
        switch self {
        case .available: "Ready"
        case .deviceNotEligible: "This device doesn't support Apple Intelligence."
        case .notEnabled: "Turn on Apple Intelligence in Settings to use this."
        case .notReady: "Apple Intelligence is still getting ready. Try again soon."
        case .notEntitled: "Private Cloud Compute access isn't enabled for this build."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }

    var symbol: String {
        switch self {
        case .available: "apple.intelligence"
        case .deviceNotEligible: "iphone.slash"
        case .notEnabled: "gearshape"
        case .notReady: "hourglass"
        case .notEntitled: "lock.shield"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

@MainActor
enum KeysIntelligence {
    /// The managed entitlement `com.apple.developer.private-cloud-compute`. Apple grants it per developer
    /// account. The build flag `KeysPrivateCloudCompute` in Info.plist must be YES only in a build that also
    /// carries the entitlement; without both, the app uses the device model.
    static let privateCloudEntitled: Bool =
        Bundle.main.object(forInfoDictionaryKey: "KeysPrivateCloudCompute") as? Bool ?? false

    static var onDeviceStatus: IntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .notReady
        case .unavailable: .unavailable
        }
    }

    static var privateCloudStatus: IntelligenceStatus {
        guard privateCloudEntitled else { return .notEntitled }
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.systemNotReady): return .notReady
        case .unavailable: return .unavailable
        }
    }

    /// Counts only. This is what the coach is allowed to see.
    static var privateCloudQuota: String {
        guard privateCloudEntitled else { return "Not enabled for this build" }
        let quota = PrivateCloudComputeLanguageModel().quotaUsage
        switch quota.status {
        case .belowLimit(let info):
            return info.isApproachingLimit ? "Approaching today's limit" : "Within today's limit"
        case .limitReached:
            return "Today's limit reached"
        @unknown default:
            return "Usage unavailable"
        }
    }

    static var isEnabled: Bool {
        let preferences = KeysPreferences.shared
        return preferences.intelligenceEnabled && onDeviceStatus.isReady
    }

    static var canUseCloud: Bool {
        let preferences = KeysPreferences.shared
        return preferences.intelligenceEnabled && preferences.usePrivateCloudCompute
            && privateCloudStatus.isReady
    }

    /// The locale line Apple recommends for anything other than U.S. English.
    nonisolated static var localeInstruction: String {
        let locale = Locale.current
        return Locale.Language(identifier: "en_US").isEquivalent(to: locale.language)
            ? "" : " The person's locale is \(locale.identifier)."
    }

    static func message(for error: Error) -> String {
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure:
                return "Private Cloud Compute couldn't be reached. Keys used this device instead."
            case .quotaLimitReached:
                return "Today's Private Cloud Compute limit is reached. Keys used this device instead."
            case .serviceUnavailable:
                return "Private Cloud Compute is busy. Keys used this device instead."
            @unknown default:
                return "Private Cloud Compute couldn't finish."
            }
        }
        if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal:
                return "Apple Intelligence won't help with that request."
            case .unsupportedLanguageOrLocale:
                return "Apple Intelligence doesn't support this language yet."
            default:
                return "Apple Intelligence couldn't finish. Try again in a moment."
            }
        }
        if error is CancellationError { return "Stopped." }
        return "Apple Intelligence couldn't finish."
    }

    /// Load the model before the person asks, so the first answer doesn't wait.
    static func prewarm() {
        guard isEnabled else { return }
        LanguageModelSession(instructions: SecurityCoach.instructions).prewarm(promptPrefix: nil)
    }
}

// MARK: - Vault statistics (counts only)

struct VaultStats: Sendable, Equatable {
    var total = 0
    var favorites = 0
    var logins = 0
    var reused = 0
    var short = 0
    var old = 0
    var missingCode = 0
    var issueCount = 0

    init(items: [VaultItem] = []) {
        let live = items.filter { $0.deleted == nil && $0.kind != .folder }
        total = live.count
        favorites = live.filter(\.favorite).count
        logins = live.filter { $0.kind == .login }.count

        let findings = VaultAudit.findings(items)
        func unique(_ kind: AuditKind) -> Int {
            Set(findings.filter { $0.kind == kind }.map(\.itemID)).count
        }
        reused = unique(.reused)
        short = unique(.short)
        old = unique(.old)
        missingCode = unique(.missingCode)
        issueCount = Set(findings.map(\.itemID)).count
    }

    var score: Int {
        guard total > 0 else { return 100 }
        var value = 100
        value -= min(35, reused * 10)
        value -= min(25, short * 6)
        value -= min(15, old * 3)
        value -= min(10, missingCode * 2)
        return max(0, min(100, value))
    }

    var grade: String {
        switch score {
        case 90...: "Excellent"
        case 75..<90: "Good"
        case 55..<75: "Fair"
        default: "Needs work"
        }
    }

    /// Redacted sentence for the model. Never add names or secrets here.
    var redactedSummary: String {
        """
        The vault has \(total) items and \(logins) logins.
        \(reused) passwords are reused; \(short) are shorter than 12 characters; \(old) are more than a year old.
        \(missingCode) logins have no one-time code.
        """
    }
}

// MARK: - Security coach

@Generable
struct SecurityAdvice {
    @Guide(description: "A one-sentence headline about the vault's security, at most 12 words, with no emoji")
    var headline: String
    @Guide(description: "Two or three specific things to fix, each one short sentence", .maximumCount(3))
    var priorities: [String]
    @Guide(description: "One short encouraging sentence")
    var encouragement: String
}

struct CoachBriefing {
    var advice: SecurityAdvice
    var usedCloud: Bool
}

struct SecurityCoach {
    static let instructions = """
        You are a calm security coach inside Asteria Keys, a password manager. You receive only counts of \
        security findings; you never see passwords, usernames, site names, notes, or card numbers. Give practical, \
        specific advice a person can act on today. Never invent a breach, a date, or a fact that is not in the \
        summary. Never ask for a password. Do not use headings, lists, or emoji. Write in plain sentences.
        """ + KeysIntelligence.localeInstruction

    /// Cloud when allowed and ready, otherwise the device. A cloud failure quietly falls back to the device.
    func advice(stats: VaultStats, useCloud: Bool) async throws -> CoachBriefing {
        let prompt = stats.redactedSummary
        if useCloud {
            do {
                return CoachBriefing(advice: try await generate(prompt, cloud: true), usedCloud: true)
            } catch {
                return CoachBriefing(advice: try await generate(prompt, cloud: false), usedCloud: false)
            }
        }
        return CoachBriefing(advice: try await generate(prompt, cloud: false), usedCloud: false)
    }

    private func generate(_ prompt: String, cloud: Bool) async throws -> SecurityAdvice {
        let session: LanguageModelSession
        if cloud {
            session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: Self.instructions)
        } else {
            session = LanguageModelSession(instructions: Self.instructions)
        }
        // Server-side reasoning is the reason to use Private Cloud Compute here. The prompt carries counts
        // only, so a deeper analysis never sees a secret. The on-device model does not support reasoning.
        let context = cloud
            ? ContextOptions(reasoningLevel: .deep)
            : ContextOptions(includeSchemaInPrompt: true)
        let response = try await session.respond(
            to: prompt,
            generating: SecurityAdvice.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300),
            contextOptions: context
        )
        return response.content
    }
}

// MARK: - Smart search

@Generable
struct SmartQuery {
    @Guide(description: "Words to match in titles, usernames, and sites. Empty when the request is only a filter.")
    var words: String
    @Guide(description: "Kinds to include: login, password, note, card, identity, passkey, wifi, code. Empty for all.")
    var kinds: [String]
    @Guide(description: "True when the person asks for favorites")
    var favoritesOnly: Bool
    @Guide(description: "True when the person asks for weak, reused, or short passwords")
    var weakOnly: Bool
    @Guide(description: "True when the person asks for old passwords")
    var oldOnly: Bool
    @Guide(description: "True when the person asks for logins without a one-time code")
    var missingCodeOnly: Bool

    var isFiltered: Bool {
        favoritesOnly || weakOnly || oldOnly || missingCodeOnly || !kinds.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if !words.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("“\(words)”") }
        if !kinds.isEmpty { parts.append(kinds.joined(separator: ", ")) }
        if favoritesOnly { parts.append("favorites") }
        if weakOnly { parts.append("weak or reused") }
        if oldOnly { parts.append("older than a year") }
        if missingCodeOnly { parts.append("no code") }
        return parts.isEmpty ? "Everything" : parts.joined(separator: " · ")
    }

    func items(from items: [VaultItem]) -> [VaultItem] {
        let wanted = Set(kinds.compactMap { ItemKind(rawValue: $0.lowercased()) })
        let findings = VaultAudit.findings(items)
        func ids(_ kind: AuditKind) -> Set<UUID> {
            Set(findings.filter { $0.kind == kind }.map(\.itemID))
        }
        let weak = ids(.reused).union(ids(.short))
        let old = ids(.old)
        let missing = ids(.missingCode)
        let needle = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return items.filter { item in
            guard item.deleted == nil, item.kind != .folder else { return false }
            if !wanted.isEmpty, !wanted.contains(item.kind) { return false }
            if favoritesOnly, !item.favorite { return false }
            if weakOnly, !weak.contains(item.id) { return false }
            if oldOnly, !old.contains(item.id) { return false }
            if missingCodeOnly, !missing.contains(item.id) { return false }
            if !needle.isEmpty, !item.matchesQuery(needle) { return false }
            return true
        }
    }
}

enum SmartSearch {
    /// Runs on the device only: the words a person types can name a site they keep secret.
    static func parse(_ text: String) async throws -> SmartQuery {
        let session = LanguageModelSession(instructions: """
            You turn a request into filters for a password manager's search. Use only these kinds: login, password, \
            note, card, identity, passkey, wifi, code. Leave words empty when the request is only a filter. Never \
            invent a site or a person's name. The request is the person's own text.
            """ + KeysIntelligence.localeInstruction)
        let response = try await session.respond(
            to: text,
            generating: SmartQuery.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160)
        )
        return response.content
    }
}
