import Foundation

/// Stable identity for one of the six predefined account slots.
///
/// Slot identities are independent of display labels and provider branding.
public enum AccountSlotID: String, Codable, CaseIterable, Sendable, Hashable {
    case claudeLegacyA = "claude-legacy-1"
    case claudethe team = "claude-legacy-2"
    case gptPersonal = "gpt-personal"
    case openCodeGO = "opencode-go"
    case commandCodeGOAT = "commandcode-goat"
    case zaiCodingPlan = "zai-coding-plan"
}

/// A predefined provider-and-label position the user connects to a profile source.
public struct AccountSlot: Codable, Sendable, Hashable, Identifiable {
    public var id: AccountSlotID { slotID }
    public let slotID: AccountSlotID
    public let label: String
    /// Provider family used for connection routing only; never for presentation branching.
    public let provider: ProviderFamily
    /// Required usage windows declared by the static v1 catalog.
    public let requiredWindows: [UsageWindowKind]
    /// Whether the user has connected this slot to an imported profile.
    /// Connection state is runtime configuration, not serialized catalog identity:
    /// decoding tolerates its absence by treating the slot as not connected.
    public var isConnected: Bool

    public init(slotID: AccountSlotID, label: String, provider: ProviderFamily,
                requiredWindows: [UsageWindowKind], isConnected: Bool = false) {
        self.slotID = slotID
        self.label = label
        self.provider = provider
        self.requiredWindows = requiredWindows
        self.isConnected = isConnected
    }

    private enum CodingKeys: String, CodingKey {
        case slotID, label, provider, requiredWindows, isConnected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slotID = try container.decode(AccountSlotID.self, forKey: .slotID)
        label = try container.decode(String.self, forKey: .label)
        provider = try container.decode(ProviderFamily.self, forKey: .provider)
        requiredWindows = try container.decode([UsageWindowKind].self, forKey: .requiredWindows)
        isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
    }
}

/// Coarse provider families represented by the v1 catalog.
public enum ProviderFamily: String, Codable, Sendable {
    case claude
    case gpt
    case opencode
    case commandCode
    case zai
}

/// The reset period of a usage window. Extra provider-reported periods are ignored in v1.
public enum UsageWindowKind: String, Codable, CaseIterable, Sendable, Hashable {
    case fiveHour
    case weekly
    case monthly

    /// Human-readable English window name.
    public var displayName: String {
        switch self {
        case .fiveHour: return "5 hour"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    /// Approximate period length used only as a diagnostic fallback hint.
    public var approximatePeriod: TimeInterval? {
        switch self {
        case .fiveHour: return 5 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        }
    }
}

/// Static v1 catalog of the six predefined account slots.
///
/// The slot IDs and required-window declarations are fixed catalog data (child
/// spec R1); they must not be derived from user input or provider responses.
public enum AccountCatalog {

    /// The six predefined slots in stable display order.
    public static let slots: [AccountSlot] = [
        AccountSlot(
            slotID: .claudeLegacyA,
            label: "Claude (legacy A)",
            provider: .claude,
            requiredWindows: [.fiveHour, .weekly]),
        AccountSlot(
            slotID: .claudethe team,
            label: "Claude (legacy B)",
            provider: .claude,
            requiredWindows: [.fiveHour, .weekly]),
        AccountSlot(
            slotID: .gptPersonal,
            label: "GPT · Personal",
            provider: .gpt,
            requiredWindows: [.weekly]),
        AccountSlot(
            slotID: .openCodeGO,
            label: "OpenCode · GO",
            provider: .opencode,
            requiredWindows: [.fiveHour, .weekly, .monthly]),
        AccountSlot(
            slotID: .commandCodeGOAT,
            label: "Command Code · GOAT",
            provider: .commandCode,
            requiredWindows: [.fiveHour, .weekly]),
        AccountSlot(
            slotID: .zaiCodingPlan,
            label: "Z.ai · Coding Plan",
            provider: .zai,
            requiredWindows: [.fiveHour])
    ]

    /// Look up a slot by stable ID.
    public static func slot(for id: AccountSlotID) -> AccountSlot? {
        slots.first { $0.slotID == id }
    }
}
