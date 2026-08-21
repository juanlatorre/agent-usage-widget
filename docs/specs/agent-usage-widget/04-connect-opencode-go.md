# PRD — Connect OpenCode GO

- **Status:** READY
- **Destination:** The predefined OpenCode GO slot imports its local plan key and reports required 5-hour, weekly, and monthly windows.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** STABLE
- **Scope:** OpenCode profile import/manual fallback, Keychain synchronization, usage endpoint normalization, and app connection controls.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0002, ADR-0004

## 1. Summary

OpenCode GO becomes a fully connected three-window account whose exhaustion in any declared period blocks effective availability.

## 2. Objectives and non-objectives

- **O1:** Import `opencode-go` credentials from a selected/default OpenCode auth store after consent, with manual replacement fallback.
- **O2:** Normalize all three required provider windows and both known payload shapes.
- **NO1:** OpenCode balance, other OpenCode providers, or arbitrary account slots.

## 3. Flow

```text
Detect ~/.local/share/opencode/auth.json metadata
→ Connect GO and copy opencode-go.key to Keychain (or manually enter key)
→ GET OpenCode GO usage
→ normalize rolling / weekly / monthly
```

## 4. Rules and invariants

- **R1:** Fetch `GET https://opencode.ai/zen/go/v1/usage` using Bearer authentication.
- **R2:** Support both `rollingUsage/weeklyUsage/monthlyUsage` with `usagePercent/resetInSec` and `usage.{rolling,weekly,monthly}` with `percent/resetsAt`.
- **R3:** Rolling maps to 5 hour. All three windows are required and block independently.
- **R4:** Missing window, percent, or reset produces `UNAVAILABLE`; a provider `status` that indicates failure cannot be normalized as success.
- **R5:** `useBalance` and unrelated response members are ignored for v1 availability.
- **R6:** Profile import, manual replacement, source identity checks, disconnect, errors, and backoff inherit parent credential/state rules.

## 5. Acceptance criteria

### AC1 — Both response shapes

**GIVEN** fixtures for each known payload shape

**WHEN** refreshed

**THEN** they yield equivalent 5-hour, Weekly, and Monthly normalized snapshots.

### AC2 — Any period blocks

**GIVEN** 5-hour 42%, Weekly 68%, Monthly 100%

**WHEN** availability is derived

**THEN** GO is blocked by Monthly and the ring shows the limiting value in the selected display mode.

### AC3 — Missing month

**GIVEN** a successful HTTP response without Monthly data

**WHEN** normalized

**THEN** status is `UNAVAILABLE`, not available with a zero month.

### AC4 — Credential lifecycle

**GIVEN** detected and manual credentials

**WHEN** the user connects/replaces/tests/disconnects

**THEN** runtime secrets remain Keychain-only and source files are never modified.

## 6. Errors and edge cases

Cover negative reset intervals, malformed ISO dates, unknown status, 401/403, 429, timeout/5xx, source deletion, key rotation, and payloads containing only unrelated balances.

## 7. Repository constraints and reuse

Use the two locally verified `AgentBar` payload families as fixtures. Correct its missing-window-to-zero behavior to satisfy the parent trust contract.

## 8. Test and verification strategy

Stubbed transport tests cover both shapes and all required windows. Profile/Keychain tests cover import and replacement. Domain integration tests cover every single/multiple blocking combination.

## 9. Migration, rollout, and rollback

No migration. Disconnect deletes only app-owned GO state.

## 10. Assumptions and open questions

### Confirmed assumptions

- The local OpenCode auth store retains the `opencode-go` key shape or manual fallback is available.

### Blocking questions

- None.
