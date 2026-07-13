#!/usr/bin/env bash
set -euo pipefail

# Mirrors logstack/deploy.sh: builds the healthcheck binary, drops it into
# ~/bin/healthcheck, and bounces the user systemd unit. Same DBus env shim so the
# script works from non-login shells (Claude, automation).
#
# Why this exists at all: healthcheck had NO deploy script. The README told you to
# `go build -o healthcheck ./cmd/healthcheck` -- a package path that does not
# exist (main is at the repo root) -- and the unit file in deploy/ pointed at a
# binary in the repo dir while the LIVE unit ran ~/bin/healthcheck. So nothing
# rebuilt the live binary, and it sat at its Apr 30 build for 2.5 months while Go
# changes landed in the repo: `enabled_state` was committed (e911f3d) and never
# served. A repo whose deploy path cannot deploy is the same failure shape as the
# 3.5-month unbuildable-tree drift.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"
SERVICE="healthcheck.service"
# Must match ExecStart in ~/.config/systemd/user/healthcheck.service. A sibling
# repo once shipped a deploy.sh whose BIN_NAME still named the repo it was copied
# from and would have overwritten that other service's binary.
BINARY="healthcheck"
PORT="8099"

cd "$REPO_DIR"

export PATH="$HOME/.local/share/mise/shims:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

echo "==> Building $BINARY..."
go build -o "$BINARY" .
echo "    built: $(ls -lh "$BINARY" | awk '{print $5}')"

echo "==> Running tests..."
go vet ./...
go test ./... >/dev/null
echo "    tests OK"

echo "==> Installing unit file..."
mkdir -p "$HOME/.config/systemd/user"
cp deploy/healthcheck.service "$HOME/.config/systemd/user/$SERVICE"

echo "==> Stopping $SERVICE..."
systemctl --user stop "$SERVICE" 2>/dev/null || true
sleep 1

echo "==> Installing binary to $BIN_DIR..."
mkdir -p "$BIN_DIR"
cp "$BINARY" "$BIN_DIR/$BINARY"

echo "==> Starting $SERVICE..."
systemctl --user daemon-reload
systemctl --user start "$SERVICE"

echo "==> Verifying..."
sleep 2
if ! systemctl --user is-active --quiet "$SERVICE"; then
  echo "ERROR: $SERVICE failed to start"
  journalctl --user -u "$SERVICE" -n 20 --no-pager 2>&1
  exit 1
fi
echo "    $SERVICE is running"

echo "==> Waiting for :$PORT to accept connections..."
READY_TIMEOUT=30
for i in $(seq 1 "$READY_TIMEOUT"); do
  if curl -fsS --max-time 5 "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    echo "    health OK (ready after ${i}s)"
    break
  fi
  if ! systemctl --user is-active --quiet "$SERVICE"; then
    echo "ERROR: $SERVICE died while starting up"
    journalctl --user -u "$SERVICE" -n 30 --no-pager 2>&1
    exit 1
  fi
  if [ "$i" -eq "$READY_TIMEOUT" ]; then
    echo "ERROR: $SERVICE still not answering :$PORT/api/health after ${READY_TIMEOUT}s"
    journalctl --user -u "$SERVICE" -n 30 --no-pager 2>&1
    exit 1
  fi
  sleep 1
done

echo "==> Smoke test..."

# Pin the deployed binary to one that actually carries the repo's Go changes, not
# merely to "a binary that starts". `enabled_state` is populated for every
# type=systemd service and was added in e911f3d; the binary that sat live for 2.5
# months omits the field entirely. If this assertion fails, the binary is stale --
# which is the exact condition this script exists to make impossible.
STATUS_BODY="$(curl -fsS --max-time 10 "http://localhost:$PORT/api/status")"

if ! printf '%s' "$STATUS_BODY" | grep -q '"enabled_state"'; then
  echo "ERROR: /api/status has no enabled_state -- deployed binary is stale (predates e911f3d)"
  exit 1
fi
echo "    enabled_state present"

# No check may be watching a unit that does not exist. checkSystemd reports that
# as status=misconfigured (distinct from down), and it means system_unit disagrees
# with where the unit actually lives -- a config bug that silently makes a check
# report nothing about its service while auto_restart hammers a phantom unit.
#
# `|| true` is load-bearing: grep exits 1 when it finds NO matches, and under
# `set -o pipefail` that aborts the script -- on the healthy path, where the count
# is legitimately zero. Without it this smoke test fails every good deploy and
# passes only the broken ones, which is worse than not having it.
MISCONFIGURED="$(printf '%s' "$STATUS_BODY" | grep -c '"status":"misconfigured"' || true)"
if [ "$MISCONFIGURED" -ne 0 ]; then
  echo "ERROR: $MISCONFIGURED check(s) report status=misconfigured -- a systemd check"
  echo "       names a unit that does not exist under the manager it probes."
  printf '%s' "$STATUS_BODY" | python3 -m json.tool | grep -B8 misconfigured || true
  exit 1
fi
echo "    no misconfigured checks"
echo "    smoke test OK"

echo "==> Done."
