#!/usr/bin/env bash
# ActivityWatch → Aurboda push agent
# Run periodically (e.g. every 5 minutes) via cron or systemd timer.
#
# Reads shared config from ~/.config/aurboda/config which should contain:
#   AURBODA_BASE_URL=https://aurboda.net
#   AURBODA_TOKEN=your-token-here
#   DEVICE_NAME=spanda   # optional, defaults to hostname

set -euo pipefail

CONFIG_FILE="$HOME/.config/aurboda/config"

# Load shared config if present
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

# ── Configuration ─────────────────────────────────────────────────────────────
AURBODA_URL="${AURBODA_URL:-${AURBODA_BASE_URL:-https://aurboda.net}/api}"
AURBODA_TOKEN="${AURBODA_TOKEN:-}"
DEVICE_NAME="${DEVICE_NAME:-$(hostname)}"
AW_URL="${AW_URL:-http://localhost:5600}"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/aw-aurboda/last_sync"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-1}"
# ──────────────────────────────────────────────────────────────────────────────

if [[ -z "$AURBODA_TOKEN" ]]; then
  echo "ERROR: AURBODA_TOKEN is not set" >&2
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"

# Determine time window
if [[ -f "$STATE_FILE" ]]; then
  START_TIME=$(cat "$STATE_FILE")
else
  START_TIME=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-${LOOKBACK_HOURS}H +%Y-%m-%dT%H:%M:%SZ)  # macOS fallback
fi
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Find the aw-watcher-window bucket for this host
BUCKET_ID=$(curl -sf "${AW_URL}/api/0/buckets/" \
  | python3 -c "
import sys, json
buckets = json.load(sys.stdin)
for bid, b in buckets.items():
    if b.get('type') == 'currentwindow':
        print(bid)
        break
" || true)

if [[ -z "$BUCKET_ID" ]]; then
  echo "No aw-watcher-window bucket found — is ActivityWatch running?" >&2
  exit 0
fi

# Fetch events
EVENTS=$(curl -sf \
  "${AW_URL}/api/0/buckets/${BUCKET_ID}/events?start=${START_TIME}&end=${END_TIME}&limit=10000")

EVENT_COUNT=$(echo "$EVENTS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [[ "$EVENT_COUNT" -eq 0 ]]; then
  echo "No events in range ${START_TIME} → ${END_TIME}"
  echo "$END_TIME" > "$STATE_FILE"
  exit 0
fi

echo "🚀 Pushing ${EVENT_COUNT} events (${START_TIME} → ${END_TIME}) as device '${DEVICE_NAME}'"

# Transform and push
PAYLOAD=$(DEVICE_NAME="$DEVICE_NAME" python3 -c "
import sys, json, os
events = json.loads(sys.stdin.read())
device_name = os.environ.get('DEVICE_NAME', '')
transformed = []
for e in events:
    app = e.get('data', {}).get('app', '')
    if not app:
        continue
    transformed.append({
        'timestamp': e['timestamp'],
        'duration': e['duration'],
        'app': app,
        'title': e.get('data', {}).get('title', ''),
    })
print(json.dumps({'device_name': device_name, 'events': transformed}))
" <<< "$EVENTS")

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${AURBODA_URL}/sync/activitywatch" \
  -H "Authorization: bearer ${AURBODA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
  echo "✓ Pushed successfully (HTTP ${HTTP_STATUS})"
  echo "$END_TIME" > "$STATE_FILE"
else
  echo "✗ Push failed (HTTP ${HTTP_STATUS})" >&2
  exit 1
fi
