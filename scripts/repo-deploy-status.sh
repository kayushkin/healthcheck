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
# It also refuses a report stamped for another MODE, one whose sweep ABORTED
# before it started, one that identified zero artifacts, and one that states no
# max_behind tolerance. This file reads every field with a default, so each of
# those four used to produce a GREEN line over a comparison that never happened
# rather than an error.
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

if report.get("mode") != "deploy":
    # Checked FIRST, because until the mode is right every field below is being
    # read off the wrong run. This reader picks its report by PATH, but both
    # sweeps take their path from REPORT=, so the two can be paired wrongly —
    # which is the documented way to run one guard by hand without clobbering the
    # fleet report. This reader reads every field it wants with a default, so a
    # foreign report does not error, it goes GREEN: fed the Go build report it
    # printed "ok: all 0 deployed artifacts match their committed HEAD within ?
    # commits" and exited 0. Both sweeps stamp mode on every report they write.
    print("FAIL: repo-deploy report is not a --deploy report (mode=" + str(report.get("mode")) + ")")
    sys.exit(1)

aborted = report.get("aborted")
if aborted:
    # The sweep refused to start, so every count below is zero and reporting
    # them would read as "nothing is broken". Say what stopped it instead.
    # Checked before staleness because an abort is fresh news, not old news:
    # the report it wrote is stamped seconds ago, so the age clause passes and
    # only this branch can catch it.
    #
    # Until 2026-08-08 the sweep wrote no report at all when it aborted and
    # this branch did not exist, so a missing go toolchain left the report from
    # the night before in place and this reader announced a green fleet over a
    # run that identified zero artifacts.
    #
    # No apostrophes in this block: it is embedded in a single-quoted shell
    # string, and a nested one silently ends it. This comment cost a run.
    print(f"FAIL: repo-deploy sweep did not run — {aborted}. Nothing was checked.")
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

if not total:
    # The sweep identifies a deployed artifact by asking go version -m for its
    # module path, and it gates on the toolchain before it starts. Zero artifacts
    # therefore does not mean nothing is deployed on this box — 72 things are —
    # it means the sweep identified none of them. Reporting that as a clean run
    # is the same equivalence this file already refuses on staleness: nothing
    # checked must not be able to read as nothing broken.
    print("FAIL: repo-deploy report identified 0 deployed artifacts, so nothing was compared.")
    sys.exit(1)

if "max_behind" not in thresholds:
    # The OK line states the tolerance it applied. Without this the reader
    # printed a literal question mark in place of that number and still exited 0,
    # so it called the fleet green without being able to say how stale a running
    # binary was allowed to be.
    print("FAIL: repo-deploy report declares no max_behind threshold, so its verdict states no tolerance.")
    sys.exit(1)

problems = []

if stale:
    # No single quotes in this block: it is embedded in a single-quoted shell
    # string, and a nested one silently ends it.
    worst = sorted(stale, key=lambda a: -a.get("behind", 0))[:4]

    def label(a):
        # A no-module artifact has no repo to name — that is the whole finding —
        # so name the artifact, which is also the thing you go and fix.
        if a.get("status") == "no-module":
            return os.path.basename(a.get("artifact", "?")) + " (no-module)"
        if a.get("status") in ("orphan-rev", "no-vcs"):
            return a.get("repo", "?") + " (" + a.get("status", "?") + ")"
        return a.get("repo", "?") + " (" + str(a.get("behind", 0)) + " behind)"

    named = ", ".join([label(a) for a in worst])
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
max_behind = thresholds["max_behind"]
print(
    f"ok: all {total} deployed artifacts match their committed HEAD within "
    f"{max_behind} commits{ghost_note} "
    f"(checked {age_hours:.1f}h ago)"
)
'
