#!/usr/bin/env bash
#
# repo-node-status — read the last repo-build-audit --node report and say whether
# the fleet's TypeScript/React packages still install and build from a clean
# clone of HEAD.
#
# healthcheck polls this as a `command` service (60s interval, 10s timeout), so
# it must stay cheap: the expensive clean-clone sweep runs nightly under the
# scheduler and leaves its verdict in node-report.json. This only reads that
# verdict.
#
# It fails on a STALE report as loudly as on a failing build. A guard that
# quietly stopped running looks exactly like a guard that is passing, and that
# equivalence is what let a broken tree ship for 3.5 months. It matters more
# here than for the Go pass, not less: node and npm exist on this host only
# under mise, so a --node job that loses its PATH does not fail loudly, it fails
# with "npm: not found" and leaves yesterday's green report sitting on disk.
#
# It does NOT fail on packages reported `unguarded`. Those are packages the sweep
# cannot judge at all (no committed lockfile; a lockfile for a package manager
# this host does not have), and there are two of them today. The count is printed
# so the gap stays visible and shrinks, but a red-from-day-one check is a check
# people learn to ignore — and an ignored guard is worse than no guard.
#
# Prints a line containing "ok" (healthcheck's expect_output) and exits 0 when
# the last sweep was clean and recent; otherwise prints why and exits 1.

set -uo pipefail

REPORT="${REPORT:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit/node-report.json}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"   # nightly job + margin for a missed run

if [ ! -f "$REPORT" ]; then
  echo "FAIL: no repo-node report at $REPORT — the nightly TS/React build guard has never run"
  exit 1
fi

REPORT="$REPORT" MAX_AGE_HOURS="$MAX_AGE_HOURS" python3 -c '
import datetime, json, os, sys

path = os.environ["REPORT"]
max_age = float(os.environ["MAX_AGE_HOURS"])

try:
    with open(path) as fh:
        report = json.load(fh)
except Exception as err:
    print(f"FAIL: repo-node report is unreadable ({err})")
    sys.exit(1)

generated = datetime.datetime.fromisoformat(report["generated_at"])
if generated.tzinfo is None:
    print("FAIL: report generated_at has no timezone offset")
    sys.exit(1)
age_hours = (datetime.datetime.now(datetime.timezone.utc) - generated).total_seconds() / 3600

failed = report.get("failed", 0)
total = report.get("repos_total", 0)
ok = report.get("ok", 0)
unguarded = report.get("unguarded", 0)

if age_hours > max_age:
    print(
        f"FAIL: repo-node audit is STALE — last ran {age_hours:.1f}h ago "
        f"(max {max_age:.0f}h). The TS/React build guard is not running; nothing "
        f"is checking that the committed frontends still install and build."
    )
    sys.exit(1)

if failed:
    # No single quotes anywhere in this block: it is embedded in a single-quoted
    # shell string, and a nested one silently ends it.
    broken = ", ".join(
        [f.get("repo", "?") + " (" + f.get("stage", "?") + ")"
         for f in report.get("failures", [])]
    )
    print(f"FAIL: {failed} node package(s) do not build from a clean clone of HEAD: {broken}")
    sys.exit(1)

print(
    f"ok: {ok}/{total} node packages install and build from a clean clone of HEAD "
    f"({unguarded} unguarded, checked {age_hours:.1f}h ago)"
)
'
