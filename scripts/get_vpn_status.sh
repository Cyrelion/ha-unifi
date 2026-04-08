#!/bin/sh
set -eu

CACHE="/tmp/udm_cache.json"
UPDATER="/config/scripts/udm_cache_update.sh"
CREDS="/config/secrets/udm_api.env"
UDM_TELEPORT_PREFIX="192.168.2."

if [ -f "$CREDS" ]; then
  # shellcheck disable=SC1090
  . "$CREDS"
fi

UDM_TELEPORT_PREFIX="${UDM_TELEPORT_PREFIX:-192.168.2.}"

fallback() {
  jq -cn '
    {
      summary: {
        active_count: 0,
        total_count: 0,
        enabled: null,
        site_to_site_enabled: null,
        rx_bytes: 0,
        tx_bytes: 0,
        source: "none",
        endpoint_available: false,
        raw_count: 0,
        remote_user_count: 0,
        teleport_count: 0,
        clients_endpoint_available: false,
        integration_clients_endpoint_available: false,
        connected_users: ""
      },
      data: [],
      raw: [],
      raw_remote: [],
      raw_teleport_candidates: [],
      raw_teleport_candidates_integration: [],
      raw_teleport_candidates_legacy: [],
      meta: {
        host: null,
        site: null,
        ts: null,
        stale: true,
        vpn_http: null,
        health_http: null,
        clients_http: null,
        integration_clients_http: null
      }
    }
  '
}

run_updater() {
  if [ -x "$UPDATER" ]; then
    "$UPDATER" >/dev/null 2>&1 || true
  elif [ -f "$UPDATER" ]; then
    sh "$UPDATER" >/dev/null 2>&1 || true
  fi
}

run_updater

if [ ! -f "$CACHE" ]; then
  fallback
  exit 0
fi

jq -c --arg teleport_prefix "$UDM_TELEPORT_PREFIX" '
  def truthy:
    if . == true then true
    elif . == false or . == null then false
    else
      (tostring | ascii_downcase) as $v
      | (["1","true","yes","connected","online","up","active"] | index($v)) != null
    end;

  def falsy:
    if . == false then true
    elif . == true or . == null then false
    else
      (tostring | ascii_downcase) as $v
      | (["0","false","no","disconnected","offline","down","inactive"] | index($v)) != null
    end;

  def pick_ip($row):
    (
      $row.ip
      // $row.ipAddress
      // $row.last_ip
      // $row.remote_ip
      // $row.remoteIp
      // $row.client_ip
      // $row.clientIp
      // $row.virtual_ip
      // $row.virtualIp
      // null
    );

  def pick_mac($row):
    (
      $row.mac
      // $row.macAddress
      // null
    );

  def pick_hostname($row):
    (
      $row.hostname
      // $row.host
      // null
    );

  def pick_user($row):
    (
      $row.username
      // $row.user
      // $row.display_name
      // $row.displayName
      // $row.name
      // pick_hostname($row)
      // pick_ip($row)
      // "unknown"
    );

  def norm_state($row):
    if (($row.state // "") | tostring) != "" then
      (($row.state | tostring) | ascii_upcase)
    elif (($row.status // "") | tostring) != "" then
      (($row.status | tostring) | ascii_upcase)
    elif $row.connected != null then
      (if ($row.connected | truthy) then "CONNECTED" else "DISCONNECTED" end)
    elif $row.is_connected != null then
      (if ($row.is_connected | truthy) then "CONNECTED" else "DISCONNECTED" end)
    elif $row.connectedAt != null or $row.connected_at != null then
      "CONNECTED"
    else
      "UNKNOWN"
    end;

  def is_explicitly_disconnected($row):
    (
      (($row.state // $row.status // "") | tostring | ascii_downcase)
      as $s
      | (["disconnected","offline","down","inactive","idle"] | index($s)) != null
    )
    or ($row.connected != null and ($row.connected | falsy))
    or ($row.is_connected != null and ($row.is_connected | falsy));

  def is_remote_active($row):
    if is_explicitly_disconnected($row) then
      false
    elif norm_state($row) == "CONNECTED" then
      true
    else
      true
    end;

  def is_teleport($row):
    (
      (($row.type // $row.vpnType // $row.vpn_type // $row.connectionType // $row.connection_type // "") | tostring | ascii_upcase) == "TELEPORT"
    )
    or
    (
      ((pick_ip($row) // "") | tostring | startswith($teleport_prefix))
      and ((pick_mac($row) // "") == "")
    );

  def normalize_remote($row):
    {
      id: ($row.id // $row._id // null),
      user: pick_user($row),
      name: pick_user($row),
      display_name: pick_user($row),
      hostname: pick_hostname($row),
      username: ($row.username // $row.user // null),
      ip: pick_ip($row),
      mac: pick_mac($row),
      type: (
        ($row.type // $row.connectionType // $row.connection_type // $row.vpnType // $row.vpn_type // "L2TP")
        | tostring
        | ascii_upcase
      ),
      connection_type: (
        $row.connection_type
        // $row.connectionType
        // $row.vpn_type
        // $row.vpnType
        // $row.protocol
        // "L2TP"
      ),
      vpn_type: (
        $row.vpn_type
        // $row.vpnType
        // $row.protocol
        // "L2TP"
      ),
      state: (
        if norm_state($row) == "UNKNOWN" then "CONNECTED" else norm_state($row) end
      ),
      status: (
        if norm_state($row) == "UNKNOWN" then "CONNECTED" else norm_state($row) end
      ),
      connected_at: ($row.connectedAt // $row.connected_at // null),
      source: "vpn_raw",
      label: (
        (pick_user($row)) as $u
        | ((($row.type // $row.connectionType // $row.connection_type // $row.vpnType // $row.vpn_type // "L2TP") | tostring | ascii_upcase)) as $t
        | (pick_ip($row) // "no-ip") as $ip
        | "\($u) [\($t)] • \($ip)"
      )
    };

  def normalize_teleport($row):
    {
      id: ($row.id // null),
      user: pick_user($row),
      name: pick_user($row),
      display_name: pick_user($row),
      hostname: pick_hostname($row),
      username: null,
      ip: pick_ip($row),
      mac: pick_mac($row),
      type: "TELEPORT",
      connection_type: "TELEPORT",
      vpn_type: "TELEPORT",
      state: "CONNECTED",
      status: "CONNECTED",
      connected_at: ($row.connectedAt // $row.connected_at // null),
      source: "clients_integration_raw",
      label: (
        (pick_user($row)) as $u
        | (pick_ip($row) // "no-ip") as $ip
        | "\($u) [TELEPORT] • \($ip)"
      )
    };

  def normalize_placeholder($n):
    {
      id: null,
      user: ("L2TP client " + ($n | tostring)),
      name: ("L2TP client " + ($n | tostring)),
      display_name: ("L2TP client " + ($n | tostring)),
      hostname: null,
      username: null,
      ip: null,
      mac: null,
      type: "L2TP",
      connection_type: "L2TP",
      vpn_type: "L2TP",
      state: "CONNECTED",
      status: "CONNECTED",
      connected_at: null,
      source: "vpn_summary_fallback",
      label: ("L2TP client " + ($n | tostring) + " [L2TP]")
    };

  . as $root
  | ($root.vpn_raw // []) as $vpn_raw
  | ($root.clients_integration_raw // []) as $clients_integration_raw
  | ($root.vpn_summary // {}) as $cached_summary

  | [ $vpn_raw[]? | select(is_remote_active(.)) | normalize_remote(.) ] as $remote_users
  | [ $clients_integration_raw[]? | select(is_teleport(.)) | normalize_teleport(.) ] as $teleport_users

  | (
      ($cached_summary.active_count // 0)
      | if . < ($vpn_raw | length) then ($vpn_raw | length) else . end
    ) as $reported_remote_active

  | ([0, ($reported_remote_active - ($remote_users | length))] | max) as $missing_remote_count
  | [range(1; $missing_remote_count + 1) | normalize_placeholder(.)] as $remote_placeholders

  | (
      ($remote_users + $remote_placeholders + $teleport_users)
      | sort_by(.type, .name, .ip, .source)
      | group_by((.type | tostring) + "|" + (.ip | tostring) + "|" + (.name | tostring) + "|" + (.source | tostring))
      | map(first)
    ) as $data

  | {
      summary: {
        active_count: ($data | length),
        total_count: (
          (
            if ($cached_summary.total_count // 0) > 0 then
              ($cached_summary.total_count // 0)
            else
              $reported_remote_active
            end
          ) + ($teleport_users | length)
        ),
        enabled: ($cached_summary.enabled // null),
        site_to_site_enabled: ($cached_summary.site_to_site_enabled // null),
        rx_bytes: ($cached_summary.rx_bytes // 0),
        tx_bytes: ($cached_summary.tx_bytes // 0),
        source: (
          if (($remote_users | length) + ($remote_placeholders | length)) > 0 and ($teleport_users | length) > 0 then
            "stat/remoteuservpn+integration/clients"
          elif ($teleport_users | length) > 0 then
            "integration/clients"
          elif (($remote_users | length) + ($remote_placeholders | length)) > 0 then
            ($cached_summary.source // "stat/remoteuservpn")
          else
            ($cached_summary.source // "none")
          end
        ),
        endpoint_available: (($root.meta.vpn_http // "") == "200"),
        raw_count: ($vpn_raw | length),
        remote_user_count: (($remote_users | length) + ($remote_placeholders | length)),
        teleport_count: ($teleport_users | length),
        clients_endpoint_available: (
          (($root.meta.integration_clients_http // "") == "200")
          or (($root.meta.clients_http // "") == "200")
        ),
        integration_clients_endpoint_available: (($root.meta.integration_clients_http // "") == "200"),
        connected_users: ($data | map(.label) | join(", "))
      },
      data: $data,
      raw: $data,
      raw_remote: ($remote_users + $remote_placeholders),
      raw_teleport_candidates: $teleport_users,
      raw_teleport_candidates_integration: $teleport_users,
      raw_teleport_candidates_legacy: [],
      meta: {
        host: ($root.meta.host // null),
        site: ($root.meta.site // null),
        ts: ($root.meta.ts // null),
        stale: ($root.meta.stale // null),
        vpn_http: ($root.meta.vpn_http // null),
        health_http: ($root.meta.health_http // null),
        clients_http: ($root.meta.clients_http // null),
        integration_clients_http: ($root.meta.integration_clients_http // null)
      }
    }
' "$CACHE" 2>/dev/null || fallback