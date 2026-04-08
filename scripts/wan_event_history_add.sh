#!/bin/sh
set -eu

FILE="/config/data/wan_event_history.json"

TS="${1:-}"
WAN="${2:-UNKNOWN}"
WAN_NAME="${3:-UNKNOWN}"
EVENT="${4:-UNKNOWN}"
MESSAGE="${5:-}"

mkdir -p /config/data

if [ ! -f "$FILE" ]; then
  echo '{"events":[]}' > "$FILE"
fi

TMP="$(mktemp)"

jq \
  --arg ts "$TS" \
  --arg wan "$WAN" \
  --arg wan_name "$WAN_NAME" \
  --arg event "$EVENT" \
  --arg message "$MESSAGE" \
  '
  .events = (
    [
      {
        ts: $ts,
        wan: $wan,
        wan_name: $wan_name,
        event: $event,
        message: $message
      }
    ] + (.events // [])
  )[:20]
  ' "$FILE" > "$TMP"

mv "$TMP" "$FILE"