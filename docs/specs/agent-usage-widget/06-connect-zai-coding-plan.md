# PRD — Connect Z.ai Coding Plan

- **Status:** READY
- **Destination:** The predefined Z.ai Coding Plan slot imports or accepts its API token and reports only the required 5-hour coding window.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** STABLE
- **Scope:** Z.ai token import/manual fallback, Keychain synchronization, quota endpoint normalization, and connection UI.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0002, ADR-0004

## 1. Summary

Z.ai becomes a one-window account. Provider-reported monthly MCP/time limits are deliberately ignored in v1.

## 2. Objectives and non-objectives

- **O1:** Import `zai-coding-plan` from known OpenCode/local configuration when available, with manual token fallback.
- **O2:** Normalize `TOKENS_LIMIT` into the required 5-hour percentage/reset.
- **NO1:** Displaying or blocking on `TIME_LIMIT`, MCP allocation, or other quota types.

## 3. Flow

```text
Detect compatible Z.ai token metadata
→ Connect Coding Plan and copy token to Keychain (or enter manually)
→ GET quota limits
→ select TOKENS_LIMIT only
→ normalize 5 hour
```

## 4. Rules and invariants

- **R1:** Fetch `GET https://api.z.ai/api/monitor/usage/quota/limit` with JSON accept/language headers.
- **R2:** Attempt Bearer authorization first; a single raw-token retry is allowed only after an unauthorized Bearer response because the verified endpoint has accepted both forms.
- **R3:** `TOKENS_LIMIT.percentage` and epoch-millisecond `nextResetTime` are required. Other quota types are ignored.
- **R4:** Missing `TOKENS_LIMIT`, percentage, reset, or a negative/failed API envelope produces `UNAVAILABLE`, not 0%.
- **R5:** Token import/manual replacement, synchronization, disconnect, status classification, and backoff inherit parent rules.

## 5. Acceptance criteria

### AC1 — Required limit only

**GIVEN** a response containing complete TOKENS_LIMIT and TIME_LIMIT entries

**WHEN** normalized

**THEN** exactly one 5-hour window is stored and TIME_LIMIT is absent from display/blocking.

### AC2 — Authorization compatibility

**GIVEN** Bearer receives 401 and raw token succeeds

**WHEN** refresh runs

**THEN** exactly one safe compatibility retry occurs and the successful snapshot is persisted.

### AC3 — Missing required quota

**GIVEN** a success envelope without TOKENS_LIMIT or reset

**WHEN** normalized

**THEN** status is `UNAVAILABLE` with no fabricated usage.

### AC4 — Token lifecycle

**GIVEN** detected and manual token paths

**WHEN** connect/replace/test/disconnect actions execute

**THEN** only the app Keychain stores runtime secrets and local source files remain untouched.

## 6. Errors and edge cases

Cover unsuccessful envelopes, duplicate TOKENS_LIMIT entries, malformed epoch milliseconds, percentage outside bounds, both auth forms rejected, 429/5xx, and token rotation. Duplicate required entries are invalid unless the adapter can deterministically identify the current coding-plan entry.

## 7. Repository constraints and reuse

Use local `AgentBar` quota fixtures as grounding but intentionally omit its TIME_LIMIT mapping and missing-value defaults.

## 8. Test and verification strategy

Stubbed transport tests cover auth retry, exact quota filtering, malformed envelopes, extra limits, and degraded states. Credential tests cover local import/manual fallback and Keychain-only runtime access.

## 9. Migration, rollout, and rollback

No migration. Disconnect deletes only app-owned Z.ai state.

## 10. Assumptions and open questions

### Confirmed assumptions

- The initial product contract intentionally excludes provider-reported non-coding limits.

### Blocking questions

- None.
