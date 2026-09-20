#!/usr/bin/env bash
# discord-signup-gateway-status.sh — a healthcheck `command` guard that goes DOWN when
# discord-signup-store is running but has no Discord gateway socket.
#
# Why this exists next to the `systemd` check on the unit: from 2026-09-15 to 2026-09-20
# the gateway was down for five days while the unit stayed active and answered every
# request. The process was fine; it just heard nothing from Discord. Since a163fb7 the
# store says so in `GET /healthz` under `gateway.state`, and it answers 200 in every
# state on purpose, so a check that reads only the status code can never see an outage.
# This reads the state.
#
# Only `connected` passes. `connecting` fails too, and that is deliberate: during an
# outage the supervisor cycles down -> connecting -> down, so a check that passed
# `connecting` would clear healthcheck's consecutive-failure count every time a poll
# landed on it, and a dead gateway might never alert. The grace for a restart or a
# routine reconnect comes from the layer above: healthcheck alerts only after
# `alert_threshold` failed polls in a row.
#
# Deliberately NO auto_restart on this check in config.yaml. A Discord outage is not the
# unit's fault, and restarting the unit every few minutes through one would throw away
# the session's RESUME each time.
#
# Contract (healthcheck `type: command`, `expect_output: "ok"`): print a line starting
# "ok" and exit 0 when healthy; print a FAIL line and exit 1 otherwise.
set -euo pipefail

UNIT="discord-signup-store"

# healthcheck runs under the user manager, which sets both of these. The defaults are
# for running this by hand from a shell that has neither.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

# The unit owns the listen address. DISCORD_SIGNUP_GATEWAY_ADDR overrides it so the
# script can be pointed at a stand-in when it is tested.
address="${DISCORD_SIGNUP_GATEWAY_ADDR:-}"
if [ -z "$address" ]; then
  environment="$(systemctl --user show "$UNIT" --property=Environment --value)" \
    || { echo "FAIL: could not read the $UNIT unit"; exit 1; }
  for assignment in $environment; do
    case "$assignment" in
      DISCORD_SIGNUP_ADDR=*) address="${assignment#DISCORD_SIGNUP_ADDR=}" ;;
    esac
  done
fi
if [ -z "$address" ]; then
  echo "FAIL: the $UNIT unit sets no DISCORD_SIGNUP_ADDR, so there is no address to ask"
  exit 1
fi

body="$(curl --silent --show-error --fail --max-time 5 "http://${address}/healthz" 2>&1)" \
  || { echo "FAIL: GET http://${address}/healthz: $body"; exit 1; }

state="$(printf '%s' "$body" | jq --raw-output '.gateway.state // empty' 2>/dev/null)" \
  || { echo "FAIL: /healthz is not JSON: $body"; exit 1; }
if [ -z "$state" ]; then
  echo "FAIL: /healthz carries no gateway.state (a binary older than a163fb7?): $body"
  exit 1
fi

since="$(printf '%s' "$body" | jq --raw-output '.gateway.since // "unknown"')"
if [ "$state" = "connected" ]; then
  opens="$(printf '%s' "$body" | jq --raw-output '.gateway.opens // "unknown"')"
  abandoned_sessions="$(printf '%s' "$body" | jq --raw-output '.gateway.abandoned_sessions // "unknown"')"
  echo "ok: gateway connected since $since ($opens opens, $abandoned_sessions abandoned sessions)"
  exit 0
fi

last_error="$(printf '%s' "$body" | jq --raw-output '.gateway.last_error // "none given"')"
last_connected_at="$(printf '%s' "$body" | jq --raw-output '.gateway.last_connected_at // "unknown"')"
echo "FAIL: gateway is $state since $since (last connected $last_connected_at; last error: $last_error)"
exit 1
