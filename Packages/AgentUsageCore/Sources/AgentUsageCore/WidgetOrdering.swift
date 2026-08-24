import Foundation

/// Provider-agnostic status priority used by Medium/Large widget sorting (R3, R4).
/// Blocked/error/auth/unavailable precede available, with deterministic tie order.
public enum WidgetOrdering {

    /// Numeric priority: lower means shown first.
    public static func priority(for presentation: AccountPresentation) -> Int {
        switch presentation.status {
        case .blocked: return 0
        case .error: return 1
        case .authenticationRequired: return 2
        case .unavailable: return 3
        case .loading: return 4
        case .available: return 5
        case .notConnected: return 6
        }
    }

    /// Sort presentations by priority, preserving catalog order for ties (deterministic).
    public static func sorted(_ presentations: [AccountPresentation]) -> [AccountPresentation] {
        let catalogOrder = Dictionary(uniqueKeysWithValues: AccountCatalog.slots.enumerated().map { ($1.slotID, $0) })
        return presentations.sorted { a, b in
            let pa = priority(for: a), pb = priority(for: b)
            if pa != pb { return pa < pb }
            return (catalogOrder[a.slotID] ?? Int.max) < (catalogOrder[b.slotID] ?? Int.max)
        }
    }
}
