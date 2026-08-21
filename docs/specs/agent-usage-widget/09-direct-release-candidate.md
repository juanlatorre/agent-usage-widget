# PRD — Direct release candidate

- **Status:** READY
- **Destination:** The integrated macOS app, login helper, and widget form an installable arm64 archive with reproducible signing/notarization and no secret leakage.
- **Owner:** Juan Latorre
- **Created:** 2026-08-21
- **Size:** LARGE-CHILD
- **Domain impact:** STABLE
- **Scope:** Integrated entitlements, bundle identities, versioning, archive/export/notarization tooling, privacy inspection, installation/upgrade/uninstall behavior, and end-to-end release verification.
- **Parent:** [`../agent-usage-widget.md`](../agent-usage-widget.md)
- **Related ADRs:** ADR-0001, ADR-0003, ADR-0004

## 1. Summary

The feature set becomes a coherent directly distributable candidate rather than separate targets that only run from Xcode.

## 2. Objectives and non-objectives

### Objectives

- **O1:** Archive app/helper/widget together for macOS 14 arm64 with production bundle relationships and least-privilege entitlements.
- **O2:** Make Developer ID signing, hardened runtime, notarization, stapling, and package verification reproducible with external credentials.
- **O3:** Verify first launch, login-agent lifecycle, widget discovery, upgrade, disconnect, and cleanup as one installed product.
- **O4:** Prove no credential or authenticated payload enters source, build logs, App Group snapshots, widget bundle, diagnostics, or release artifacts.

### Non-objectives

- **NO1:** Publishing a release, uploading without explicit authorization, automatic update infrastructure, Mac App Store packaging, or Intel binaries.
- **NO2:** Committing Apple certificates, account credentials, notarization profiles, provider tokens, or personal source profiles.

## 3. Flow

```text
Build/test all targets
→ archive arm64 app with embedded login item + widget
→ inspect bundle IDs, signing, hardened runtime, App Group and Keychain entitlements
→ export/sign with externally supplied Developer ID credentials
→ notarize and staple when authorized credentials are available
→ install cleanly and run integrated acceptance scenarios
```

## 4. Rules and invariants

- **R1:** The widget has App Group access for non-secret data and no Keychain credential access. Only app/helper receive the minimum shared Keychain entitlement needed.
- **R2:** Helper/widget bundle IDs, team settings, versions, and embedding relationships are internally consistent and validated by archive tooling.
- **R3:** Hardened runtime is enabled. Any decision not to use App Sandbox must be limited to narrow allowlisted profile discovery/access and documented in release security notes; broad home-directory crawling is prohibited.
- **R4:** Build/release scripts accept signing/notary identities through environment, Keychain profiles, or CI secret stores and redact output. They work in a no-secret validation mode.
- **R5:** Archive validation rejects arm64 mismatch, unsigned nested code, forbidden entitlements, credential-like files, or snapshots containing secret fields.
- **R6:** Upgrade preserves non-secret preferences/snapshots and Keychain entries; downgrade or uninstall cannot leave a running orphan helper after explicit cleanup.
- **R7:** No push, remote release, upload, or deployment occurs under this child without separate user authorization. Local checkpoint commits remain IDD mechanics only.
- **R8:** User-facing version/build information and diagnostics contain no provider credential material.

## 5. Acceptance criteria

### AC1 — Archive composition

**GIVEN** a clean checkout on supported hardware

**WHEN** release archive validation runs

**THEN** app, helper, and widget build for macOS 14 arm64 and nested-code/bundle/entitlement checks pass.

### AC2 — Security boundary

**GIVEN** connected-account test fixtures

**WHEN** App Group files, defaults, logs, widget bundle, archive, and diagnostics are scanned

**THEN** no OAuth/API/access/refresh token or authenticated raw payload is present.

### AC3 — Signing/notarization workflow

**GIVEN** valid external Developer ID and notarization credentials

**WHEN** documented tooling runs

**THEN** signatures verify, notarization succeeds, the ticket is stapled, and Gatekeeper assessment passes. Without credentials, no-secret dry-run validation passes and reports the external prerequisite rather than claiming notarization.

### AC4 — Installed lifecycle

**GIVEN** a clean installation

**WHEN** the first account connects, the user logs in again, adds each widget size, disables/re-enables background refresh, upgrades, disconnects, and performs cleanup

**THEN** the helper/widget/app behave according to their specs without orphan processes or cross-slot data loss.

### AC5 — Integrated success view

**GIVEN** six controlled provider fixtures matching the success criterion

**WHEN** the installed app and Large widget render

**THEN** the user can identify every AVAILABLE/BLOCKED account, blockers, resets, and historical/degraded states in accordance with the parent criteria.

## 6. Errors and edge cases

Cover missing signing identity, notarization outage, rejected entitlement, app moved after install, helper version mismatch, widget not yet discovered, denied login-item approval, upgrade during refresh, and cleanup while helper runs. Tooling must stop safely with truthful evidence.

## 7. Repository constraints and reuse

Use Apple-supported Xcode archive/export, `codesign`, notarization, stapling, and Gatekeeper verification. Secrets remain external. Direct distribution does not authorize publishing.

## 8. Test and verification strategy

- Run all unit/integration/UI tests and Release configuration builds.
- Validate architecture, deployment targets, embedded provisioning/signatures, entitlements, rpaths, nested code, bundle versions, and privacy scan.
- Run a temporary-user or clean-state installed lifecycle smoke test.
- Record exact commands/results; distinguish dry-run from credentialed notarization evidence.

## 9. Migration, rollout, and rollback

First release has no migration. Upgrade tests cover schema/version compatibility created by earlier children. Rollback instructions unregister the helper and remove app-owned artifacts without modifying external provider profiles.

## 10. Assumptions and open questions

### Confirmed assumptions

- Developer ID/notarization credentials are external operational prerequisites and may not be available in every implementation session.

### Blocking questions

- None.
