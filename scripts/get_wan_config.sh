#!/bin/sh
/config/scripts/udm_cache_update.sh | jq -c '{data: (.wan_config // [])}'
