#!/bin/bash
set -euo pipefail

# Package Agent Usage as a Developer ID–signed + hardened-runtime DMG (the developer team).
# Requires:  Developer ID Application certificate for Y3DAXDSX2F in login keychain.
# For ad-hoc fallback (no cert), omit --team and it will produce an unsigned DMG.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentUsage"
PROJECT="$ROOT/App/AgentUsage.xcodeproj"
SCHEME="AgentUsage"
DERIVED="$ROOT/.derived-validate"
ARCHIVE_DIR="$DERIVED/Archive"
STAGING="$DERIVED/dmg-staging"
TEAM_ID="Y3DAXDSX2F"
IDENTITY="Developer ID Application"
VERSION="${VERSION:-1.0}"
ARCH="${ARCH:-arm64}"

usage() {
  cat <<'USAGE'
Usage: scripts/package-signed-dmg.sh [--team TEAM_ID] [--identity "Developer ID Application"]
                                     [--version 1.0] [--no-archive]

  --team TEAM_ID     Apple Team ID (default: Y3DAXDSX2F / the developer team)
  --identity NAME    Codesign identity prefix (default: "Developer ID Application")
  --version VER      CFBundleShortVersionString override for DMG name (default: 1.0)
  --no-archive       Reuse existing .xcarchive at .derived-validate/Archive/AgentUsage.xcarchive

Requires a valid Developer ID Application cert for the team in the login keychain.
To create it: Xcode → Settings → Accounts → Select the developer team team → Manage Certificates… → + → Developer ID Application
(or developer.apple.com → Certificates → + → Developer ID Application → upload CSR from Keychain Access → download .cer → double-click).
USAGE
}

TEAM="$TEAM_ID"
NO_ARCHIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --no-archive) NO_ARCHIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

redact() { sed -E 's/(Bearer )[A-Za-z0-9._\-]+/\1[REDACTED]/g; s/(apiKey|accessToken|refresh)[^ ]*/\1=[REDACTED]/g'; }

echo "== Agent Usage — signed DMG (the developer team / $TEAM) =="
echo "Root: $ROOT"
echo "Team: $TEAM  Identity: $IDENTITY"

# 1) Check for Developer ID identity (warn, don't fail — allow ad-hoc for testing)
FOUND_IDENTITY="$(security find-identity -v -p codesigning 2>&1 | grep -i "Developer ID Application" | head -1 || true)"
if [[ -z "$FOUND_IDENTITY" ]]; then
  echo ""
  echo "⚠️  No 'Developer ID Application' identity found in keychain."
  echo "   Current codesigning identities:"
  security find-identity -v -p codesigning 2>&1 | sed 's/^/   /' || true
  echo ""
  echo "   Create it: Xcode → Settings → Accounts → the developer team → Manage Certificates → + → Developer ID Application"
  echo "   or: developer.apple.com → Certificates → + → Developer ID Application (upload CSR, download .cer, double-click)."
  echo ""
  echo "   Continuing ad-hoc (friend will need right-click → Open). Re-run after installing the cert for Gatekeeper-clean DMG."
  SIGN_ARGS=()
else
  echo "✅ Found: $FOUND_IDENTITY" | redact
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--options runtime --timestamp")
fi

# 2) Archive (Release, arm64, macOS 14)
ARCHIVE_PATH="$ARCHIVE_DIR/$APP_NAME.xcarchive"
if [[ "$NO_ARCHIVE" == 1 && -d "$ARCHIVE_PATH" ]]; then
  echo ""
  echo "-- Reusing existing archive at $ARCHIVE_PATH --"
else
  echo ""
  echo "-- Archiving Release (arm64, macOS 14) --"
  rm -rf "$DERIVED/Archive" "$STAGING"
  mkdir -p "$ARCHIVE_DIR"
  # xcodebuild archive — signing identity/team injected via SIGN_ARGS when available
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    SKIP_INSTALL=NO \
    "${SIGN_ARGS[@]}" \
    2>&1 | redact | tail -n 80
  echo "Archive: $ARCHIVE_PATH"
fi

ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
WIDGET_APP="$ARCHIVE_APP/Contents/PlugIns/AgentUsageWidget.appex"
[[ -d "$ARCHIVE_APP" ]] || { echo "❌ Archive app missing at $ARCHIVE_APP" >&2; exit 1; }
[[ -d "$WIDGET_APP" ]] || { echo "❌ Widget appex missing at $WIDGET_APP" >&2; exit 1; }

echo ""
echo "-- Verifying signatures --"
codesign -dv --verbose=2 "$ARCHIVE_APP" 2>&1 | redact | head -n 30 || true
codesign --verify --deep --strict "$ARCHIVE_APP" 2>&1 | redact | head -n 20 || true
if security find-identity -v -p codesigning 2>&1 | grep -qi "Developer ID Application"; then
  # When signed with Developer ID, hardened runtime flag 0x10000 must be present
  if codesign -dv --verbose=2 "$ARCHIVE_APP" 2>&1 | grep -qi "flags=.*0x10000\|runtime"; then
    echo "✅ Hardened runtime enabled"
  else
    echo "⚠️  Hardened runtime flag not detected — ensure OTHER_CODE_SIGN_FLAGS includes --options runtime"
  fi
else
  echo "(ad-hoc: flags 0x2 expected)"
fi
echo "  archs app:    $(lipo -archs "$ARCHIVE_APP/Contents/MacOS/$APP_NAME" 2>&1)"
echo "  archs widget: $(lipo -archs "$WIDGET_APP/Contents/MacOS/AgentUsageWidget" 2>&1)"

# 3) Stage + DMG
DMG="$DERIVED/$APP_NAME-$VERSION-$ARCH.dmg"
VOLNAME="Agent Usage"
echo ""
echo "-- Staging DMG --"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$ARCHIVE_APP" "$STAGING/$APP_NAME.app"
ln -sf /Applications "$STAGING/Applications"
du -sh "$STAGING/$APP_NAME.app" | redact

echo ""
echo "-- Creating DMG (UDZO) --"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" 2>&1 | tail -n 10
ls -lh "$DMG" | redact
shasum -a 256 "$DMG" | redact

echo ""
echo "-- Verifying DMG mount --"
hdiutil attach "$DMG" -nobrowse -readonly -quiet 2>&1 | tail -n 5 || true
ls -lh "/Volumes/$VOLNAME" 2>&1 | head -n 20
if [[ -d "/Volumes/$VOLNAME/$APP_NAME.app" ]]; then
  codesign --verify --deep --strict "/Volumes/$VOLNAME/$APP_NAME.app" 2>&1 | head -n 10 || true
  echo "✅ DMG mount verify OK"
  hdiutil detach "/Volumes/$VOLNAME" -quiet 2>&1 | tail -n 2 || true
fi

# Also copy to repo root for convenience (untracked)
cp -f "$DMG" "$ROOT/$APP_NAME-$VERSION-$ARCH.dmg" 2>&1 && echo "Copied to $ROOT/$APP_NAME-$VERSION-$ARCH.dmg (untracked — add to .gitignore if you don't want it in git)"

echo ""
if security find-identity -v -p codesigning 2>&1 | grep -qi "Developer ID Application"; then
  echo "== ✅ Signed DMG ready (Developer ID, hardened runtime) =="
  echo "DMG: $DMG"
  echo "Next: notarize → scripts/notarize.sh \"$DMG\"  (requires APPLE_ID + app-specific password or API key)"
  echo "     then: xcrun stapler staple \"$DMG\"  and share"
else
  echo "== ✅ Ad-hoc DMG ready (friend needs right-click → Open) =="
  echo "DMG: $DMG"
  echo "To make it Gatekeeper-clean: install Developer ID Application cert for $TEAM and re-run this script."
fi
