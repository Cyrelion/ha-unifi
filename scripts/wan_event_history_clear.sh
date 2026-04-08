#!/bin/sh
set -eu

FILE="/config/data/wan_event_history.json"
mkdir -p /config/data
echo '{"events":[]}' > "$FILE"