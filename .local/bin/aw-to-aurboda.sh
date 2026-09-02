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
# Use 5 minutes ago to give AFK watcher time to finalize heartbeats
END_TIME=$(date -u -d "5 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)  # macOS fallback

# Find the aw-watcher-window and aw-watcher-afk buckets for this host
BUCKETS_JSON=$(curl -sf "${AW_URL}/api/0/buckets/" || true)

BUCKET_ID=$(echo "$BUCKETS_JSON" | python3 -c "
import sys, json
buckets = json.load(sys.stdin)
for bid, b in buckets.items():
    if b.get('type') == 'currentwindow':
        print(bid)
        break
" || true)

AFK_BUCKET_ID=$(echo "$BUCKETS_JSON" | python3 -c "
import sys, json
buckets = json.load(sys.stdin)
for bid, b in buckets.items():
    if b.get('type') == 'afkstatus':
        print(bid)
        break
" || true)

if [[ -z "$BUCKET_ID" ]]; then
  echo "❌ No aw-watcher-window bucket found — is ActivityWatch running?" >&2
  exit 0
fi

# Fetch window events
EVENTS=$(curl -sf \
  "${AW_URL}/api/0/buckets/${BUCKET_ID}/events?start=${START_TIME}&end=${END_TIME}&limit=10000")

# Fetch AFK events (used to filter out idle screentime)
AFK_EVENTS="[]"
if [[ -n "$AFK_BUCKET_ID" ]]; then
  AFK_EVENTS=$(curl -sf \
    "${AW_URL}/api/0/buckets/${AFK_BUCKET_ID}/events?start=${START_TIME}&end=${END_TIME}&limit=10000" || echo "[]")
fi

EVENT_COUNT=$(echo "$EVENTS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [[ "$EVENT_COUNT" -eq 0 ]]; then
  echo "📭 No events in range ${START_TIME} → ${END_TIME}"
  echo "$END_TIME" > "$STATE_FILE"
  exit 0
fi

echo "🔍 Found ${EVENT_COUNT} events (${START_TIME} → ${END_TIME}) for device '${DEVICE_NAME}'"

# Transform, filter AFK, and push
PAYLOAD=$(DEVICE_NAME="$DEVICE_NAME" python3 -c "
import sys, json, os
from datetime import datetime, timedelta

events = json.loads(sys.argv[1])
afk_events = json.loads(sys.argv[2])
device_name = os.environ.get('DEVICE_NAME', '')

def parse_ts(ts):
    ts = ts.replace('Z', '+00:00')
    return datetime.fromisoformat(ts)

# Build list of AFK periods
afk_periods = []
for ae in afk_events:
    if ae.get('data', {}).get('status') == 'afk':
        start = parse_ts(ae['timestamp'])
        end = start + timedelta(seconds=ae['duration'])
        afk_periods.append((start, end))

def is_during_afk(evt_start, evt_end):
    for afk_start, afk_end in afk_periods:
        if evt_start >= afk_start and evt_end <= afk_end:
            return True
    return False

transformed = []
filtered_count = 0
for e in events:
    app = e.get('data', {}).get('app', '')
    if not app:
        continue
    evt_start = parse_ts(e['timestamp'])
    evt_end = evt_start + timedelta(seconds=e['duration'])
    if afk_periods and is_during_afk(evt_start, evt_end):
        filtered_count += 1
        continue
    transformed.append({
        'timestamp': e['timestamp'],
        'duration': e['duration'],
        'app': app,
        'title': e.get('data', {}).get('title', ''),
    })

if filtered_count > 0:
    print(f'🚫 Filtered {filtered_count} AFK events', file=sys.stderr)

print(json.dumps({'device_name': device_name, 'events': transformed}))
" "$EVENTS" "$AFK_EVENTS")

PUSH_COUNT=$(echo "$PAYLOAD" | python3 -c "import sys, json; print(len(json.load(sys.stdin).get('events', [])))" 2>/dev/null || echo 0)

if [[ "$PUSH_COUNT" -eq 0 ]]; then
  echo "😴 All events were AFK — nothing to push"
  echo "$END_TIME" > "$STATE_FILE"
  exit 0
fi

echo "🚀 Pushing ${PUSH_COUNT} events (${EVENT_COUNT} total, $((EVENT_COUNT - PUSH_COUNT)) filtered as AFK)"

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
