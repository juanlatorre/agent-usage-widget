# PRD — Connect Claude (legacy A) and the team

- **Status:** READY
- **Destination:** Both predefined Claude slots can independently import profile-directory credentials and report trustworthy 5-hour and weekly usage.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** STABLE
- **Scope:** Profile-directory selection/synchronization, slot-specific Keychain storage, Claude usage transport/normalization, connection management, and contract tests for the legacy profile and the team.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0002, ADR-0004, ADR-0006

## 1. Summary

**Today:** Claude Code has one default active Keychain identity and the target app has no Claude support.

**After:** The user selects two independent Claude profile directories, explicitly connects each slot, and sees its 5-hour and weekly status independently.

## 2. Objectives and non-objectives

### Objectives

- **O1:** Connect/disconnect/reconnect the legacy profile and the team without credential crossover.
- **O2:** Synchronize supported Claude profile credential changes into separate app Keychain entries after consent.
- **O3:** Normalize Claude's required windows and failure modes without fabricated usage.

### Non-objectives

- **NO1:** In-app Claude OAuth, default-account switching, or arbitrary Claude slots.
- **NO2:** Displaying model-specific or extra-usage windows as separate v1 limits.

## 3. Current flow → future flow

```text
Choose the legacy profile or the team Connect
→ select independent Claude profile directory
→ inspect non-secret identity metadata
→ confirm connection
→ import supported .credentials.json OAuth material into slot Keychain entry
→ call Claude usage endpoint
→ normalize 5 hour + Weekly snapshot
```

## 4. Rules and invariants

- Inherit every parent credential/privacy/status invariant.
- **R1:** Directory access requires explicit user selection; only the selected directory may be watched.
- **R2:** The source parser supports Claude Code's `claudeAiOauth` credential shape and rejects missing/malformed identity or token material.
- **R3:** the legacy profile and the team use distinct Keychain accounts and source bookmarks. Identity mismatch on a later source change stops sync and yields `AUTHENTICATION_REQUIRED` rather than replacing the slot.
- **R4:** Fetch `GET https://api.anthropic.com/api/oauth/usage` with Bearer authorization and `anthropic-beta: oauth-2025-04-20`.
- **R5:** Exact `five_hour` and `seven_day` keys map to the two required windows. If only suffixed variants exist, choose the most constrained variant for each canonical period; tied blockers use the latest reset. Unknown keys are ignored.
- **R6:** Missing/null required windows or reset timestamps produce `UNAVAILABLE`, not 0%.
- **R7:** 401/403 produces `AUTHENTICATION_REQUIRED`; transport/429/5xx produce parent-defined degraded states.
- **R8:** Disconnect deletes only that slot's app-owned credential, source bookmark, and snapshot; it does not modify the external Claude directory.

## 5. Acceptance criteria

### AC1 — Independent connection

**GIVEN** two valid profile-directory fixtures with different identities/tokens

**WHEN** each is connected to its matching slot

**THEN** two separate Keychain entries and snapshots exist, and neither slot can read or overwrite the other.

### AC2 — Successful normalization

**GIVEN** Claude returns complete 5-hour and 7-day payloads

**WHEN** either slot refreshes

**THEN** percentages/resets normalize to the declared windows and parent availability rules apply.

### AC3 — Variant payload

**GIVEN** aggregate keys are absent and model-suffixed windows differ

**WHEN** the response is normalized

**THEN** the canonical window reflects the most constraining variant and extra keys remain invisible.

### AC4 — Changed identity

**GIVEN** a connected directory later contains credentials for a different Claude identity

**WHEN** synchronization detects the change

**THEN** the existing Keychain secret is not overwritten and the slot requests reconnection.

### AC5 — Safe failure

**GIVEN** null/malformed windows, 401, 429, 5xx, or timeout fixtures

**WHEN** refresh runs

**THEN** no success snapshot with zero usage is created and the correct degraded state/retry metadata results.

## 6. Errors and edge cases

Unreadable/stale security-scoped bookmark, deleted directory, malformed credentials, access-token expiry, profile rotation during import, duplicate directory selection, and response variants MUST have deterministic sanitized outcomes. One directory cannot be actively bound to both Claude slots unless its stable identity matches both, which is impossible by contract.

## 7. Repository constraints and reuse

Use `AgentBar` Claude endpoint/fixture behavior as factual grounding, but replace cache-on-error semantics that return apparent success. Never invoke `security ... -w` from the widget or log credential JSON.

## 8. Test and verification strategy

- Temporary directory fixtures and fake Keychain client cover import/sync/disconnect.
- Stubbed URL transport covers aggregate/variant success and every principal failure.
- Concurrency test changes a source during import and proves atomic slot isolation.
- App UI test covers Connect, directory picker, Connected, Reconnect, Test Connection, Refresh Now, and Disconnect.

## 9. Migration, rollout, and rollback

No migration. Removing Claude support deletes only app-owned Claude entries on explicit disconnect/uninstall cleanup; external profiles remain untouched.

## 10. Assumptions and open questions

### Confirmed assumptions

- Each selected Claude profile directory uses a supported Claude Code credential representation.

### Blocking questions

- None.
