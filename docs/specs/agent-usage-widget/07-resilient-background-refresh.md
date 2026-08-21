# PRD — Resilient background refresh

- **Status:** READY
- **Destination:** A lightweight invisible login-session agent keeps connected account snapshots fresh at the configured target interval while failures, resets, and concurrent triggers remain trustworthy.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** STABLE
- **Scope:** Resident-agent lifecycle, refresh orchestration, adaptive scheduling, provider isolation, shared snapshot publication, app activation/manual triggers, and degraded-state transitions.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0003, ADR-0005

## 1. Summary

**Today:** Provider children can refresh only when directly invoked.

**After:** Connecting the first account enables an invisible login item that polls all connected slots, handles trigger races and backoff, and publishes honest state to the app/widget store.

## 2. Objectives and non-objectives

### Objectives

- **O1:** Refresh automatically at 30-second, 1-minute, or 5-minute targets, default 1 minute.
- **O2:** Support app activation, global/per-account manual requests, source changes, and post-reset verification.
- **O3:** Isolate failures per slot and preserve last valid snapshots without false success.
- **O4:** Register/unregister the helper predictably and expose health in Settings without a menu-bar item.

### Non-objectives

- **NO1:** Guaranteed WidgetKit reload timing, push notifications, or a visible status-menu process.
- **NO2:** Polling disconnected accounts or bypassing provider retry requirements.

## 3. Flow

```text
First successful account connection
→ enable login-session helper (user can disable)
→ schedule connected accounts with target interval
→ coalesce automatic/manual/activation/reset/source-change triggers per slot
→ provider fetches from app Keychain
→ normalize + atomically persist successful snapshot or failure metadata
→ request best-effort widget timeline reload for affected configurations
```

## 4. Rules and invariants

- Inherit parent R7–R16 and credential boundaries.
- **R1:** The agent registers after the first successful connection, remains invisible, and can be disabled/re-enabled from Settings. Disabled background refresh does not disable manual refresh while the app is open.
- **R2:** Exactly one fetch may be in flight per account. A new trigger during a fetch records at most one follow-up need; it does not fan out duplicate requests.
- **R3:** Independent accounts may refresh concurrently under a bounded concurrency limit; one hung/failed provider cannot block publication for others.
- **R4:** A successful complete response atomically replaces that account's valid snapshot and clears transient failure metadata.
- **R5:** A failed attempt records sanitized category, attempt time, and next retry while preserving the valid snapshot unchanged. State derives as ERROR before 15 minutes and UNAVAILABLE at/after 15 minutes.
- **R6:** 401/403 or source identity mismatch cancels automatic retries that cannot heal and requests reconnection.
- **R7:** 429 honors Retry-After. Other retryable failures use capped exponential backoff with jitter from an injected random source; a later configured interval or server deadline wins.
- **R8:** Passing any required window reset triggers one immediate refresh. Until success, prior AVAILABLE/BLOCKED is suspended as UNAVAILABLE and the old snapshot is historical.
- **R9:** App activation requests refresh for due connected accounts. Manual global refresh targets all connected accounts; per-account and widget requests target their explicit IDs.
- **R10:** Credential source-change monitoring may request synchronization/refresh only for the slot bound to that source.
- **R11:** Agent/app/widget coordination uses non-secret App Group requests or an authenticated local IPC mechanism. The widget never receives a credential entitlement.
- **R12:** Timer/sleep/wake and clock changes recompute due times instead of replaying every missed interval.

## 5. Pseudocode — behavioral agreement

```text
ON trigger(slot)
IF disconnected THEN ignore with reason
IF auth-blocked THEN require reconnect
IF fetch in flight THEN mark one follow-up and return
IF before provider retry deadline AND trigger is not safe manual override THEN return
START fetch
ON complete response: persist snapshot, clear failure, schedule target interval
ON auth failure: record AUTHENTICATION_REQUIRED, stop automatic retries
ON retryable failure: preserve snapshot, record ERROR/backoff
FINALLY if follow-up marked and safe, run once

ON reset boundary
mark snapshot historical / UNAVAILABLE
trigger(slot)
```

## 6. Acceptance criteria

### AC1 — Automatic lifecycle

**GIVEN** no connected slots

**WHEN** the first connection succeeds and later all slots disconnect

**THEN** the helper is offered/enabled after connection, can be toggled, performs no disconnected polling, and removes app-owned login registration when appropriate.

### AC2 — Trigger coalescing

**GIVEN** an account fetch is in flight

**WHEN** interval, activation, widget, and manual triggers arrive together

**THEN** no concurrent duplicate fetch occurs and no more than one safe follow-up runs.

### AC3 — Failure aging

**GIVEN** a valid snapshot and repeated retryable failures

**WHEN** controlled time advances through 15 minutes

**THEN** primary state moves from ERROR to UNAVAILABLE while the snapshot bytes/timestamp remain unchanged as history.

### AC4 — Post-reset verification

**GIVEN** a blocked window reaches resetAt

**WHEN** the immediate refresh is delayed or fails

**THEN** the account does not become AVAILABLE until a complete successful response verifies it.

### AC5 — Adaptive limits

**GIVEN** 429 Retry-After and repeated 5xx fixtures

**WHEN** scheduling continues

**THEN** no request occurs before the allowed deadline and deterministic jitter/backoff tests prove recovery.

### AC6 — Process isolation

**GIVEN** one provider hangs while another succeeds

**WHEN** global refresh runs

**THEN** the healthy account publishes promptly and the hung request times out without blocking the queue.

## 7. Errors and edge cases

Cover helper crash/restart, app upgrade, sleep/wake, manual refresh during backoff, deleted credentials, corrupt request queue, clock rollback/forward, cancellation, partial global refresh, and App Group unavailable. Crashes must not mark in-flight work successful.

## 8. Repository constraints and reuse

Use `SMAppService` or the supported macOS 14 login-item mechanism. Keep networking/credentials out of the widget process. All scheduling clocks/randomness/transports must be injectable for deterministic tests.

## 9. Test and verification strategy

- Virtual-clock scheduler tests cover every trigger, coalescing, interval, sleep/wake, reset, and backoff path.
- Multi-provider integration tests use fake slow/failing providers.
- Process-level test proves helper reads Keychain/shared configuration and publishes a snapshot.
- Manual validation logs in/out or relaunches the user session, verifies helper registration, and inspects sanitized diagnostics.

## 10. Migration, rollout, and rollback

Registration is lazy after first connection. Disabling launch-at-login stops future automatic starts without deleting snapshots. Uninstall/disconnect cleanup can unregister the helper safely.

## 11. Assumptions and open questions

### Confirmed assumptions

- The OS may defer widget reloads even when the agent has already persisted newer data.

### Blocking questions

- None.
