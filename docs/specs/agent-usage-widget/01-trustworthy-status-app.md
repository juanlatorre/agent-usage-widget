# PRD — Trustworthy status companion app

- **Status:** READY
- **Destination:** The companion app can render and persist provider-agnostic account status with correct availability, freshness, and Used/Remaining semantics before live providers are connected.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** NEW/TRANSVERSAL
- **Scope:** Establish the macOS project, shared domain engine, six account slots, non-secret snapshot/preferences store, and app status UI using injectable fixture providers.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0002, ADR-0005

## 1. Summary

**Today:** No application or shared usage model exists.

**After:** A macOS 14 Apple Silicon app displays six slots and trustworthy status/details from normalized snapshots without provider-specific view branches.

## 2. Story

The user can open the app and understand how each slot will appear in every normal/degraded state. Fixture-driven states prove the core contract before credentials or live endpoints add uncertainty.

## 3. Objectives and non-objectives

### Objectives

- **O1:** Define generic account, window, snapshot, state, freshness, and display-preference contracts.
- **O2:** Compute blocking, limiting window, `availableAt`, and status transitions deterministically.
- **O3:** Persist snapshots/preferences atomically in an App Group-compatible store.
- **O4:** Present all six predefined slots and detailed windows in a native SwiftUI companion app.

### Non-objectives

- **NO1:** Live credentials, provider calls, resident polling, widgets, or release signing.
- **NO2:** Arbitrary account creation or extra provider windows.

## 4. Current flow → future flow

```text
No executable project
→ build macOS app
→ inject fixture snapshots/failures and controllable clock
→ normalize and persist state
→ render provider-agnostic account list/details
```

## 5. Domain, entities, and data

Use parent/`CONTEXT.md` terms. Stable account-slot IDs MUST be independent of display labels. `UsageWindow` includes stable ID, name, required flag, used, limit, resetAt, and source diagnostics excluding payload/secrets. `UsageSnapshot` includes slot/provider identity, windows, updatedAt, and provenance. Runtime presentation state is derived rather than serialized as authoritative truth.

## 6. Rules and invariants

- Inherit parent R1–R11, R17, I1, and I2.
- **R1:** The six slot IDs and required-window declarations are static v1 catalog data.
- **R2:** Domain calculations accept an injected clock and contain no SwiftUI, networking, or provider-specific logic.
- **R3:** Snapshot writes are atomic per slot; a failed write cannot destroy the previous valid record.
- **R4:** A corrupt/unknown-schema record is ignored for current state and retained only if safely quarantined without blocking other slots.
- **R5:** The global Used/Remaining value and refresh interval use non-secret shared preferences; invalid stored values fall back to Remaining and 1 minute.
- **R6:** Account list ordering is stable except that Large-widget priority sorting is deferred to its child.

## 7. Pseudocode — behavioral agreement

```text
LOAD catalog, preferences and snapshots
FOR each account slot
  VALIDATE required windows and freshness against injected now
  DERIVE status, blockers, limiting window and availableAt
  RENDER the same account/detail components from derived presentation data

ON preference change
PERSIST shared value
RECOMPUTE only presentation percentages
DO NOT alter availability
```

## 8. Acceptance criteria

### AC1 — Multiple blockers

**GIVEN** fixture windows at 100%, 100%, and 39% with different resets

**WHEN** state is derived

**THEN** both exhausted windows are blocking and availableAt is their later reset.

### AC2 — Display mode

**GIVEN** a limiting window at 42% used

**WHEN** Remaining replaces Used

**THEN** ring/bar/label show 58% remaining while state and blockers are unchanged.

### AC3 — State matrix

**GIVEN** fixtures for no snapshot, current complete snapshot, incomplete snapshot, refresh error, authentication failure, expired history, and post-reset pending verification

**WHEN** rendered in the app

**THEN** they produce the parent-defined states and historical/partial context without fabricated zero usage.

### AC4 — Persistence safety

**GIVEN** a valid stored snapshot

**WHEN** a replacement write is interrupted or another slot record is corrupt

**THEN** the valid snapshot remains readable and unaffected slots still load.

### AC5 — Provider-agnostic UI

**GIVEN** snapshots with one through four generic windows

**WHEN** account detail renders

**THEN** it lays out every window without checking provider type.

## 9. Errors and edge cases

| Situation | Expected behavior |
|---|---|
| NaN/infinite/negative limit | `UNAVAILABLE`, sanitized diagnostic |
| used below zero | Invalid required window, not free capacity |
| used above limit | Clamp visual percentage; remain blocking |
| reset in past | `UNAVAILABLE` pending verification |
| future snapshot timestamp | Treat age as zero for display and record clock-skew diagnostic |
| corrupt snapshot | Isolate record and request future refetch |

## 10. Repository constraints and reuse

- Create a maintainable Xcode project with app, shared module/package, and test targets; deployment target macOS 14, arm64 only.
- Use app-group-capable abstractions without placing credentials in the shared container.
- User-facing copy is English and uses native typography/materials; provider colors are prohibited.

## 11. Test and verification strategy

- Unit tests map AC1–AC4 with fixed clocks.
- Store tests cover schema versioning, atomic replacement, corruption, and slot isolation.
- SwiftUI previews and UI tests cover AC3/AC5, keyboard accessibility, reduced motion, dark/light/vibrant contexts, and long labels.
- `xcodebuild` builds/tests the app and shared targets on an available macOS destination.

## 12. Migration, rollout, and rollback

No migration. First launch creates preferences/catalog state lazily and leaves all slots disconnected. Deleting shared records restores the empty state.

## 13. Assumptions and open questions

### Confirmed assumptions

- Fixture providers are test infrastructure, not a user-selectable production provider.

### Blocking questions

- None.
