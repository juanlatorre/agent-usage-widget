import Foundation
import AgentUsageCore

/// Maps per-provider fetch errors into the unified RefreshFetchError and
/// wraps the current StatusModel managers so both the UI-triggered
/// refreshXSlot paths and the background RefreshService use the same
/// transport/credentials.
@MainActor
enum UnifiedFetcher {

    static func fetcher(statusModel: StatusModel) -> (AccountSlotID) async -> Result<UsageSnapshot, RefreshFetchError> {
        return { slotID in
            await fetchSlot(slotID, statusModel: statusModel)
        }
    }

    private static func fetchSlot(_ slotID: AccountSlotID, statusModel: StatusModel) async -> Result<UsageSnapshot, RefreshFetchError> {
        switch slotID {
        case .claudeLegacyA, .claudethe team:
            let outcome = await statusModel.refreshClaudeSlot(slotID)
            return mapClaudeOutcome(outcome)
        case .gptPersonal:
            let outcome = await statusModel.refreshCodexSlot(slotID)
            return mapCodexOutcome(outcome)
        case .openCodeGO:
            let outcome = await statusModel.refreshOpenCodeSlot(slotID)
            return mapOpenCodeOutcome(outcome)
        case .commandCodeGOAT:
            let outcome = await statusModel.refreshCommandCodeSlot(slotID)
            return mapCommandCodeOutcome(outcome)
        case .zaiCodingPlan:
            let outcome = await statusModel.refreshZaiSlot(slotID)
            return mapZaiOutcome(outcome)
        }
    }

    static func mapClaudeOutcome(_ outcome: ClaudeRefreshOutcome) -> Result<UsageSnapshot, RefreshFetchError> {
        switch outcome {
        case .updated(let s): return .success(s)
        case .authenticationRequired: return .failure(.unauthorized(status: 401))
        case .sourceIdentityChanged: return .failure(.sourceIdentityChanged)
        case .failed: return .failure(.transport("transient failure"))
        }
    }

    static func mapCodexOutcome(_ o: CodexRefreshOutcome) -> Result<UsageSnapshot, RefreshFetchError> {
        switch o {
        case .updated(let s): return .success(s)
        case .authenticationRequired: return .failure(.unauthorized(status: 401))
        case .sourceIdentityChanged: return .failure(.sourceIdentityChanged)
        case .failed: return .failure(.transport("transient failure"))
        }
    }

    static func mapOpenCodeOutcome(_ o: OpenCodeRefreshOutcome) -> Result<UsageSnapshot, RefreshFetchError> {
        switch o {
        case .updated(let s): return .success(s)
        case .authenticationRequired: return .failure(.unauthorized(status: 401))
        case .sourceIdentityChanged: return .failure(.sourceIdentityChanged)
        case .failed: return .failure(.transport("transient failure"))
        }
    }

    static func mapCommandCodeOutcome(_ o: CommandCodeRefreshOutcome) -> Result<UsageSnapshot, RefreshFetchError> {
        switch o {
        case .updated(let s): return .success(s)
        case .unavailable: return .failure(.incomplete("subscription unavailable"))
        case .authenticationRequired: return .failure(.unauthorized(status: 401))
        case .sourceIdentityChanged: return .failure(.sourceIdentityChanged)
        case .failed: return .failure(.transport("transient failure"))
        }
    }

    static func mapZaiOutcome(_ o: ZaiRefreshOutcome) -> Result<UsageSnapshot, RefreshFetchError> {
        switch o {
        case .updated(let s): return .success(s)
        case .authenticationRequired: return .failure(.unauthorized(status: 401))
        case .sourceIdentityChanged: return .failure(.sourceIdentityChanged)
        case .failed: return .failure(.transport("transient failure"))
        }
    }
}
