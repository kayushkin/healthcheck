#!/usr/bin/env bash
#
# repo-deploy-status — read the last repo-deploy-audit report and say whether
# what is RUNNING still matches what is COMMITTED.
#
# healthcheck polls this as a `command` service, so it must stay cheap: the
# sweep runs under the scheduler and leaves its verdict in deploy-report.json.
# This only reads that verdict.
#
# Reports STALE as loudly as DRIFTED, for the same reason every other guard here
# does: a guard that quietly stopped running is indistinguishable from a guard
# that is passing, and that equivalence is the entire bug class.
#
# Prints a line containing "ok" (healthcheck's expect_output) and exits 0 when
# nothing running is stale and no work is abandoned; otherwise prints why.

set -uo pipefail

REPORT="${REPORT:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit/deploy-report.json}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"   # nightly job + margin for a missed run

if [ ! -f "$REPORT" ]; then
  echo "FAIL: no repo-deploy-audit report at $REPORT — the deploy guard has never run"
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
    print(f"FAIL: repo-deploy-audit report is unreadable ({err})")
    sys.exit(1)

generated = datetime.datetime.fromisoformat(report["generated_at"])
if generated.tzinfo is None:
    print("FAIL: report generated_at has no timezone offset")
    sys.exit(1)
age_hours = (datetime.datetime.now(datetime.timezone.utc) - generated).total_seconds() / 3600

if age_hours > max_age:
    print(
        f"FAIL: repo-deploy-audit is STALE — last ran {age_hours:.1f}h ago "
        f"(max {max_age:.0f}h). Nothing is checking that the running binaries "
        f"match the committed source."
    )
    sys.exit(1)

stale = report.get("stale_running", [])
wip = report.get("stale_wip", [])
ghosts = report.get("ghost_artifacts", [])
total = report.get("artifacts_total", 0)
thresholds = report.get("thresholds", {})

problems = []

if stale:
    # No single quotes in this block: it is embedded in a single-quoted shell
    # string, and a nested one silently ends it.
    worst = sorted(stale, key=lambda a: -a.get("behind", 0))[:4]
    named = ", ".join(
        [a.get("repo", "?") + " (" + str(a.get("behind", 0)) + " behind)"
         if a.get("status") not in ("orphan-rev", "no-vcs")
         else a.get("repo", "?") + " (" + a.get("status", "?") + ")"
         for a in worst]
    )
    more = "" if len(stale) <= 4 else f" +{len(stale) - 4} more"
    problems.append(
        f"{len(stale)} RUNNING binaries are stale vs their committed HEAD: {named}{more}"
    )

if wip:
    named = ", ".join(
        [w.get("repo", "?") + " (" + str(w.get("age_hours", 0)) + "h idle)" for w in wip[:4]]
    )
    more = "" if len(wip) <= 4 else f" +{len(wip) - 4} more"
    problems.append(
        f"{len(wip)} repo(s) hold uncommitted tracked changes with no agent working on them: {named}{more}"
    )

if problems:
    print("FAIL: " + "; ".join(problems))
    sys.exit(1)

ghost_note = f", {len(ghosts)} ghost artifact(s)" if ghosts else ""
max_behind = thresholds.get("max_behind", "?")
print(
    f"ok: all {total} deployed artifacts match their committed HEAD within "
    f"{max_behind} commits{ghost_note} "
    f"(checked {age_hours:.1f}h ago)"
)
'
