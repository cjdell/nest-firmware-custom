#!/usr/bin/env bash
# Push the vendored Hubitat app/driver source to the hub.
#
# Why this exists: hubitat/apps/*.groovy and hubitat/drivers/*.groovy are the
# single source of truth for what runs on the hub (app id 210, driver id 940).
# Editing code in the hub UI, or re-importing from upstream, silently loses our
# two driver fixes (illegal GString + coolingSetpoint, AGENTS.md trap 18) — so
# edit here and push, never the other way round.
#
#   ./hubitat/push.sh                 # both, to 192.168.1.3
#   ./hubitat/push.sh driver          # just the driver
#   HUB=192.168.1.99 DRIVER_ID=1 ./hubitat/push.sh
#
# Needs curl + jq. /driver/saveOrUpdateJson and /app/saveOrUpdateJson need no
# login and no CSRF token (see README.md).
set -euo pipefail

HUB="${HUB:-192.168.1.3}"
DRIVER_ID="${DRIVER_ID:-940}"
APP_ID="${APP_ID:-210}"
here="$(cd "$(dirname "$0")" && pwd)"

push() { # push <kind: driver|app> <hub id> <file>
  local kind=$1 id=$2 file=$3
  command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
  [ -r "$file" ] || { echo "missing $file" >&2; exit 1; }
  echo "== $kind id $id <- ${file#"$here"/} ($(wc -c <"$file") bytes) -> $HUB"
  jq -Rs --argjson id "$id" '{id: $id, source: ., version: 1}' "$file" |
    curl -fsS -X POST "http://$HUB/$kind/saveOrUpdateJson" \
      -H 'Content-Type: application/json' --data-binary @-
  echo
}

case "${1:-both}" in
  driver) push driver "$DRIVER_ID" "$here/drivers/nolongerevil-thermostat.groovy" ;;
  app)    push app    "$APP_ID"    "$here/apps/nolongerevil-connect.groovy" ;;
  both)
    # Driver first: the app creates children that reference the driver type.
    push driver "$DRIVER_ID" "$here/drivers/nolongerevil-thermostat.groovy"
    push app    "$APP_ID"    "$here/apps/nolongerevil-connect.groovy"
    echo
    echo "Done. googleHomeSupported only recomputes after the device re-polls:"
    echo "  1. press Refresh on the device page (or run setHeatingSetpoint)"
    echo "  2. curl -s http://$HUB/device/fullJson/16 | grep -o googleHomeSupported[^,]*"
    ;;
  *) echo "usage: $0 [driver|app|both]" >&2; exit 2 ;;
esac
