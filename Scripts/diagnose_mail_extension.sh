#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.bao3.MailKBAI.Extension"
LEGACY_BUNDLE_ID="com.bao3.AppleMailAI.Extension"
SERVICE="com.bao3.MailKBAI.vertex-api-key"
LEGACY_SERVICE="com.bao3.AppleMailAI.vertex-api-key"
ACCOUNT="vertex-api-key"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_DIR/MailKBAI.app"
APPEX_PATH="$APP_PATH/Contents/PlugIns/MailKBAIExtension.appex"

section() {
  printf "\n============================================================\n"
  printf " %s\n" "$1"
  printf "============================================================\n"
}

section "1. System & Mail.app Environment"
sw_vers || true
defaults read /System/Applications/Mail.app/Contents/Info CFBundleShortVersionString 2>/dev/null | sed 's/^/Mail.app Version: /' || true
pgrep -fl "MailKBAIExtension|MailKBAI" || echo "(No MailKBAIExtension / MailKBAI process currently running)"

section "2. Installed App & Extension Bundle Check"
if [[ -d "$APP_PATH" ]]; then
  echo "✅ Host App found: $APP_PATH"
else
  echo "❌ Host App NOT found at $APP_PATH (run: make install)"
fi

if [[ -d "$APPEX_PATH" ]]; then
  echo "✅ Extension found: $APPEX_PATH"
  echo "--- Extension Info.plist (NSExtension) ---"
  /usr/libexec/PlistBuddy -c "Print :NSExtension" "$APPEX_PATH/Contents/Info.plist" 2>/dev/null || true
  ICON_NAME="$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:MEComposeSession:MEComposeIcon" "$APPEX_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$ICON_NAME" ]]; then
    echo "✅ MEComposeIcon configured: $ICON_NAME"
    if [[ -f "$APPEX_PATH/Contents/Resources/Assets.car" ]]; then
      echo "✅ Compiled asset catalog present: Assets.car"
    else
      echo "⚠️  Assets.car missing in $APPEX_PATH/Contents/Resources/ (toolbar button icon may not render)"
    fi
  else
    echo "❌ MEComposeSession:MEComposeIcon missing in Extension Info.plist!"
  fi
else
  echo "❌ Extension NOT found at $APPEX_PATH"
fi

section "3. Code Signing & Entitlements Verification"
if [[ -d "$APP_PATH" ]]; then
  if codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1; then
    echo "✅ Deep strict codesign verification PASSED"
  else
    echo "❌ Codesign verification FAILED"
  fi
fi
if [[ -d "$APPEX_PATH" ]]; then
  echo "--- Extension Entitlements ---"
  codesign -d --entitlements :- "$APPEX_PATH" 2>/dev/null || true
fi

section "4. PlugInKit Registration & Duplicate Detection"
PK_OUT="$(pluginkit -m -v -A -D -i "$BUNDLE_ID" 2>&1 || true)"
echo "$PK_OUT"
REG_COUNT="$(printf "%s\n" "$PK_OUT" | grep -c "$BUNDLE_ID" || true)"
if [[ "$REG_COUNT" -eq 0 ]]; then
  echo "❌ Extension is NOT registered in PlugInKit. Run: make install"
elif [[ "$REG_COUNT" -gt 1 ]]; then
  echo "⚠️  DUPLICATE PlugInKit registrations detected ($REG_COUNT copies)!"
  echo "   Stale DerivedData copies often confuse Mail.app. Run: make reset-pluginkit"
else
  echo "✅ Single clean PlugInKit registration found."
fi
if printf "%s\n" "$PK_OUT" | grep -q "^+"; then
  echo "✅ Extension is ENABLED (+) in PlugInKit."
else
  echo "⚠️  Extension is NOT enabled (+) yet. Enable it in: Mail → Settings → Extensions."
fi

LEGACY_PK_OUT="$(pluginkit -m -v -A -D -i "$LEGACY_BUNDLE_ID" 2>&1 || true)"
LEGACY_REG_COUNT="$(printf "%s\n" "$LEGACY_PK_OUT" | grep -c "$LEGACY_BUNDLE_ID" || true)"
if [[ "$LEGACY_REG_COUNT" -gt 0 ]]; then
  echo "⚠️  Legacy $LEGACY_BUNDLE_ID is still registered in PlugInKit ($LEGACY_REG_COUNT copies). Run: make reset-pluginkit"
fi

section "5. Keychain Credential Check (Non-Secret)"
if security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
  echo "✅ Keychain item exists (service=$SERVICE, account=$ACCOUNT)"
elif security find-generic-password -s "$LEGACY_SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
  echo "ℹ️  Legacy Keychain item exists (service=$LEGACY_SERVICE, account=$ACCOUNT; automatic fallback active)"
else
  echo "⚠️  Keychain item NOT found. Run: make provision-key"
fi

section "6. Recent Crash Reports (Mail & MailKBAIExtension)"
CRASH_FOUND=0
for dir in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
  if [[ -d "$dir" ]]; then
    while IFS= read -r report; do
      [[ -z "$report" ]] && continue
      CRASH_FOUND=1
      echo "--- Crash Report: $report ---"
      python3 - "$report" <<'PY' 2>/dev/null || head -n 40 "$report"
import json, sys
path = sys.argv[1]
with open(path, "r", errors="replace") as f:
    lines = f.read().splitlines()
if len(lines) >= 2 and lines[0].startswith("{"):
    meta = json.loads(lines[0])
    body = json.loads("\n".join(lines[1:]))
    print("  app_name:", meta.get("app_name"), "timestamp:", meta.get("timestamp"))
    exc = body.get("exception", {})
    term = body.get("termination", {})
    print("  exception:", exc.get("type"), exc.get("signal"), exc.get("subtype"))
    if term:
        print("  termination:", term.get("namespace"), term.get("indicator"), term.get("reasons"))
    fault = body.get("faultingThread")
    threads = body.get("threads", [])
    if isinstance(fault, int) and 0 <= fault < len(threads):
        frames = threads[fault].get("frames", [])[:12]
        images = body.get("usedImages", [])
        print(f"  faultingThread ({fault}) top frames:")
        for fr in frames:
            img_idx = fr.get("imageIndex")
            img_name = images[img_idx].get("name", "?") if isinstance(img_idx, int) and img_idx < len(images) else "?"
            sym = fr.get("symbol", "<no symbol>")
            print(f"    {img_name}: {sym}")
else:
    print("\n".join(lines[:30]))
PY
    done < <(find "$dir" -maxdepth 2 \( -name "Mail-*.ips" -o -name "MailKBAIExtension-*.ips" -o -name "MailKBAI-*.ips" \) -mtime -7 2>/dev/null | sort -r | head -n 5)
  fi
done
if [[ "$CRASH_FOUND" -eq 0 ]]; then
  echo "✅ No recent Mail / MailKBAIExtension .ips crash reports found in the last 7 days."
fi

section "7. Recent Unified Logs (Last 10 Minutes)"
log show --last 10m --style compact --predicate 'subsystem == "com.bao3.MailKBAI" OR process == "MailKBAIExtension"' 2>/dev/null | tail -n 40 || true

echo ""
echo "Tip: Stream live logs while reproducing with: make logs"
