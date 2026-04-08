#!/bin/sh
/config/scripts/udm_cache_update.sh | jq -c '(.wan_health_raw // [])[0] // {"status":"unknown","hint":"no wan subsystem in stat/health"}'
