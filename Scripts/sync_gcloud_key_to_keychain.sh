#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-${1:-}}"
KEY_UID="${GCP_API_KEY_UID:-${2:-}}"
SERVICE="com.bao3.AppleMailAI.vertex-api-key"
ACCOUNT="vertex-api-key"

if [[ -z "$PROJECT_ID" || -z "$KEY_UID" ]]; then
  echo "Usage: GCP_PROJECT_ID=<your-project-id> GCP_API_KEY_UID=<your-api-key-uid> $0" >&2
  echo "   or: $0 <your-project-id> <your-api-key-uid>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v gcloud >/dev/null 2>&1; then
  echo "Error: gcloud CLI not found in PATH." >&2
  exit 1
fi

KEY_VALUE="$(gcloud services api-keys get-key-string "$KEY_UID" --project="$PROJECT_ID" --format='value(keyString)' --quiet)"
if [[ -z "${KEY_VALUE:-}" ]]; then
  echo "Error: Failed to retrieve Vertex AI API Key ($KEY_UID) from project $PROJECT_ID." >&2
  exit 1
fi

ACL_ARGS=(-T /usr/bin/security)
CANDIDATES=(
  "$REPO_ROOT/build/DerivedData/Build/Products/Release/AppleMailAI.app/Contents/MacOS/AppleMailAI"
  "$REPO_ROOT/build/DerivedData/Build/Products/Release/AppleMailAI.app/Contents/PlugIns/MailAIExtension.appex/Contents/MacOS/MailAIExtension"
  "$REPO_ROOT/build/DerivedData/Build/Products/Debug/AppleMailAI.app/Contents/MacOS/AppleMailAI"
  "$REPO_ROOT/build/DerivedData/Build/Products/Debug/AppleMailAI.app/Contents/PlugIns/MailAIExtension.appex/Contents/MacOS/MailAIExtension"
  "/Applications/AppleMailAI.app/Contents/MacOS/AppleMailAI"
  "/Applications/AppleMailAI.app/Contents/PlugIns/MailAIExtension.appex/Contents/MacOS/MailAIExtension"
  "$HOME/Applications/AppleMailAI.app/Contents/MacOS/AppleMailAI"
  "$HOME/Applications/AppleMailAI.app/Contents/PlugIns/MailAIExtension.appex/Contents/MacOS/MailAIExtension"
)

for bin in "${CANDIDATES[@]}"; do
  if [[ -x "$bin" ]]; then
    ACL_ARGS+=(-T "$bin")
  fi
done

# Delete existing item if present so ACL (-T) entries refresh cleanly.
security delete-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1 || true

security add-generic-password \
  -s "$SERVICE" \
  -a "$ACCOUNT" \
  -l "AppleMailAI Vertex AI API Key ($PROJECT_ID)" \
  -w "$KEY_VALUE" \
  "${ACL_ARGS[@]}" \
  -U

defaults write com.bao3.AppleMailAI com.bao3.AppleMailAI.vertexProjectID -string "$PROJECT_ID"
defaults write com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.vertexProjectID -string "$PROJECT_ID"
for group_dir in "$HOME/Library/Group Containers/"*".com.bao3.AppleMailAI"; do
  if [[ -d "$group_dir" ]]; then
    group_id="$(basename "$group_dir")"
    mkdir -p "$group_dir/Library/Preferences"
    defaults write "$group_dir/Library/Preferences/$group_id.plist" com.bao3.AppleMailAI.vertexProjectID -string "$PROJECT_ID"
  fi
done

unset KEY_VALUE
echo "Synced Vertex AI API Key into macOS Login Keychain (service=$SERVICE, account=$ACCOUNT, project=$PROJECT_ID)."
