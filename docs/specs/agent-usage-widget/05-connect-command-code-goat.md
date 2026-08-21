# PRD — Connect Command Code GOAT

- **Status:** READY
- **Destination:** The predefined Command Code GOAT slot imports or accepts its token and reports required 5-hour and weekly windows.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** STABLE
- **Scope:** Command Code auth import/manual fallback, Keychain synchronization, credits/subscription endpoints, two-window normalization, and connection UI.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0002, ADR-0004

## 1. Summary

Command Code GOAT becomes a trustworthy two-window account based on provider-reported used/cap values and reset timestamps.

## 2. Objectives and non-objectives

- **O1:** Import `apiKey` from the selected/default Command Code auth store after consent, with manual replacement fallback.
- **O2:** Normalize the 5-hour and weekly credit windows and show GOAT plan identity when confirmed.
- **NO1:** Monthly/purchased/free credit balances as blocking windows or other Command Code plans as account slots.

## 3. Flow

```text
Detect ~/.commandcode/auth.json metadata
→ Connect GOAT and copy apiKey to Keychain (or enter manually)
→ fetch credits and subscription metadata
→ normalize fiveHour + weekly
```

## 4. Rules and invariants

- **R1:** Use `https://api.commandcode.ai/alpha/billing/credits` for windows and `/alpha/billing/subscriptions` for plan metadata.
- **R2:** Authenticate with Bearer token and a truthful supported Command Code CLI user agent required by the service.
- **R3:** `used`, positive `cap`, and epoch-millisecond `resetAt` are required for each window; explicit `exceeded` corroborates but does not replace capacity math.
- **R4:** Credits outside `windowLimits` and subscription status do not add required windows. An inactive subscription produces `AUTHENTICATION_REQUIRED` or `UNAVAILABLE` with reason, never available.
- **R5:** If plan metadata fails while both usage windows succeed, the snapshot may remain valid with the static slot label; if usage fails, plan success cannot create availability.
- **R6:** Import/manual fallback, synchronization, disconnect, failure, and retry behavior inherit parent rules.

## 5. Acceptance criteria

### AC1 — Credit normalization

**GIVEN** complete fiveHour and weekly used/cap/reset values

**WHEN** refreshed

**THEN** both windows preserve numeric capacity, derive percentages, and participate in blocking.

### AC2 — Plan metadata independence

**GIVEN** valid credit windows and a failed subscription-metadata request

**WHEN** refresh completes

**THEN** usage remains current under the GOAT slot label with a sanitized metadata warning.

### AC3 — Incomplete cap

**GIVEN** a missing or zero cap/reset in either required window

**WHEN** normalized

**THEN** current status is `UNAVAILABLE` and no zero-usage success is persisted.

### AC4 — Required headers

**GIVEN** a stubbed API

**WHEN** requests execute

**THEN** authorization, accept/content headers, and truthful user agent match the contract without leaking secrets to logs.

## 6. Errors and edge cases

Cover epoch overflow, fractional credits, used greater than cap, `exceeded` disagreement, one of two concurrent requests failing, 401/403, Cloudflare rejection, 429, and token/source rotation.

## 7. Repository constraints and reuse

Ground payloads and endpoint behavior in local `AgentBar` tests. The new provider must not default absent windows to zero.

## 8. Test and verification strategy

Contract tests cover credit precision, plan metadata, partial concurrent success, headers, status classes, and backoff. Keychain/profile tests cover consent/import/manual replacement/disconnect.

## 9. Migration, rollout, and rollback

No migration. Disconnect leaves the Command Code CLI auth store untouched.

## 10. Assumptions and open questions

### Confirmed assumptions

- The billing endpoints and required user-agent behavior may be fragile and are isolated in this adapter.

### Blocking questions

- None.
