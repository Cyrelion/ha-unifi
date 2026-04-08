# Home Assistant UniFi / Internet Monitoring

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Home Assistant](https://img.shields.io/badge/Home%20Assistant-YAML-41BDF5)
![UniFi](https://img.shields.io/badge/UniFi-Network%20Monitoring-0559C9)
![Maintained](https://img.shields.io/badge/Maintained-Yes-success)

Production-ready Home Assistant packages and helper scripts for monitoring a UniFi gateway with a focus on WAN health, failover visibility, traffic telemetry, VPN status, and webhook-based event ingestion.

## Features

- WAN config and WAN health via UniFi API
- WAN traffic monitoring via SNMP
- internet health and stability scoring
- failover and outage visibility
- VPN and Teleport status visibility
- WAN event history storage
- webhook ingestion from UniFi Alarm Manager
- event-based notification handoff via `unifi_network_monitor_notification`

## Architecture

The package itself does not send push notifications directly.
Instead, it emits the Home Assistant event:

```text
unifi_network_monitor_notification
```

This makes the repo portable.
You can route notifications in your own stack, for example through:

- Home Assistant automations
- mobile app notifications
- Telegram
- Matrix
- mail
- TTS
- JARVIS or any custom event router

A local example bridge is included at:

```text
examples/notifications.local.example.yaml
```

If you already have your own event-driven notification handling, you can ignore that file completely.

## Repository structure

```text
packages/network/
  internet.yaml
  unifi_api.yaml
  unifi_helpers.yaml
  unifi_traffic.yaml
  unifi_vpn_status.yaml
  unifi_webhook.yaml

scripts/
  udm_cache_update.sh
  get_wan_config.sh
  get_wan_health.sh
  get_vpn_status.sh
  wan_event_history_add.sh
  wan_event_history_clear.sh

examples/
  secrets.example.yaml
  notifications.local.example.yaml

secrets/
  udm_api.env.example

LICENSE
README.md
```

## Included packages

### `packages/network/unifi_api.yaml`
Reads WAN config and WAN health from the UniFi API through local helper scripts.

### `packages/network/unifi_traffic.yaml`
Reads WAN traffic counters via SNMP and derives RX and TX rates and totals.

### `packages/network/internet.yaml`
Builds health, failover, routing and stability logic on top of the raw WAN data.

### `packages/network/unifi_vpn_status.yaml`
Provides VPN and Teleport visibility from cached UniFi data.

### `packages/network/unifi_webhook.yaml`
Receives WAN-related webhook events from UniFi Alarm Manager and writes them into Home Assistant helpers, counters, history and a generic event stream.

### `packages/network/unifi_helpers.yaml`
Defines helper entities and shell commands used by the package.

## Requirements

The package assumes:

- Home Assistant with YAML package support
- the `command_line` integration
- the `snmp` integration
- shell access for Home Assistant scripts
- scripts available under `/config/scripts/`
- package files available under `/config/packages/network/`

The helper scripts use these binaries:

- `sh`
- `curl`
- `jq`
- `wget`
- `nslookup`

## Installation

### 1. Copy the repository into your Home Assistant config

Copy these folders into your HA configuration directory:

- `packages/network/` to `/config/packages/network/`
- `scripts/` to `/config/scripts/`

You do not need to copy `examples/` into production.
Those files are only templates.

### 2. Enable packages in `configuration.yaml`

If you do not already use packages, add:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

### 3. Create or extend `secrets.yaml`

Use `examples/secrets.example.yaml` as a template.
At minimum, define these values in `/config/secrets.yaml`:

```yaml
udm_snmp_host: 192.168.1.1
udm_snmp_community: your-snmp-community
internet_dns_internal_check_command: "nslookup homeassistant.io 192.168.1.1 >/dev/null 2>&1 && echo OK || echo FAIL"
udm_alarm_manager_wan_webhook_id: change-me-randomly
udm_alarm_manager_wan_debug_webhook_id: change-me-randomly
```

Notes:

- `udm_snmp_host` is usually your UniFi gateway IP
- `udm_snmp_community` must match the SNMP configuration on the gateway
- `internet_dns_internal_check_command` should query your internal resolver such as AdGuard Home or Pi-hole
- webhook IDs should be random and private

### 4. Create the local UniFi env file

Create this file:

```text
/config/secrets/udm_api.env
```

Use `secrets/udm_api.env.example` as a template:

```bash
UDM_USER='your-udm-username'
UDM_PASS='your-udm-password'
UDM_HOST='192.168.1.1'
UDM_SITE='default'
UDM_SITE_NAME='Default'
UDM_API_KEY='your-optional-integration-api-key'
UDM_TELEPORT_PREFIX='192.168.2.'
```

Notes:

- `UDM_API_KEY` is optional, but useful for certain integration endpoints
- `UDM_SITE` is usually `default`
- `UDM_TELEPORT_PREFIX` is optional and only improves Teleport client detection heuristics

### 5. Make scripts executable

```bash
chmod +x /config/scripts/*.sh
```

### 6. Restart Home Assistant

After copying files and creating secrets, restart Home Assistant.

Then check:

- Developer Tools → YAML → configuration check
- Settings → System → Logs
- the states of `sensor.udm_wan_health_raw`, `sensor.udm_wan_config_raw`, and `sensor.udm_vpn_status_raw`

## UniFi-side setup

### API access

The cache updater logs in against the UniFi gateway and reads WAN, health, VPN and client information.
The configured UniFi account therefore needs enough permissions to access those endpoints.

### SNMP

Enable SNMP on the UniFi gateway and make sure:

- the community string matches `udm_snmp_community`
- the gateway in `udm_snmp_host` is reachable from Home Assistant

### WAN interface indexes

`packages/network/unifi_traffic.yaml` currently assumes these SNMP interface indexes:

- WAN1 uses ifIndex `3`
- WAN2 uses ifIndex `5`

If your hardware uses different indexes, update the OIDs in `packages/network/unifi_traffic.yaml`.

## UniFi Alarm Manager webhook setup

This package expects WAN-related events from **UniFi Network Alarm Manager** and exposes two Home Assistant webhooks:

- production event webhook
- optional debug webhook

Home Assistant webhook URLs follow this pattern:

```text
https://<your-home-assistant-url>/api/webhook/<webhook_id>
```

Example:

```text
https://ha.example.com/api/webhook/4b4d8f0f2b2f4f4da0e8...
```

### Recommended approach

Create at least one UniFi Network alarm for WAN outage and failover-related events and attach a webhook action that points to your Home Assistant URL.

This repo is prepared for both:

- a main webhook for real event ingestion
- an optional debug webhook for payload inspection during setup

### Step-by-step

1. Open **UniFi Network**
2. Go to **Alarm Manager**
3. Click **Create Alarm**
4. Choose a WAN or internet-related trigger such as WAN offline, outage or failover-related events
5. Set the scope if UniFi offers one for that trigger
6. In **Actions**, add a **Webhook** action
7. Paste your Home Assistant webhook URL
8. Prefer **HTTP POST** if available so UniFi includes structured payload data
9. Save the alarm
10. Trigger a test event or use a controlled WAN test and verify the payload arrives in Home Assistant

### Practical setup notes

- Use the main webhook URL with `udm_alarm_manager_wan_webhook_id` for the real production alarm
- Use the debug webhook URL with `udm_alarm_manager_wan_debug_webhook_id` while validating payload structure
- Once your payloads look correct, you can keep the debug alarm disabled or remove it
- If you use a reverse proxy, make sure external webhook requests are forwarded to Home Assistant correctly
- If your Home Assistant instance is not directly reachable, place the webhook behind your existing secure public entry point

### What the package currently parses

The webhook logic in `packages/network/unifi_webhook.yaml` currently looks for values such as:

- event name
- event message
- `UNIFIwanId`
- `UNIFIwanName`
- `UNIFIwanIsp`

From that, it derives:

- WAN1 or WAN2 mapping
- outage versus recovery detection
- helper updates and counters
- `wan_event_history`
- the generic event `unifi_network_monitor_notification`

### Screenshot placeholders

Drop your screenshots in a future `docs/images/` folder and reference them here, for example:

```markdown
![Create Alarm](docs/images/unifi-alarm-manager-create-alarm.png)
![Webhook Action](docs/images/unifi-alarm-manager-webhook-action.png)
![POST Payload](docs/images/unifi-alarm-manager-post-payload.png)
```

Suggested screenshot sequence:

1. Alarm Manager overview
2. Create Alarm dialog
3. Trigger selection for WAN or internet events
4. Action selection with Webhook
5. Webhook URL and POST configuration
6. Resulting event in Home Assistant

## First start checklist

After restart, validate these points:

- `sensor.udm_wan_health_raw` returns data
- `sensor.udm_wan_config_raw` returns WAN config
- `sensor.udm_vpn_status_raw` returns JSON rather than fallback-only output
- SNMP entities such as `sensor.udm_wan1_in_octets` update
- `sensor.internet_health_state` moves out of `unknown`
- `sensor.wan_event_history` exists
- webhook test events update `input_text.udm_last_wan_event`

## Event payload for notifications

The package emits `unifi_network_monitor_notification` with payloads similar to this:

```yaml
title: UDM WAN Event
severity: warning
source: udm_alarm_manager_wan_webhook
message: WAN1 ausgefallen Telekom DSL Provider
push_tag: udm_wan_event
```

## Troubleshooting

### `sensor.udm_wan_health_raw` stays `unknown`

Usually caused by one of these:

- wrong `UDM_HOST`
- wrong login credentials
- missing `jq` or `curl`
- temporary UniFi overload returning empty API data

### VPN status is empty

Check:

- `sensor.udm_vpn_status_raw`
- `/tmp/udm_cache.json`
- `UDM_API_KEY` if integration endpoints are needed
- whether `UDM_TELEPORT_PREFIX` matches your environment

### SNMP sensors do not update

Check:

- SNMP is enabled on the gateway
- the community string is correct
- the host is correct
- the interface indexes match your hardware
- Home Assistant can reach UDP 161 on the gateway

### Webhooks do not arrive

Check:

- the webhook ID matches exactly
- Home Assistant is reachable from the UniFi side
- your reverse proxy forwards webhook requests correctly
- the debug webhook receives test payloads
- the alarm action is configured to use the expected webhook URL

## Publishing checklist

Before making the repository public:

- verify that no real credentials remain in tracked files
- verify that all webhook IDs are examples only
- verify that `secrets/udm_api.env` is not committed
- rotate any accidentally exposed credentials
- add screenshots for the webhook setup section if desired
- tag the first public release

## License

This project is licensed under the **MIT License**.
See [`LICENSE`](LICENSE) for details.
