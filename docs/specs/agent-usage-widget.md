# PRD — Agent Usage Widget

- **Status:** READY
- **Destination:** A native macOS companion app and WidgetKit widget let the user determine each configured AI subscription's effective availability, blocking usage windows, remaining or used capacity, and reset timing at a glance, while securely managing credentials and preserving trustworthy historical snapshots during failures.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-PARENT
- **Domain impact:** NEW/TRANSVERSAL
- **Scope:** Deliver the six predefined account slots, normalized usage and availability semantics, secure local-profile connections, resilient refresh, native widgets, and a directly distributable macOS 14 Apple Silicon app.
- **Parent:** none
- **Related ADRs:** [ADR-0001](../adr/0001-distribute-a-signed-direct-download.md), [ADR-0002](../adr/0002-allow-explicit-pragmatic-provider-adapters.md), [ADR-0003](../adr/0003-refresh-through-a-resident-agent.md), [ADR-0004](../adr/0004-synchronize-selected-profiles-into-keychain.md), [ADR-0005](../adr/0005-require-post-reset-verification.md), [ADR-0006](../adr/0006-source-claude-accounts-from-separate-profile-directories.md)

## 1. Summary

**Today:** The repository contains only a license. The user must open several tools or websites and manually interpret unrelated rate-limit windows.

**After:** One companion app and native desktop widget present trustworthy normalized status for Claude (legacy A), Claude (legacy B), GPT Personal, OpenCode GO, Command Code GOAT, and Z.ai Coding Plan.

## 2. Story

### Before

While choosing an AI coding service, the user checks several products, compares incompatible percentages, and manually reasons about whether one exhausted window blocks an otherwise funded subscription.

### After

The user glances at the desktop and immediately sees which accounts are available, which required window blocks an account, and when every current blocker is expected to clear. Details remain available without exposing credentials or misrepresenting failed or stale data.

## 3. Objectives and non-objectives

### Objectives

- **O1:** Make effective availability and blocking windows understandable within seconds.
- **O2:** Normalize any number of provider windows without provider-specific view logic.
- **O3:** Securely connect the six predefined local account slots and fetch their current required windows.
- **O4:** Keep snapshots fresh through automatic, manual, activation, and post-reset refresh while representing failures honestly.
- **O5:** Provide native Small, Medium, and Large WidgetKit experiences plus an account-management app.
- **O6:** Produce a signed/notarizable direct-download build for macOS 14 on Apple Silicon.

### Non-objectives

- **NO1:** Mac App Store distribution, Intel support, or macOS 13 support.
- **NO2:** Arbitrary user-created accounts or providers in v1.
- **NO3:** A menu-bar status item, notifications, provider-specific colors, or Spanish localization.
- **NO4:** In-app OAuth authorization; v1 imports explicitly selected local profiles or tokens.
- **NO5:** Displaying or enforcing provider windows outside the initial required-window table.
- **NO6:** Guaranteeing per-minute WidgetKit reloads despite system scheduling budgets.

## 4. Current flow → future flow

### Current

```text
Choose a service
→ open several tools/web pages
→ inspect unrelated limits
→ manually infer blocking and reset timing
```

### Future

```text
Connect predefined local account slots
→ credentials copied to slot-specific Keychain entries
→ resident agent fetches and normalizes snapshots
→ shared non-secret snapshot store persists last valid values
→ app and widget compute presentation from the common contract
→ user sees AVAILABLE / BLOCKED or an honest degraded state
```

## 5. Actors, roles, and permissions

| Actor or role | Can do | Cannot do | Notes |
|---|---|---|---|
| Local macOS user | Select profile sources, connect/disconnect slots, replace tokens, configure display/refresh, request refresh | Read secrets through the widget | Single-user local product |
| Companion app | Request profile consent, access app Keychain group, manage settings and snapshots | Store plaintext credentials in defaults/files/App Group | Owns account-management UI |
| Resident agent | Read authorized Keychain credentials, call providers, write normalized snapshots | Present UI or silently import unapproved profiles | Starts after first connection |
| Widget extension | Read snapshots and non-secret preferences, invoke scoped refresh intent | Read OAuth/API credentials or call provider APIs directly | WidgetKit scheduling is best-effort |

## 6. Domain, entities, and data

Canonical language is defined in [`CONTEXT.md`](../../CONTEXT.md).

| Entity/data | Current meaning/source | Required change | Authority/owner |
|---|---|---|---|
| Account Slot | None | Six stable IDs and labels with connection state | App configuration |
| Imported Profile | Existing local tool configuration | Explicitly selected source metadata and synchronized Keychain secret | Source tool for changes; app Keychain for runtime use |
| Usage Window | Provider-specific payload | Normalized required window with values, percentage, reset and blocking flag | Successful provider response |
| Usage Snapshot | None | Codable non-secret snapshot with provenance and timestamp | Usage manager |
| Effective Availability | Manual inference | Derived from all required windows only | Domain engine |
| Presentation Preference | None | Global Used/Remaining and refresh interval | Shared app preference |

Initial required windows:

| Account slot | Required windows |
|---|---|
| Claude (legacy A) | 5 hour, Weekly |
| Claude (legacy B) | 5 hour, Weekly |
| GPT · Personal | Weekly |
| OpenCode · GO | 5 hour, Weekly, Monthly |
| Command Code · GOAT | 5 hour, Weekly |
| Z.ai · Coding Plan | 5 hour |

## 7. Rules and invariants

- **R1:** A successful snapshot MUST contain every required window with finite `used`, positive `limit`, and a valid future-or-current `resetAt`; otherwise current status is `UNAVAILABLE` and complete windows are context only.
- **R2:** `remaining = max(limit - used, 0)`. Percentages MUST be clamped to `0...100` for presentation without hiding invalid source values from diagnostics.
- **R3:** A required window is `BLOCKING` when remaining capacity is zero. An account is `AVAILABLE` only when every required window has remaining capacity; otherwise it is `BLOCKED`.
- **R4:** `blockedBy` contains every blocking required window. `availableAt` is the latest `resetAt` among current blockers.
- **R5:** The limiting window has the maximum percentage used, equivalently the minimum percentage remaining, and supplies the ring percentage.
- **R6:** The global Used/Remaining preference changes ring/bar direction and labels only; it MUST NOT change blocking or availability.
- **R7:** Status precedence is: missing/invalid credential → `AUTHENTICATION_REQUIRED`; no snapshot during initial fetch → `LOADING`; complete successful snapshot → `AVAILABLE` or `BLOCKED`; transient failed refresh → `ERROR` with historical snapshot; incomplete required data or snapshot age at least 15 minutes → `UNAVAILABLE` with historical/partial context.
- **R8:** Refreshing a still-current successful snapshot preserves `AVAILABLE`/`BLOCKED` with a subtle progress indicator. `LOADING` is not used for routine refresh.
- **R9:** Crossing a cached `resetAt` triggers refresh and suspends the prior availability claim as `UNAVAILABLE` until a successful post-reset snapshot arrives.
- **R10:** Countdown presentation derives locally from `resetAt - now`; it MUST NOT trigger one API request per visual tick.
- **R11:** Provider failures MUST NOT create zero-usage windows or current availability. The last valid snapshot remains persisted as historical context.
- **R12:** Credentials MUST exist only in macOS Keychain for app runtime. Snapshots, settings, slot IDs, source paths, timestamps, and non-secret identity metadata may use an App Group container; secrets may not.
- **R13:** Profile discovery reads non-secret metadata only. Secret import requires an explicit Connect action. A source identity mismatch MUST stop synchronization rather than overwrite another slot.
- **R14:** Polling intervals are 30 seconds, 1 minute, and 5 minutes, defaulting to 1 minute. `Retry-After` and exponential backoff with jitter override the target interval when necessary.
- **R15:** Refresh is single-flight per account. Global refresh may run independent accounts concurrently but MUST coalesce duplicate triggers.
- **R16:** The app supports global and per-account Refresh Now. A Medium/Large widget refreshes only its visible accounts; Small has no refresh control.
- **R17:** Windows not listed in the initial table are ignored in v1 and cannot affect display or availability.
- **I1:** Widget code remains provider-agnostic and credential-free.
- **I2:** Disconnecting one slot cannot delete or alter another slot's credential, snapshot, or source mapping.

## 8. Pseudocode — behavioral agreement

```text
WHEN a provider response succeeds
NORMALIZE only declared required windows
IF any required window is incomplete or invalid
  SET current status UNAVAILABLE and retain complete values as partial context
ELSE
  SET blocking windows where remaining <= 0
  SET AVAILABLE when blocking windows is empty, otherwise BLOCKED
  SET availableAt to max(blocking resetAt)
  PERSIST the valid snapshot without credentials

WHEN refresh fails
IF credentials are missing or rejected
  SET AUTHENTICATION_REQUIRED
ELSE
  SET ERROR while historical snapshot age < 15 minutes
  SET UNAVAILABLE once historical snapshot age >= 15 minutes
NEVER synthesize zero usage

WHEN a cached resetAt passes
REQUEST a refresh
SET current status UNAVAILABLE until post-reset verification succeeds

WHEN displaying usage
SELECT limiting window
IF preference is Used, display used percentages
IF preference is Remaining, display complementary percentages
PRESERVE identical availability logic
```

## 9. Acceptance criteria

### AC1 — Effective availability

**GIVEN** any initial account with all required windows complete

**WHEN** one or more windows have no remaining capacity

**THEN** the account is `BLOCKED`, every exhausted window is `BLOCKING`, the ring uses the limiting window, and `availableAt` is the latest blocker reset.

### AC2 — Trustworthy degradation

**GIVEN** a valid snapshot followed by a network failure

**WHEN** refresh fails and later the snapshot reaches 15 minutes old

**THEN** the primary state is first `ERROR`, then `UNAVAILABLE`, while the prior snapshot remains visibly historical and is never presented as current availability.

### AC3 — Secure account setup

**GIVEN** a supported local profile or token source

**WHEN** the user connects its predefined slot

**THEN** only metadata is inspected before consent, runtime credentials are stored in a slot-specific Keychain entry, and no widget/App Group/defaults/file contains the secret.

### AC4 — Complete initial provider coverage

**GIVEN** contract fixtures for all five providers

**WHEN** each adapter fetches a successful payload

**THEN** the six slots expose exactly their declared required windows and ignore extra provider limits.

### AC5 — Refresh behavior

**GIVEN** connected accounts and the resident agent enabled

**WHEN** automatic, activation, manual, credential-change, or post-reset triggers occur

**THEN** duplicate account work is coalesced, rate-limit backoff is respected, valid snapshots are persisted, and affected UI surfaces request best-effort reload.

### AC6 — Native widget hierarchy

**GIVEN** Small, Medium, and Large widget instances

**WHEN** they render available, blocked, authentication, error, and unavailable fixtures

**THEN** state, blockers, availability timing, usage, resets, and freshness follow the agreed priority within each size's configured account scope.

### AC7 — Used/Remaining consistency

**GIVEN** the same snapshots in both display modes

**WHEN** the global preference changes

**THEN** ring, bars, and labels all change representation while statuses, blockers, and available times remain unchanged.

### AC8 — Direct release candidate

**GIVEN** the complete project on macOS 14 Apple Silicon

**WHEN** release validation runs

**THEN** the app, helper, and widget archive with production entitlements; signing/notarization steps are reproducible without secrets in source control.

## 10. Errors, degraded states, and edge cases

| Situation | Expected safe state | Feedback | Recovery | Observability |
|---|---|---|---|---|
| No credential | `AUTHENTICATION_REQUIRED` | Connect/Reconnect account | Explicit Connect | Non-secret reason code |
| 401/403 or source identity changed | `AUTHENTICATION_REQUIRED` | Reconnect profile | Reimport after consent | Sanitized HTTP/source code |
| Timeout, offline, 5xx | `ERROR`, later `UNAVAILABLE` at 15m | Usage unavailable + snapshot age | Adaptive retry/manual refresh | Attempt time, category, retry time |
| 429 | `ERROR` with historical context | Rate limited + next retry | Honor Retry-After/backoff | Retry deadline |
| Missing required window/value/reset | `UNAVAILABLE` | Incomplete usage data | Retry/provider update | Missing field/window IDs |
| Cached reset passes | `UNAVAILABLE` pending verification | Refreshing after reset | Immediate/coalesced refresh | Reset trigger and result |
| App Group snapshot corrupt | `UNAVAILABLE` for affected slot | Usage unavailable | Ignore/quarantine corrupt record and refetch | Decode failure without payload secrets |
| Widget reload delayed | Last rendered data with native timer/age | Last updated | Agent requests best-effort reload | Snapshot timestamps remain authoritative |

## 11. Repository constraints and reuse

- The target repository has no existing app architecture; create an Xcode project/workspace suitable for app, helper, widget, shared domain code, and tests.
- Ground provider contracts in the locally verified `AgentBar` adapters and fixtures, but do not inherit their zero-on-missing or availability-on-error behavior.
- Deployment target is macOS 14; architectures are Apple Silicon only.
- Use SwiftUI + WidgetKit and App Intents for widget configuration/actions.
- Use an App Group for non-secret shared data and a Keychain access group only for app/helper credential access; the widget target receives no credential entitlement.
- Follow WidgetKit refresh budgets; do not claim that timeline reloads occur every minute.
- Do not commit real credentials, captured authenticated payloads, signing identities, notarization passwords, or personal profile contents.

## 12. Test and verification strategy

- Domain unit tests cover R1–R10 and map to AC1, AC2, and AC7.
- Credential-store and source-parser tests use temporary fixtures/fake Keychain clients for AC3.
- Provider contract tests stub transport and cover success, malformed data, missing windows, 401, 429, 5xx, and unknown extra fields for AC4.
- Scheduler tests use a controllable clock/random source and fake providers for AC5.
- Snapshot-store tests cover atomic writes, corruption, isolation, and cross-process reads.
- SwiftUI previews/snapshot or accessibility-driven UI tests cover all states and sizes for AC6.
- Xcode build/test/archive plus entitlement inspection cover AC8; real notarization is an operational check requiring external Apple credentials.

## 13. Migration, rollout, and rollback

- No data migration is required for the empty repository.
- First launch has six disconnected slots and no resident agent registration until the first connection succeeds.
- Rollback removes the login item and app bundle; disconnect/delete flows remove app-owned Keychain entries and shared snapshots.
- Provider adapters are isolated so a broken integration can become `UNAVAILABLE` without corrupting other accounts.

## 14. Assumptions and open questions

### Confirmed assumptions

- Provider endpoints may be undocumented and can change; explicit adapter failure is preferable to fabricated data.
- The user can provide independent Claude profile directories containing supported Claude credential metadata.
- Code signing/notarization credentials are supplied outside source control during release validation.

### Blocking questions

- None.
