#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "==> [1/5] Pulling latest main..."
git pull --ff-only origin main

echo "==> [2/5] Quitting Apple Mail & MailKBAI..."
osascript -e 'tell application "Mail" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "MailKBAI" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "AppleMailAI" to quit' >/dev/null 2>&1 || true
sleep 1

echo "==> [3/5] Running unit tests..."
make test

echo "==> [4/5] Building, signing, installing, and resetting PlugInKit..."
make install

echo "==> [5/5] Running ops diagnostics..."
make diagnose

echo ""
echo "✅ Done! You can now open Apple Mail and check Mail → Settings → Extensions."
