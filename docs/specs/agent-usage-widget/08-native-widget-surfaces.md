# PRD — Native WidgetKit surfaces

- **Status:** READY
- **Destination:** Configurable Small, Medium, and Large macOS widgets communicate effective availability, blockers, recovery timing, usage, resets, and freshness with native compact hierarchy.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** STABLE
- **Scope:** Widget extension, App Intent configuration/actions, provider-agnostic ring/bar components, native reset timers, all state variants, accessibility, and best-effort timelines.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0003, ADR-0005

## 1. Summary

The desktop becomes the primary at-a-glance surface while remaining honest about WidgetKit scheduling and historical data.

## 2. Objectives and non-objectives

### Objectives

- **O1:** Small prioritizes one selected account's availability and limiting percentage.
- **O2:** Medium shows up to three selected accounts and their principal windows.
- **O3:** Large shows all six accounts, all required windows/resets, and prioritizes blocked/error states.
- **O4:** Use one provider-agnostic visual system for all normal/degraded states and both display modes.
- **O5:** Offer contextual Refresh Now in Medium/Large without exposing credentials.

### Non-objectives

- **NO1:** Provider-specific colors, web-dashboard styling, arbitrary account creation, or a Small refresh button.
- **NO2:** Provider API calls, custom per-second redraw loops, or guaranteed minute-level timeline reloads.

## 3. Configuration and flow

```text
Edit widget
→ Small selects exactly one available account slot
→ Medium selects one to three distinct slots
→ Large includes the six v1 slots
→ timeline reads shared non-secret state
→ view derives presentation with global Used/Remaining preference
→ Medium/Large Refresh Now submits visible slot IDs to resident refresh orchestration
```

## 4. Rules and invariants

- **R1:** Visual priority is state, blocker, available-again timing, usage, per-window reset, freshness.
- **R2:** Small displays ring, percentage, AVAILABLE/BLOCKED or degraded state, slot/provider label, and concise blocker/recovery context when blocked. It opens the app for management.
- **R3:** Medium displays one to three selected slots. Within those slots, blocked/error/auth/unavailable precede available while preserving deterministic tie order.
- **R4:** Large includes all six slots, sorted by the same status priority, and renders every declared required window when space permits without horizontal scrolling.
- **R5:** Ring percentage is the limiting window. Used/Remaining changes ring, each bar's fill, numeric label, and wording consistently.
- **R6:** Bars identify `BLOCKING` explicitly; color is semantic state color, not provider identity.
- **R7:** Reset countdowns use SwiftUI native timer/date presentation from resetAt. They never cause remote requests per tick.
- **R8:** AVAILABLE/BLOCKED appears only for current verified snapshots. ERROR/AUTHENTICATION_REQUIRED/UNAVAILABLE displays historical age or reconnect action as applicable.
- **R9:** A selected but disconnected slot remains visible as authentication-required; WidgetKit does not silently substitute another account.
- **R10:** Medium/Large refresh App Intent passes only visible slot IDs, shows transient action feedback, and remains idempotent/coalesced by the agent.
- **R11:** Widget timelines read snapshots/preferences/configuration only. Reload policy plans reset/freshness boundaries at sensible intervals and relies on WidgetCenter invalidation for newly persisted data.
- **R12:** Use `containerBackground(for: .widget)`, native materials, SF Pro/SF Symbols, restrained semantic colors, and sufficient contrast in full-color/vibrant rendering.
- **R13:** Every status, ring, bar, blocking marker, reset, and action has meaningful VoiceOver text; focus order follows visual priority and reduced-motion settings are respected.

## 5. Acceptance criteria

### AC1 — Small blocked account

**GIVEN** OpenCode GO is selected and blocked by 5 hour

**WHEN** Small renders

**THEN** BLOCKED, 5-hour blocker, recovery timer, limiting ring percentage, and account identity are understandable without opening the app.

### AC2 — Medium configuration

**GIVEN** three selected accounts in mixed states

**WHEN** Medium renders or Refresh Now is invoked

**THEN** only those accounts appear/refresh, degraded statuses are prioritized, and unselected accounts are untouched.

### AC3 — Large complete view

**GIVEN** fixtures for all six accounts and every initial window

**WHEN** Large renders

**THEN** all six are represented, all required windows/resets are accessible, and blocked/error states lead the hierarchy.

### AC4 — Representation consistency

**GIVEN** the same snapshot in Used and Remaining modes

**WHEN** the global preference changes

**THEN** all rings/bars/labels complement each other and availability does not change.

### AC5 — Degraded honesty

**GIVEN** authentication-required, transient error with history, expired/unavailable, loading, and post-reset-pending fixtures

**WHEN** each family renders

**THEN** none displays current availability and historical age/context is unambiguous.

### AC6 — Native/accessibility behavior

**GIVEN** dark/light/vibrant modes, increased text size, VoiceOver, keyboard control, and reduced motion

**WHEN** widgets render and actions receive focus

**THEN** information remains legible, ordered, labeled, and operable without provider-color dependence.

## 6. Errors and edge cases

Cover empty configuration, disconnected selections, snapshot decode failure, very long account/window labels, reset in seconds versus days, timer reaching zero before refreshed data, action timeout, and delayed WidgetKit reload. At timer zero the status must follow parent post-reset verification, not flip locally to AVAILABLE.

## 7. Repository constraints and reuse

Target macOS 14 WidgetKit families `.systemSmall`, `.systemMedium`, and `.systemLarge`; use App Intent configuration. Follow Apple's documented reload budgets (commonly 40–70 daily refreshes and timeline entries at least roughly five minutes apart). The native timer is presentation, not a timeline-entry-per-second workaround.

## 8. Test and verification strategy

- SwiftUI previews/visual regression fixtures cover every state/family/display mode.
- UI/accessibility tests inspect labels, ordering, actions, contrast, Dynamic Type behavior, and selection persistence.
- App Intent tests verify distinct account choices and contextual refresh IDs.
- Manual desktop verification covers vibrant/translucent system rendering and actual native timer behavior.

## 9. Migration, rollout, and rollback

No migration. Removing widget configurations does not affect accounts or snapshots. Invalid old configuration IDs fall back to an explicit unconfigured state.

## 10. Assumptions and open questions

### Confirmed assumptions

- Widget display can lag the persisted snapshot because WidgetKit owns rendering cadence.

### Blocking questions

- None.
