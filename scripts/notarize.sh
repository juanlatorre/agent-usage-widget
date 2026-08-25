#!/bin/bash
set -euo pipefail

# Notarize + staple a Developer ID DMG/ZIP (the developer team).
# Credentials must come from env (never committed):
#   Option 1 (API key, recomendado — no expira cada 30 días):
#     APPLE_API_KEY_PATH=/path/to/AuthKey_XXXX.p8
#     APPLE_API_KEY_ID=XXXX
#     APPLE_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   Option 2 (Apple ID + app-specific password):
#     APPLE_ID="tu@apple.id"                # Apple ID del Team the team
#     APPLE_APP_SPECIFIC_PASSWORD="abcd-..." # app-specific password (appleid.apple.com)
#     APPLE_TEAM_ID=Y3DAXDSX2F
#
# Usage:
#   scripts/notarize.sh .derived-validate/AgentUsage-1.0-arm64.dmg
#   scripts/notarize.sh --key /path/to/key.p8 --key-id XXX --issuer YYY .derived-validate/AgentUsage-1.0-arm64.dmg

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${APPLE_TEAM_ID:-Y3DAXDSX2F}"

usage() {
  cat <<'USAGE'
Usage: scripts/notarize.sh [options] <path-to-dmg-or-zip>

Options (alternativas):
  --key PATH --key-id ID --issuer UUID   API key auth (notarytool --key --key-id --issuer)
  --apple-id EMAIL --password PWD --team TEAM   Apple ID auth

Env (recomendado, no pasar secrets por argv):
  APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER
  APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID (default: Y3DAXDSX2F)

Ejemplos:
  APPLE_API_KEY_PATH=~/AuthKey.p8 APPLE_API_KEY_ID=ABCD APPLE_API_ISSUER=uuid scripts/notarize.sh .derived-validate/AgentUsage-1.0-arm64.dmg
  APPLE_ID=you@example.com APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx scripts/notarize.sh .derived-validate/AgentUsage-1.0-arm64.dmg
USAGE
}

KEY_PATH="${APPLE_API_KEY_PATH:-}"
KEY_ID="${APPLE_API_KEY_ID:-}"
ISSUER="${APPLE_API_ISSUER:-}"
APPLE_ID="${APPLE_ID:-}"
APP_PWD="${APPLE_APP_SPECIFIC_PASSWORD:-}"

FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY_PATH="$2"; shift 2 ;;
    --key-id) KEY_ID="$2"; shift 2 ;;
    --issuer) ISSUER="$2"; shift 2 ;;
    --apple-id) APPLE_ID="$2"; shift 2 ;;
    --password) APP_PWD="$2"; shift 2 ;;
    --team) TEAM_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; FILE="${1:-}"; break ;;
    -*) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
    *) FILE="$1"; shift ;;
  esac
done
[[ -z "$FILE" && $# -gt 0 ]] && FILE="$1"

if [[ -z "${FILE:-}" || ! -f "$FILE" ]]; then
  echo "❌ Falta archivo: scripts/notarize.sh <ruta-dmg>" >&2
  usage; exit 1
fi

FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

echo "== Notarización (Team $TEAM_ID) =="
echo "Archivo: $FILE"
ls -lh "$FILE"

# Pre-check: debe estar firmado Developer ID (no ad-hoc) o Apple lo rechazará
if codesign -dv --verbose=2 "$FILE" 2>&1 | grep -qi "Signature=adhoc\|flags=0x2"; then
  # DMG ad-hoc pasa, pero el .app dentro no — chequea el app dentro del DMG si aplica
  MOUNT_TMP="$(mktemp -d)"
  if hdiutil attach "$FILE" -nobrowse -readonly -mountpoint "$MOUNT_TMP" -quiet 2>/dev/null; then
    APP_ON_DMG="$(find "$MOUNT_TMP" -maxdepth 2 -name "*.app" -type d | head -1 || true)"
    if [[ -n "$APP_ON_DMG" ]]; then
      if codesign -dv --verbose=2 "$APP_ON_DMG" 2>&1 | grep -qi "Signature=adhoc\|TeamIdentifier=not set"; then
        echo "❌ El .app dentro del DMG es ad-hoc (sin Developer ID). Notaría fallará."
        echo "   Crea el cert Developer ID Application (Y3DAXDSX2F) y re-empaqueta con scripts/package-signed-dmg.sh"
        hdiutil detach "$MOUNT_TMP" -quiet 2>/dev/null || true
        exit 1
      fi
      echo "✅ .app dentro del DMG está firmado Developer ID (pre-check OK)"
    fi
    hdiutil detach "$MOUNT_TMP" -quiet 2>/dev/null || true
  fi
fi

# Submit
echo ""
echo "-- Enviando a Apple notary service (esto tarda 1-5 min) --"

SUBMIT_ARGS=(xcrun notarytool submit "$FILE" --wait)

if [[ -n "$KEY_PATH" && -n "$KEY_ID" && -n "$ISSUER" ]]; then
  echo "Auth: API key ($KEY_ID)"
  SUBMIT_ARGS+=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER")
elif [[ -n "$APPLE_ID" && -n "$APP_PWD" ]]; then
  echo "Auth: Apple ID ($APPLE_ID)"
  SUBMIT_ARGS+=(--apple-id "$APPLE_ID" --password "$APP_PWD" --team-id "$TEAM_ID")
else
  echo "❌ Falta auth. Configura uno de:"
  echo "   export APPLE_API_KEY_PATH=~/AuthKey_XXXX.p8 APPLE_API_KEY_ID=XXXX APPLE_API_ISSUER=xxxx-xxxx-..."
  echo "   o export APPLE_ID=tu@apple.id APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx APPLE_TEAM_ID=Y3DAXDSX2F"
  echo ""
  echo "Cómo generar:"
  echo "  API key: App Store Connect → Users and Access → Keys → Team API Keys → Generate (Admin) → descarga .p8, anota Key ID e Issuer ID"
  echo "  App password: appleid.apple.com → App-Specific Passwords → Generate"
  exit 1
fi

# notarytool log va a stdout — guardarlo
LOG_FILE="$(mktemp)"
set +e
"${SUBMIT_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
STATUS=${PIPESTATUS[0]}
set -e

if [[ $STATUS -ne 0 ]]; then
  echo ""
  echo "❌ notarytool submit falló (ver log arriba). Si dice 'Invalid credentials', regenera la key/password."
  echo "Log: $LOG_FILE"
  exit $STATUS
fi

# Check result contains Accepted
if ! grep -qi "status: Accepted" "$LOG_FILE"; then
  echo "⚠️  No se confirmó 'Accepted' — revisa el log: $LOG_FILE"
  if grep -qi "Invalid\|Rejected" "$LOG_FILE"; then
    exit 1
  fi
fi
echo "✅ Notarización Accepted"

# Staple (pega el ticket al DMG para Gatekeeper offline)
echo ""
echo "-- Stapling ticket --"
xcrun stapler staple "$FILE" 2>&1 | tee -a "$LOG_FILE"
xcrun stapler validate "$FILE" 2>&1 | tee -a "$LOG_FILE" || true

echo ""
echo "-- Gatekeeper check --"
spctl --assess --type open --context context:primary-signature -v "$FILE" 2>&1 || {
  echo "⚠️  spctl assess falló — puede ser que el staple aún no esté listo (reintenta en 30s: xcrun stapler validate '$FILE')"
}

echo ""
echo "== ✅ Listo para compartir =="
echo "DMG notarizado: $FILE"
echo "Tu amigo puede abrirlo sin right-click → Gatekeeper lo ve como de the developer team, notarizado por Apple."
rm -f "$LOG_FILE"
