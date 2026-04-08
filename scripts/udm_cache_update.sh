#!/bin/sh
set -eu

CREDS="/config/secrets/udm_api.env"

CACHE="/tmp/udm_cache.json"
TMP="/tmp/udm_cache_tmp.json"

COOKIE="/tmp/udm_cookie_jarvis.txt"
LOCKDIR="/tmp/udm_cache.lockdir"

# Tuning
CACHE_MIN_REFRESH_SECONDS=25
COOKIE_TTL_SECONDS=900
LOGIN_BACKOFF_SECONDS=900
BACKOFF_FILE="/tmp/udm_login_backoff.ts"

WANCONF_BODY_FILE="/tmp/udm_wanconf_body.txt"
HEALTH_BODY_FILE="/tmp/udm_health_body.txt"
VPN_BODY_FILE="/tmp/udm_vpn_body.txt"
CLIENTS_BODY_FILE="/tmp/udm_clients_body.txt"
SITES_INTEGRATION_BODY_FILE="/tmp/udm_sites_integration_body.txt"
CLIENTS_INTEGRATION_BODY_FILE="/tmp/udm_clients_integration_body.txt"

WAN_CONFIG_FILE="/tmp/udm_wan_config.json"
WAN_HEALTH_RAW_FILE="/tmp/udm_wan_health_raw.json"
VPN_RAW_FILE="/tmp/udm_vpn_raw.json"
VPN_HEALTH_RAW_FILE="/tmp/udm_vpn_health_raw.json"
VPN_SUMMARY_FILE="/tmp/udm_vpn_summary.json"
CLIENTS_RAW_FILE="/tmp/udm_clients_raw.json"
CLIENTS_INTEGRATION_RAW_FILE="/tmp/udm_clients_integration_raw.json"

if [ ! -f "$CREDS" ]; then
  echo "{\"error\":\"missing_creds\",\"hint\":\"Create $CREDS with UDM_USER, UDM_PASS, optional UDM_HOST, UDM_SITE, UDM_SITE_NAME and UDM_API_KEY\"}"
  exit 0
fi

# shellcheck disable=SC1090
. "$CREDS"

UDM_HOST="${UDM_HOST:-}"
UDM_SITE="${UDM_SITE:-default}"
UDM_SITE_NAME="${UDM_SITE_NAME:-Default}"
UDM_API_KEY="${UDM_API_KEY:-}"
UDM_TELEPORT_PREFIX="${UDM_TELEPORT_PREFIX:-192.168.2.}"

if [ -z "$UDM_HOST" ]; then
  echo "{\"error\":\"missing_udm_host\",\"hint\":\"Set UDM_HOST in $CREDS\"}"
  exit 0
fi

now_ts() { date +%s; }

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || echo 0
}

file_age() {
  f="$1"
  if [ ! -f "$f" ]; then
    echo 999999
    return
  fi
  now="$(now_ts)"
  mt="$(file_mtime "$f")"
  echo $(( now - mt ))
}

cache_is_fresh() {
  [ -f "$CACHE" ] || return 1
  age="$(file_age "$CACHE")"
  [ "$age" -lt "$CACHE_MIN_REFRESH_SECONDS" ]
}

cookie_is_fresh() {
  [ -f "$COOKIE" ] || return 1
  age="$(file_age "$COOKIE")"
  [ "$age" -lt "$COOKIE_TTL_SECONDS" ]
}

in_login_backoff() {
  [ -f "$BACKOFF_FILE" ] || return 1
  age="$(file_age "$BACKOFF_FILE")"
  [ "$age" -lt "$LOGIN_BACKOFF_SECONDS" ]
}

write_json_file() {
  file="$1"
  content="$2"
  printf '%s' "$content" > "$file"
}

login() {
  curl -sk -m 10 \
    -X POST "https://${UDM_HOST}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${UDM_USER}\",\"password\":\"${UDM_PASS}\"}" \
    -c "$COOKIE" \
    -o /tmp/udm_login_body.txt \
    -w "%{http_code}"
}

api_get() {
  path="$1"
  body_file="$2"
  curl -sk -m 10 -b "$COOKIE" "https://${UDM_HOST}${path}" -o "$body_file" -w "%{http_code}"
}

integration_api_get() {
  path="$1"
  body_file="$2"

  if [ -z "$UDM_API_KEY" ]; then
    write_json_file "$body_file" '{}'
    echo 000
    return 0
  fi

  curl -sk -m 20 \
    -H "Accept: application/json" \
    -H "X-API-KEY: ${UDM_API_KEY}" \
    "https://${UDM_HOST}${path}" \
    -o "$body_file" \
    -w "%{http_code}" || echo 000
}

extract_integration_site_id() {
  file="$1"

  jq -r \
    --arg wanted "$UDM_SITE" \
    --arg wanted_name "$UDM_SITE_NAME" '
    def rows:
      if .data? != null then .data
      elif .items? != null then .items
      elif type == "array" then .
      else []
      end;

    (
      rows
      | map(select(
          (.id // "" | tostring) == $wanted
          or (.name // "" | tostring) == $wanted
          or (.name // "" | tostring) == $wanted_name
          or (.internalReference // "" | tostring) == $wanted
          or (.siteId // "" | tostring) == $wanted
          or (.slug // "" | tostring) == $wanted
        ))
      | .[0].id
    ) // (rows | .[0].id) // empty
  ' "$file" 2>/dev/null || true
}

mark_stale_and_exit() {
  http="$1"
  err="$2"
  if [ -f "$CACHE" ]; then
    jq -c --arg http "$http" --arg err "$err" '
      .meta.stale=true
      | .meta.login_http=$http
      | .meta.login_error=$err
      | .vpn_raw = (.vpn_raw // [])
      | .vpn_health_raw = (.vpn_health_raw // [])
      | .vpn_summary = (.vpn_summary // {active_count:0,total_count:0,enabled:null,site_to_site_enabled:null,rx_bytes:0,tx_bytes:0,source:"none",endpoint_available:false})
      | .clients_raw = (.clients_raw // [])
      | .clients_integration_raw = (.clients_integration_raw // [])
    ' "$CACHE"
  else
    jq -cn --arg host "$UDM_HOST" --arg site "$UDM_SITE" --arg http "$http" --arg err "$err" '
      {
        meta: {
          host:$host,
          site:$site,
          ts:(now|floor),
          stale:true,
          login_http:$http,
          login_error:$err
        },
        wan_config: [],
        wan_health_raw: [],
        vpn_raw: [],
        vpn_health_raw: [],
        vpn_summary: {
          active_count:0,
          total_count:0,
          enabled:null,
          site_to_site_enabled:null,
          rx_bytes:0,
          tx_bytes:0,
          source:"none",
          endpoint_available:false
        },
        clients_raw: [],
        clients_integration_raw: []
      }
    '
  fi
  exit 0
}

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -f "$CACHE" ]; then
    cat "$CACHE"
  else
    echo "{\"error\":\"lock_busy\",\"hint\":\"cache not ready yet\"}"
  fi
  exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

if cache_is_fresh; then
  cat "$CACHE"
  exit 0
fi

if ! cookie_is_fresh; then
  if in_login_backoff; then
    mark_stale_and_exit "429" "login_backoff_active"
  fi

  HTTP="$(login || echo 000)"
  if [ "$HTTP" = "429" ]; then
    now_ts > "$BACKOFF_FILE" 2>/dev/null || true
    BODY="$(cat /tmp/udm_login_body.txt 2>/dev/null || true)"
    mark_stale_and_exit "$HTTP" "$BODY"
  fi

  if [ "$HTTP" != "200" ]; then
    BODY="$(cat /tmp/udm_login_body.txt 2>/dev/null || true)"
    mark_stale_and_exit "$HTTP" "$BODY"
  fi
fi

WANCONF_PATH="/proxy/network/api/s/${UDM_SITE}/rest/networkconf"
HEALTH_PATH="/proxy/network/api/s/${UDM_SITE}/stat/health"
VPN_PATH="/proxy/network/api/s/${UDM_SITE}/stat/remoteuservpn"
CLIENTS_PATH="/proxy/network/api/s/${UDM_SITE}/stat/sta"

set +e
WANCONF_HTTP="$(api_get "$WANCONF_PATH" "$WANCONF_BODY_FILE" || echo 000)"
HEALTH_HTTP="$(api_get "$HEALTH_PATH" "$HEALTH_BODY_FILE" || echo 000)"
VPN_HTTP="$(api_get "$VPN_PATH" "$VPN_BODY_FILE" || echo 000)"
CLIENTS_HTTP="$(api_get "$CLIENTS_PATH" "$CLIENTS_BODY_FILE" || echo 000)"
set -e

if [ "$WANCONF_HTTP" = "401" ] || \
   [ "$HEALTH_HTTP" = "401" ] || \
   [ "$VPN_HTTP" = "401" ] || \
   [ "$CLIENTS_HTTP" = "401" ]; then

  if ! in_login_backoff; then
    HTTP="$(login || echo 000)"
    if [ "$HTTP" = "429" ]; then
      now_ts > "$BACKOFF_FILE" 2>/dev/null || true
      BODY="$(cat /tmp/udm_login_body.txt 2>/dev/null || true)"
      mark_stale_and_exit "$HTTP" "$BODY"
    fi
  fi

  set +e
  WANCONF_HTTP="$(api_get "$WANCONF_PATH" "$WANCONF_BODY_FILE" || echo 000)"
  HEALTH_HTTP="$(api_get "$HEALTH_PATH" "$HEALTH_BODY_FILE" || echo 000)"
  VPN_HTTP="$(api_get "$VPN_PATH" "$VPN_BODY_FILE" || echo 000)"
  CLIENTS_HTTP="$(api_get "$CLIENTS_PATH" "$CLIENTS_BODY_FILE" || echo 000)"
  set -e
fi

INTEGRATION_SITES_HTTP="000"
INTEGRATION_CLIENTS_HTTP="000"
INTEGRATION_SITE_ID=""

write_json_file "$SITES_INTEGRATION_BODY_FILE" '{}'
write_json_file "$CLIENTS_INTEGRATION_BODY_FILE" '{}'

if [ -n "$UDM_API_KEY" ]; then
  INTEGRATION_SITES_HTTP="$(integration_api_get "/proxy/network/integration/v1/sites" "$SITES_INTEGRATION_BODY_FILE")"

  if [ "$INTEGRATION_SITES_HTTP" = "200" ]; then
    INTEGRATION_SITE_ID="$(extract_integration_site_id "$SITES_INTEGRATION_BODY_FILE")"
  fi

  if [ -n "$INTEGRATION_SITE_ID" ]; then
    INTEGRATION_CLIENTS_HTTP="$(integration_api_get "/proxy/network/integration/v1/sites/${INTEGRATION_SITE_ID}/clients?offset=0&limit=1000" "$CLIENTS_INTEGRATION_BODY_FILE")"
  fi
fi

if [ "$WANCONF_HTTP" = "200" ]; then
  jq -c '(.data // []) | map(select(.purpose == "wan"))' "$WANCONF_BODY_FILE" > "$WAN_CONFIG_FILE" 2>/dev/null || write_json_file "$WAN_CONFIG_FILE" '[]'
else
  write_json_file "$WAN_CONFIG_FILE" '[]'
fi

if [ "$HEALTH_HTTP" = "200" ]; then
  jq -c '(.data // []) | map(select(.subsystem == "wan"))' "$HEALTH_BODY_FILE" > "$WAN_HEALTH_RAW_FILE" 2>/dev/null || write_json_file "$WAN_HEALTH_RAW_FILE" '[]'
  jq -c '(.data // []) | map(select(.subsystem == "vpn"))' "$HEALTH_BODY_FILE" > "$VPN_HEALTH_RAW_FILE" 2>/dev/null || write_json_file "$VPN_HEALTH_RAW_FILE" '[]'
else
  write_json_file "$WAN_HEALTH_RAW_FILE" '[]'
  write_json_file "$VPN_HEALTH_RAW_FILE" '[]'
fi

if [ "$VPN_HTTP" = "200" ]; then
  jq -c '(.data // [])' "$VPN_BODY_FILE" > "$VPN_RAW_FILE" 2>/dev/null || write_json_file "$VPN_RAW_FILE" '[]'
else
  write_json_file "$VPN_RAW_FILE" '[]'
fi

if [ "$CLIENTS_HTTP" = "200" ]; then
  jq -c '
    if type == "array" then .
    elif (.data? | type) == "array" then .data
    elif (.items? | type) == "array" then .items
    else []
    end
  ' "$CLIENTS_BODY_FILE" > "$CLIENTS_RAW_FILE" 2>/dev/null || write_json_file "$CLIENTS_RAW_FILE" '[]'
else
  write_json_file "$CLIENTS_RAW_FILE" '[]'
fi

if [ "$INTEGRATION_CLIENTS_HTTP" = "200" ]; then
  jq -c '
    if type == "array" then .
    elif (.data? | type) == "array" then .data
    elif (.items? | type) == "array" then .items
    else []
    end
  ' "$CLIENTS_INTEGRATION_BODY_FILE" > "$CLIENTS_INTEGRATION_RAW_FILE" 2>/dev/null || write_json_file "$CLIENTS_INTEGRATION_RAW_FILE" '[]'
else
  write_json_file "$CLIENTS_INTEGRATION_RAW_FILE" '[]'
fi

jq -cn \
  --arg vpn_http "$VPN_HTTP" \
  --slurpfile vpn_raw_file "$VPN_RAW_FILE" \
  --slurpfile vpn_health_raw_file "$VPN_HEALTH_RAW_FILE" '
    def is_truthy:
      (tostring | ascii_downcase) as $v
      | (["1","true","yes","connected","online","up"] | index($v)) != null;

    def norm_state($row):
      if $row.state != null and ($row.state | tostring) != "" then
        ($row.state | tostring | ascii_upcase)
      elif $row.status != null and ($row.status | tostring) != "" then
        ($row.status | tostring | ascii_upcase)
      elif $row.connected != null then
        (if ($row.connected | is_truthy) then "CONNECTED" else "DISCONNECTED" end)
      elif $row.is_connected != null then
        (if ($row.is_connected | is_truthy) then "CONNECTED" else "DISCONNECTED" end)
      else
        "UNKNOWN"
      end;

    ($vpn_raw_file[0] // []) as $vpn_raw
    | ($vpn_health_raw_file[0] // []) as $vpn_health_raw
    | ($vpn_health_raw[0] // {}) as $vh
    | {
        active_count:
          (if ($vpn_raw | length) > 0
           then ($vpn_raw | map(select(norm_state(.) == "CONNECTED")) | length)
           else ($vh.remote_user_num_active // 0)
           end),
        total_count:
          (if ($vpn_raw | length) > 0
           then ($vpn_raw | length)
           else (($vh.remote_user_num_active // 0) + ($vh.remote_user_num_inactive // 0))
           end),
        enabled: ($vh.remote_user_enabled // null),
        site_to_site_enabled: ($vh.site_to_site_enabled // null),
        rx_bytes: ($vh.remote_user_rx_bytes // 0),
        tx_bytes: ($vh.remote_user_tx_bytes // 0),
        source:
          (if $vpn_http == "200" then "stat/remoteuservpn"
           elif ($vh | length) > 0 then "stat/health.vpn"
           else "none"
           end),
        endpoint_available: ($vpn_http == "200")
      }
  ' > "$VPN_SUMMARY_FILE" 2>/dev/null || write_json_file "$VPN_SUMMARY_FILE" '{"active_count":0,"total_count":0,"enabled":null,"site_to_site_enabled":null,"rx_bytes":0,"tx_bytes":0,"source":"none","endpoint_available":false}'

NOW="$(now_ts)"

jq -cn \
  --arg host "$UDM_HOST" \
  --arg site "$UDM_SITE" \
  --arg site_name "$UDM_SITE_NAME" \
  --arg integration_site_id "$INTEGRATION_SITE_ID" \
  --argjson ts "$NOW" \
  --arg wanconf_http "$WANCONF_HTTP" \
  --arg health_http "$HEALTH_HTTP" \
  --arg vpn_http "$VPN_HTTP" \
  --arg clients_http "$CLIENTS_HTTP" \
  --arg integration_sites_http "$INTEGRATION_SITES_HTTP" \
  --arg integration_clients_http "$INTEGRATION_CLIENTS_HTTP" \
  --slurpfile wan_config_file "$WAN_CONFIG_FILE" \
  --slurpfile wan_health_raw_file "$WAN_HEALTH_RAW_FILE" \
  --slurpfile vpn_raw_file "$VPN_RAW_FILE" \
  --slurpfile vpn_health_raw_file "$VPN_HEALTH_RAW_FILE" \
  --slurpfile vpn_summary_file "$VPN_SUMMARY_FILE" \
  --slurpfile clients_raw_file "$CLIENTS_RAW_FILE" \
  --slurpfile clients_integration_raw_file "$CLIENTS_INTEGRATION_RAW_FILE" \
  '
    ($wan_config_file[0] // []) as $wan_config
    | ($wan_health_raw_file[0] // []) as $wan_health_raw
    | ($vpn_raw_file[0] // []) as $vpn_raw
    | ($vpn_health_raw_file[0] // []) as $vpn_health_raw
    | ($vpn_summary_file[0] // {
        active_count:0,
        total_count:0,
        enabled:null,
        site_to_site_enabled:null,
        rx_bytes:0,
        tx_bytes:0,
        source:"none",
        endpoint_available:false
      }) as $vpn_summary
    | ($clients_raw_file[0] // []) as $clients_raw
    | ($clients_integration_raw_file[0] // []) as $clients_integration_raw
    | {
        meta: {
          host:$host,
          site:$site,
          site_name:$site_name,
          integration_site_id:$integration_site_id,
          ts:$ts,
          stale:false,
          wanconf_http:$wanconf_http,
          health_http:$health_http,
          vpn_http:$vpn_http,
          clients_http:$clients_http,
          integration_sites_http:$integration_sites_http,
          integration_clients_http:$integration_clients_http
        },
        wan_config:$wan_config,
        wan_health_raw:$wan_health_raw,
        vpn_raw:$vpn_raw,
        vpn_health_raw:$vpn_health_raw,
        vpn_summary:$vpn_summary,
        clients_raw:$clients_raw,
        clients_integration_raw:$clients_integration_raw
      }
  ' > "$TMP"

mv "$TMP" "$CACHE"
cat "$CACHE"