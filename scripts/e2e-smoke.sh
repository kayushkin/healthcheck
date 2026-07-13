#!/usr/bin/env bash
# Boot-and-answer smoke test for healthcheck itself.
#
# Builds healthcheck from THIS source tree, boots it on a temp port against a
# throwaway config, and drives its real routes. Proves the committed HEAD
# produces a binary that runs — which `go build` alone cannot: Go 1.22+
# ServeMux panics on a conflicting route pattern at REGISTRATION time, so a
# route collision compiles clean and dies at boot.
#
# Run nightly by the guard this very repo owns (scripts/repo-build-audit.sh
# --smoke), from a clean clone of HEAD.
#
# WHY THE THROWAWAY CONFIG IS THE WHOLE SAFETY STORY
# --------------------------------------------------
# healthcheck's day job is to restart failing systemd units. Booting it against
# the real config.yaml would point a second, unsupervised checker at 30 live
# units with auto_restart armed. The smoke therefore writes its own config
# containing ONLY self-contained checks: no systemd, no auto_restart, no NATS,
# nothing that can reach a real service.
#
# And deliberately NO systemd check, even a harmless one: `systemctl --user`
# needs XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS, which the scheduler's unit
# does not set, so such a check would pass by hand and behave differently at
# 03:00. A guard that is red only at night is a guard people learn to ignore.
#
# Tunables:
#   E2E_PORT   — listen port (default 19105)
#   E2E_KEEP   — set to "1" to leave $TMP_DIR around after the run

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${E2E_PORT:-19105}"
BASE="http://127.0.0.1:$PORT"

for bin in go curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: required tool '$bin' not found on PATH" >&2; exit 2; }
done

# Refuse to run against a port something else already holds: every assertion
# below would then be interrogating that other process, and a smoke that passes
# by testing the wrong server is worse than one that fails.
if curl -fsS -o /dev/null --max-time 2 "$BASE/api/health" 2>/dev/null; then
  echo "ERROR: something is already serving on $BASE — set E2E_PORT" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d -t healthcheck-e2e.XXXXXX)"
SERVER_PID=""
cleanup() {
  local rc=$?
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Dump the log on ANY non-zero exit, including the ones `set -e` takes on its
  # own (a failing `curl -fsS` inside a $(...) aborts before reaching fail()).
  if [ "$rc" -ne 0 ] && [ -f "$TMP_DIR/server.log" ]; then
    echo "----- server.log -----" >&2
    cat "$TMP_DIR/server.log" >&2
  fi
  if [ "${E2E_KEEP:-}" = "1" ]; then echo "[e2e] keeping $TMP_DIR"; else rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT INT TERM

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "build healthcheck from $REPO_DIR"
cd "$REPO_DIR"
go build -o "$TMP_DIR/healthcheck" .
echo "    binary: $(ls -lh "$TMP_DIR/healthcheck" | awk '{print $5}')"

step "write a throwaway config (no systemd, no auto_restart, no NATS)"
# alert_threshold: 2 so the degraded -> down ramp is observable inside a smoke
# run. Nothing can be recovered from either way: auto-restart only fires for a
# `systemd` check with auto_restart set, and recovery only for a check with a
# recovery_command. This config has neither, by construction.
cat >"$TMP_DIR/config.yaml" <<EOF
check_interval: 1s
alert_threshold: 2
listen_addr: "127.0.0.1:$PORT"
log_file: "$TMP_DIR/alerts.log"
nats_url: ""
llm_bridge_url: "http://127.0.0.1:1"

services:
  - name: e2e-command-ok
    type: command
    command: ["/bin/sh", "-c", "echo ok"]
    expect_output: "ok"

  - name: e2e-command-broken
    type: command
    command: ["/bin/sh", "-c", "echo it-is-broken >&2; exit 1"]

  - name: e2e-command-wrong-output
    type: command
    command: ["/bin/sh", "-c", "echo something-else"]
    expect_output: "ok"

  - name: e2e-http-self
    type: http
    url: "$BASE/api/health"
    timeout: 5s

  - name: e2e-http-dead
    type: http
    url: "http://127.0.0.1:1/health"
    timeout: 2s

resources:
  - name: e2e-disk
    type: disk
    path: "$TMP_DIR"
    threshold: 99.9
EOF

step "launch healthcheck on $BASE"
"$TMP_DIR/healthcheck" -config "$TMP_DIR/config.yaml" >"$TMP_DIR/server.log" 2>&1 &
SERVER_PID=$!
echo "    pid: $SERVER_PID"

# Poll for readiness — never sleep-and-hope. Abort the instant the process dies,
# which is how a route-registration panic surfaces as a clear failure instead of
# a 10-second timeout with no explanation.
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null --max-time 2 "$BASE/api/health" 2>/dev/null && break
  kill -0 "$SERVER_PID" 2>/dev/null || fail "healthcheck exited during startup (route-registration panic? port in use?)"
  sleep 0.25
done
curl -fsS -o /dev/null --max-time 2 "$BASE/api/health" || fail "healthcheck did not answer on $BASE within 15s"

step "GET /api/health"
[ "$(curl -fsS --max-time 5 "$BASE/api/health" | jq -r '.status')" = "ok" ] \
  || fail "/api/health did not report status=ok"
echo "    status=ok"

step "GET /api/status — wait for the failing checks to ramp past alert_threshold"
# check_interval is 1s and alert_threshold is 2, so a broken check reaches `down`
# within ~2 cycles. Poll for that end state rather than sleeping and hoping; the
# poll is what makes this robust on a loaded box instead of timing-dependent.
STATUS_JSON=""
for _ in $(seq 1 60); do
  STATUS_JSON=$(curl -fsS --max-time 5 "$BASE/api/status")
  ramped=$(jq '[.services[] | select(.name=="e2e-command-broken" and .status=="down")] | length' <<<"$STATUS_JSON")
  [ "$ramped" = "1" ] && break
  sleep 0.25
done
[ "$(jq '.services | length' <<<"$STATUS_JSON")" = "5" ] \
  || fail "/api/status did not report all 5 configured services: $(jq -c '[.services[].name]' <<<"$STATUS_JSON")"

want() {  # want <service> <status>
  local got
  got=$(jq -r --arg n "$1" '.services[] | select(.name==$n) | .status' <<<"$STATUS_JSON")
  [ "$got" = "$2" ] || fail "service $1: status is '$got', want '$2'"
  echo "    $1 -> $got"
}

# A passing check and a failing one must be distinguishable. This is the
# assertion that would catch the class of bug where every check reports the same
# status regardless of what it actually observed.
want e2e-command-ok       up
want e2e-command-broken   down
want e2e-http-self        up
want e2e-http-dead        down

# expect_output is the real contract of a `command` check: a command that exits 0
# but prints the wrong thing must NOT be reported as up. Both repo-build-guard and
# repo-smoke-guard are `command` checks that depend on exactly this — if
# expect_output stopped being enforced, a STALE or FAILING build report would be
# indistinguishable from a passing one, which is the whole bug those guards exist
# to prevent.
want e2e-command-wrong-output down

step "a failing check records WHY it failed"
ERR=$(jq -r '.services[] | select(.name=="e2e-command-broken") | .last_error' <<<"$STATUS_JSON")
[ -n "$ERR" ] && [ "$ERR" != "null" ] || fail "e2e-command-broken reported no last_error"
echo "    last_error: $ERR"

step "consecutive failures are counted, and only they promote degraded -> down"
FAILS=$(jq -r '.services[] | select(.name=="e2e-command-broken") | .consecutive_failures' <<<"$STATUS_JSON")
[ "$FAILS" -ge 2 ] || fail "e2e-command-broken is down at consecutive_failures=$FAILS, but alert_threshold is 2"
echo "    consecutive_failures: $FAILS (>= alert_threshold 2)"

step "a healthy check reports zero consecutive failures"
OKFAILS=$(jq -r '.services[] | select(.name=="e2e-command-ok") | .consecutive_failures' <<<"$STATUS_JSON")
[ "$OKFAILS" = "0" ] || fail "e2e-command-ok has consecutive_failures=$OKFAILS, want 0"
echo "    consecutive_failures: 0"

step "POST /api/check/e2e-disk — on-demand resource check"
CHECK=$(curl -fsS --max-time 10 -X POST "$BASE/api/check/e2e-disk")
CSTATUS=$(jq -r '.status' <<<"$CHECK")
[ "$CSTATUS" = "up" ] || fail "on-demand check of e2e-disk returned status '$CSTATUS', want up (body: $CHECK)"
echo "    e2e-disk -> $CSTATUS"

step "POST /api/check/<unknown> is a 404, not a 200"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$BASE/api/check/no-such-resource")
[ "$CODE" = "404" ] || fail "POST /api/check/no-such-resource returned $CODE, want 404"
echo "    404"

step "GET /api/check/e2e-disk is a 405 — the route requires POST"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/api/check/e2e-disk")
[ "$CODE" = "405" ] || fail "GET /api/check/e2e-disk returned $CODE, want 405"
echo "    405"

step "SUCCESS"
