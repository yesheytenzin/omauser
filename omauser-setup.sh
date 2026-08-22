#!/usr/bin/env bash
# Omauser setup - installs the bridge into ~/.cache/omauser and writes the
# API config. Never writes inside the plugin dir (omarchy watches it with
# inotify - any write triggers a full shell plugin reload).
#
# Usage: omauser-setup.sh [api-url]
#   api-url defaults to $OMAUSER_API_URL or the value baked at install time.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${XDG_CACHE_HOME:-$HOME/.cache}/omauser"
BRIDGE_SRC="$DIR/bridge/omauser-bridge.sh"
BRIDGE_DST="$RUNTIME/omauser-bridge.sh"
CONFIG="$RUNTIME/config.json"
VERSION="$(jq -er '.version' "$DIR/manifest.json" 2>/dev/null || echo "0.0.0")"
VERSION_FILE="$RUNTIME/version"

# The public Cloudflare Worker URL. Replace with your deployed worker, or
# pass it as the first argument / OMAUSER_API_URL env var.
DEFAULT_API_URL="${OMAUSER_API_URL:-https://omauser.YOUR_SUBDOMAIN.workers.dev}"
API_URL="${1:-$DEFAULT_API_URL}"

say()  { printf '\033[1;36m[omauser]\033[0m %s\n' "$*"; }

mkdir -p "$RUNTIME"

if [[ -x "$BRIDGE_DST" && -f "$VERSION_FILE" && "$(cat "$VERSION_FILE")" == "$VERSION" && -f "$CONFIG" ]]; then
  say "bridge $VERSION already installed"
  exit 0
fi

install -Dm0755 "$BRIDGE_SRC" "$BRIDGE_DST"
printf '%s' "$VERSION" > "$VERSION_FILE"
jq -n --arg url "$API_URL" --arg version "$VERSION" \
  '{ apiUrl: $url, version: $version }' > "$CONFIG"
printf '%s\n' "$VERSION" > "$VERSION_FILE"

say "installed bridge $VERSION"
say "API: $API_URL"
if [[ "$API_URL" == *YOUR_SUBDOMAIN* ]]; then
  printf '\033[1;33m[omauser]\033[0m warning: default API URL not deployed yet.\n' >&2
  printf '\033[1;33m[omauser]\033[0m deploy server/ with wrangler, then edit %s\n' "$CONFIG" >&2
fi
