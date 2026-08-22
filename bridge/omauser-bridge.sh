#!/usr/bin/env bash
# Omauser bridge - device registration, heartbeat and stats/map fetches.
# Pure bash + curl + jq: no venv, no python deps.
#
# Opt-in is the default: installing/enabling the plugin registers the device
# automatically. Opting out (panel -> Remove my device) stops sending and
# deletes the record; joining again re-registers.
#
# Usage:
#   omauser-bridge.sh status                print state.json (JSON)
#   omauser-bridge.sh register              register/heartbeat against the API
#   omauser-bridge.sh opt-out               remove device from the server map
#   omauser-bridge.sh join                  opt back in and register
#   omauser-bridge.sh stats                 GET /api/stats -> stats.json
#   omauser-bridge.sh map                   GET /api/map -> map.json
#   omauser-bridge.sh device-hash           print sha256 of /etc/machine-id
set -euo pipefail

RUNTIME="${OMAUSER_RUNTIME:-${XDG_CACHE_HOME:-$HOME/.cache}/omauser}"
STATE="$RUNTIME/state.json"
CONFIG="$RUNTIME/config.json"
STATS_CACHE="$RUNTIME/stats.json"
MAP_CACHE="$RUNTIME/map.json"
LOCK="$RUNTIME/bridge.lock"
VERSION="$(jq -er '.version // "0.0.0"' "$RUNTIME/manifest.json" 2>/dev/null || echo "0.0.0")"

API_URL="${OMAUSER_API_URL:-}"
[[ -z "$API_URL" && -f "$CONFIG" ]] && API_URL="$(jq -er '.apiUrl // ""' "$CONFIG" 2>/dev/null || true)"

# All diagnostics go to stderr; stdout carries only machine-readable data
# (JSON or plain values) that QML Process parsers consume.
say()  { printf '\033[1;36m[omauser]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[omauser]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[omauser]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$RUNTIME"

[[ -f "$STATE" ]] || echo '{"optedOut":false,"deviceHash":"","registered":false,"lastHeartbeat":0}' > "$STATE"

read_state()  { jq -er "$1 // empty" "$STATE" 2>/dev/null || echo ""; }
write_state() { jq "$@" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }

device_hash() {
  local id=""
  [[ -r /etc/machine-id ]] && id="$(tr -d '\n' < /etc/machine-id)"
  if [[ -z "$id" ]]; then
    local seed="$RUNTIME/device-seed"
    if [[ -f "$seed" ]]; then id="$(cat "$seed")"
    else {
      id="$(openssl rand -hex 16 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$HOSTNAME-$(date +%s%N)")"
      printf '%s' "$id" > "$seed"; chmod 600 "$seed"
    }
    fi
  fi
  local raw_hash
  raw_hash="$(printf '%s' "$id" | sha256sum | awk '{ print $1 }')"
  # Encrypt so even server admin cannot reverse to machine-id:
  # per-device salt stored locally, never sent. Server only sees HMAC(salt, hash).
  local salt_file="$RUNTIME/device-salt"
  local salt=""
  if [[ -f "$salt_file" ]]; then salt="$(cat "$salt_file")"
  else {
    salt="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || echo "omauser-$(date +%s%N)")"
    printf '%s' "$salt" > "$salt_file"; chmod 600 "$salt_file"
  }
  fi
  printf '%s' "${salt}${raw_hash}" | sha256sum | awk '{ print $1 }'
}

omarchy_version() {
  command -v omarchy-version >/dev/null 2>&1 \
    && omarchy-version 2>/dev/null | tr -d '\n' || echo ""
}

post_register() {
  local hash="$1"
  [[ -n "$API_URL" ]] || { warn "no API URL configured - run setup with the worker URL"; return 1; }
  local payload
  payload="$(jq -cn --arg h "$hash" --arg v "$(omarchy_version)" --arg a "$VERSION" \
    '{ deviceHash: $h, omarchyVersion: $v, appVersion: $a }')"
  local out
  # Retry with exponential backoff for free-tier 429/5xx
  local attempt=0 delay=1
  while [[ $attempt -lt 3 ]]; do
    if out="$(curl -sS --fail --max-time 15 -H 'content-type: application/json' \
        -d "$payload" "$API_URL/api/register" 2>&1)"; then
      local total active
      total="$(jq -er '.stats.total // 0' <<<"$out" 2>/dev/null || echo 0)"
      active="$(jq -er '.stats.active30d // 0' <<<"$out" 2>/dev/null || echo 0)"
      write_state --arg h "$hash" --argjson t "$total" --argjson a "$active" \
        '.deviceHash = $h | .registered = true | .lastHeartbeat = (now * 1000 | floor) | .lastTotal = $t | .lastActive = $a'
      if [[ -f "$STATS_CACHE" ]]; then
        jq --argjson t "$total" --argjson a "$active" \
          '.total = $t | .active30d = $a | .updatedAt = (now * 1000 | floor)' "$STATS_CACHE" \
          > "$STATS_CACHE.tmp" && mv "$STATS_CACHE.tmp" "$STATS_CACHE"
      fi
      say "registered (total $total, active $active)"
      return 0
    fi
    # If 429, respect Retry-After
    if grep -q "429" <<<"$out"; then delay=5; fi
    attempt=$((attempt+1)); [[ $attempt -lt 3 ]] && sleep $delay && delay=$((delay*2))
  done
  warn "registration failed: API unreachable ($API_URL)"
  return 1
}

fetch_json() {
  local endpoint="$1" outfile="$2"
  [[ -n "$API_URL" ]] || { warn "no API URL configured"; return 1; }
  local tmp="$outfile.tmp"
  local attempt=0 delay=1
  while [[ $attempt -lt 2 ]]; do
    if curl -sS --fail --max-time 15 "$API_URL/$endpoint" -o "$tmp"; then
      mv "$tmp" "$outfile"
      say "$endpoint -> $outfile"
      return 0
    fi
    attempt=$((attempt+1)); [[ $attempt -lt 2 ]] && sleep $delay
  done
  rm -f "$tmp"
  warn "$endpoint fetch failed - showing last cached data"
  return 1
}

cmd_status() {
  local conf="{}"
  [[ -f "$CONFIG" ]] && conf="$(cat "$CONFIG")"
  jq -cn --argjson s "$(cat "$STATE")" --argjson c "$conf" '
    $s + {
      version: $c.version // "",
      apiUrl: $c.apiUrl // "",
      statsFile: ("'"$STATS_CACHE"'")
    }'
}

cmd_register() {
  exec 9>"$LOCK"
  flock 9
  local opted_out hash
  opted_out="$(read_state '.optedOut')"
  [[ "$opted_out" == "true" ]] && { warn "opted out - run 'join' to rejoin the map"; exit 0; }
  hash="$(read_state '.deviceHash')"
  [[ -z "$hash" ]] && hash="$(device_hash)"
  post_register "$hash" || true
}

cmd_opt_out() {
  local hash
  hash="$(read_state '.deviceHash')"
  if [[ -n "$hash" && -n "$API_URL" ]]; then
    # Retry so a transient failure cannot silently leave the device on the map.
    local ok=0 attempt=0 delay=1
    while [[ $attempt -lt 3 ]]; do
      if curl -sS --fail --max-time 15 -H 'content-type: application/json' \
        -d "{\"deviceHash\":\"$hash\"}" "$API_URL/api/forget" >/dev/null 2>&1; then ok=1; break; fi
      attempt=$((attempt+1)); [[ $attempt -lt 3 ]] && sleep $delay && delay=$((delay*2))
    done
    [[ $ok -eq 1 ]] || warn "forget failed after retries - device may still appear; try leave again"
  fi
  exec 9>"$LOCK"
  flock 9
  write_state '.optedOut = true | .registered = false | .lastHeartbeat = 0'
  rm -f "$STATS_CACHE" "$MAP_CACHE"
  say "device removed from the map"
}

cmd_join() {
  exec 9>"$LOCK"
  flock 9
  write_state '.optedOut = false'
  local hash
  hash="$(read_state '.deviceHash')"
  [[ -z "$hash" ]] && hash="$(device_hash)"
  post_register "$hash" || true
}

cmd_heartbeat() {
  exec 9>"$LOCK"
  flock 9
  local opted_out hash last
  opted_out="$(read_state '.optedOut')"
  [[ "$opted_out" == "true" ]] && exit 0
  last="$(read_state '.lastHeartbeat')"
  hash="$(read_state '.deviceHash')"
  [[ -n "$hash" ]] || hash="$(device_hash)"
  local now_ms; now_ms="$(date +%s%3N)"
  if [[ -z "$last" || $(( now_ms - last )) -ge 82800000 ]]; then
    post_register "$hash" || true
  fi
}

case "${1:-}" in
  device-hash) device_hash ;;
  status)      cmd_status ;;
  register)    cmd_register ;;
  opt-out)     cmd_opt_out ;;
  join)        cmd_join ;;
  heartbeat)   cmd_heartbeat ;;
  stats)       fetch_json "api/stats" "$STATS_CACHE" ;;
  map)         fetch_json "api/map" "$MAP_CACHE" ;;
  map-force)   fetch_json "api/map?force=1" "$MAP_CACHE" ;;
  stats-force) fetch_json "api/stats?force=1" "$STATS_CACHE" ;;
  *)
    fail "unknown command: ${1:-<none>} (use status|register|opt-out|join|heartbeat|stats|map|map-force|stats-force|device-hash)"
    ;;
esac