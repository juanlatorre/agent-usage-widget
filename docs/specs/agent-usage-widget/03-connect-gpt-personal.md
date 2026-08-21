# PRD — Connect GPT Personal

- **Status:** READY
- **Destination:** The predefined GPT Personal slot imports the selected Codex OAuth profile and reports its current weekly usage window.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** STABLE
- **Scope:** Codex profile discovery/consent, Keychain synchronization, ChatGPT usage transport, weekly normalization, and app connection controls.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0002, ADR-0004

## 1. Summary

The user connects the Personal Codex profile and receives one trustworthy Weekly window rather than inferred local token totals.

## 2. Objectives and non-objectives

### Objectives

- **O1:** Import and synchronize the selected Codex ChatGPT OAuth identity into slot-specific Keychain storage.
- **O2:** Fetch authoritative current weekly percentage/reset and classify blocked/degraded states.

### Non-objectives

- **NO1:** API-key billing usage, extra model limits, credit balances, or arbitrary GPT accounts.
- **NO2:** Treating token-sum estimates without a provider reset as a valid snapshot.

## 3. Flow

```text
Detect Codex profile metadata (default ~/.codex or selected profile home)
→ user connects Personal
→ copy tokens.access_token + account_id to Keychain
→ GET ChatGPT Codex usage
→ normalize primary 7-day window as Weekly
```

## 4. Rules and invariants

- **R1:** Fetch `GET https://chatgpt.com/backend-api/codex/usage?limit_id=codex` with Bearer token, `ChatGPT-Account-Id` when present, JSON accept header, and a truthful client user agent.
- **R2:** `primary_window.used_percent` and `reset_at` (or nonnegative `reset_after_seconds` relative to response time) define the required Weekly window.
- **R3:** `limit_reached`/`allowed` may corroborate blocking but cannot replace a complete percentage/reset window.
- **R4:** Missing account/token is `AUTHENTICATION_REQUIRED`; incomplete weekly data is `UNAVAILABLE`; 401/403 requests reconnection; transient failures follow parent behavior.
- **R5:** Local JSONL rate-limit records may be used only as a documented fallback when they contain an explicit 7-day percentage and future reset. Raw token summing is historical diagnostics only.
- **R6:** Extra limits, credits, spend control, and plan metadata cannot block v1 availability.
- **R7:** Profile changes synchronize only after stable identity matching; disconnect removes app-owned material only.

## 5. Acceptance criteria

### AC1 — Live weekly usage

**GIVEN** a valid Codex OAuth fixture and complete API response

**WHEN** Personal refreshes

**THEN** exactly one Weekly window is persisted with the reported percent/reset.

### AC2 — Exhausted week

**GIVEN** `used_percent: 100` and `limit_reached: true`

**WHEN** normalized

**THEN** Personal is blocked by Weekly and availableAt equals the weekly reset.

### AC3 — Safe fallback

**GIVEN** the live endpoint fails and a local event includes a complete explicit 7-day rate window

**WHEN** fallback runs

**THEN** that window may produce a snapshot with provenance; an estimate lacking reset cannot.

### AC4 — Authentication and partial data

**GIVEN** missing/expired credentials or absent reset/percentage

**WHEN** refresh runs

**THEN** the state is authentication-required or unavailable as appropriate, never available at 0%.

## 6. Errors and edge cases

Handle absent account ID, multiple local `limit_id` values, stale resets, malformed auth JSON, profile change, 429 Retry-After, and endpoint shape changes. Multiple explicit rate-limit records may be combined only when their semantics are proven compatible; otherwise prefer the named `codex` weekly window.

## 7. Repository constraints and reuse

Ground request shape and fixtures in local `AgentBar` Codex coverage. Do not copy its 100M synthetic token limit into the normalized percentage contract.

## 8. Test and verification strategy

Contract tests cover 0/96/100%, epoch/relative resets, malformed/extra fields, auth failures, and fallback eligibility. Fake Keychain/profile tests prove consent and identity isolation. UI tests cover connection and per-account actions.

## 9. Migration, rollout, and rollback

No migration. Disconnect removes the app copy, source mapping, and snapshot without logging out Codex.

## 10. Assumptions and open questions

### Confirmed assumptions

- The selected Codex profile uses the ChatGPT OAuth auth-file shape currently emitted by Codex CLI.

### Blocking questions

- None.
