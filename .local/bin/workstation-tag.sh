#!/bin/bash
# Workstation heartbeat tag for Aurboda
# Sends periodic tags indicating computer usage and display type
# Run via cron every minute

set -euo pipefail

CONFIG_FILE="$HOME/.config/aurboda/config"
DEVICE="$(hostname)"
MERGE_SPAN=180  # Merge tags within 3 minutes

# Load config
if [[ ! -f "$CONFIG_FILE" ]]; then
  exit 0  # Silently exit if not configured
fi
source "$CONFIG_FILE"

# Discover XAUTHORITY from a running Xwayland or Xorg process
# Cron does not inherit XAUTHORITY from the user session, so we find it
# from the process arguments of the X server itself.
find_xauthority() {
  # Look for Xwayland or Xorg process owned by this user and extract -auth argument
  local auth
  auth=$(ps -u "$(id -u)" -o args= 2>/dev/null \
    | grep -E '^\s*(Xwayland|[^ ]*/Xorg|[^ ]*/X) ' \
    | grep -o '\-auth [^ ]*' \
    | head -1 \
    | awk '{print $2}')
  if [[ -n "$auth" && -f "$auth" ]]; then
    echo "$auth"
    return 0
  fi
  # Fallback: any xauth file in the user runtime dir
  local runtime_auth
  runtime_auth=$(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/xauth_* 2>/dev/null | head -1)
  if [[ -n "$runtime_auth" ]]; then
    echo "$runtime_auth"
    return 0
  fi
  # Classic fallback
  [[ -f "$HOME/.Xauthority" ]] && echo "$HOME/.Xauthority" && return 0
  return 1
}

# Find active X display session
find_display() {
  # Try common display values
  for display in ":0" ":1"; do
    if DISPLAY="$display" xrandr --query &>/dev/null; then
      echo "$display"
      return 0
    fi
  done

  # Try from X socket files
  for socket in /tmp/.X11-unix/X*; do
    [[ -e "$socket" ]] || continue
    display=":${socket##*X}"
    if DISPLAY="$display" xrandr --query &>/dev/null; then
      echo "$display"
      return 0
    fi
  done

  return 1
}

# Check if monitor is actually on (not standby/off via DPMS)
is_monitor_on() {
  local display="$1"
  local xset_output
  xset_output=$(DISPLAY="$display" xset q 2>/dev/null) || return 0

  # Wayland doesn't have DPMS - assume on since we have a display session
  if echo "$xset_output" | grep -q "Server does not have the DPMS Extension"; then
    return 0
  fi

  # X11 with DPMS - check if monitor is on
  echo "$xset_output" | grep -q "Monitor is On"
}

# Check for external monitor (non-laptop panel)
has_external_monitor() {
  local display="$1"
  # Look for connected displays that aren't eDP (laptop) or LVDS (older laptops)
  DISPLAY="$display" xrandr --query 2>/dev/null | \
    grep -E "^[A-Z].*\bconnected\b" | \
    grep -qvE "^(eDP|LVDS)"
}

# Main

# Set XAUTHORITY if not already set (needed when running from cron)
if [[ -z "${XAUTHORITY:-}" ]]; then
  XAUTHORITY=$(find_xauthority) || true
  export XAUTHORITY
fi

DISPLAY=$(find_display) || exit 0  # No display session, skip

# Only proceed if monitor is actually on
is_monitor_on "$DISPLAY" || exit 0

if has_external_monitor "$DISPLAY"; then
  display_type="external-monitor"
else
  display_type="laptop-only"
fi

tag="computer:${DEVICE}:${display_type}"
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Send tag to Aurboda API
curl -sf -X POST "${AURBODA_BASE_URL}/api/tags" \
  -H "Authorization: Bearer ${AURBODA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"tag\": \"${tag}\", \"start_time\": \"${timestamp}\", \"merge_span\": ${MERGE_SPAN}}" \
  >/dev/null 2>&1 || true  # Don't fail on API errors
