#!/usr/bin/env bash
#
# repo-node-status — read the last repo-build-audit --node report and say whether
# the fleet's TypeScript/React packages still install, build, and pass their own
# declared `check` script from a clean clone of HEAD.
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
# this host does not have). Measured 2026-08-17 there are two, and that is a
# reading rather than a fixed size — this reader prints the live count on every
# run, and `unguarded_packages` in node-report.json names them. The count is
# printed so the gap stays visible and shrinks, but a red-from-day-one check is
# a check people learn to ignore — and an ignored guard is worse than no guard.
#
# It also refuses a report the sweep stamped for another MODE. This file picks
# its report by path, but the sweep takes its mode from a flag and its path from
# REPORT=, so the pairing can be wrong — and the five modes (build, smoke, node,
# elf, nul) name their counts alike enough that a wrong one reads as a clean
# fleet rather than an error.
#
# And it refuses a sweep that JUDGED nothing — ok + failed of zero, counted
# rather than the repos_total the sweep merely looked at. Such a sweep writes
# no `aborted` and no `only`, so every check above passes in turn and this
# file used to print "ok: 0/0" and exit 0.
#
# The same call, for the same reason, on `without_check`: packages that install
# and build but declare no `check` script, so the sweep ran no assertion about
# how they behave. Declaring one is how a package opts in; the count is printed
# so the gap is visible rather than mistaken for coverage.
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

if report.get("mode") != "node":
    # Checked FIRST, because until the mode is right every field below is being
    # read off the wrong run. This reader picks its report by PATH, but the sweep
    # takes its mode from --smoke/--node/--elf/--nul and its path from REPORT=,
    # and the two can be paired wrongly — which is the documented way to run one
    # guard by hand without clobbering the fleet report. The five modes name their
    # counts alike (repos_total, ok, failed, unguarded), so nothing downstream
    # notices: fed the Go build report, this file printed "ok: 71/71 node packages
    # install, build and pass their declared checks" and exited 0. Measured
    # 2026-08-17 there are 12 node packages, nothing like 71, and that run never
    # invoked npm at all. The sweep stamps mode on every report it writes,
    # including the aborted ones.
    print("FAIL: repo-node report is not a --node report (mode=" + str(report.get("mode")) + ")")
    sys.exit(1)

aborted = report.get("aborted")
if aborted:
    # The sweep refused to start, so every count below is zero and reporting them
    # would read as "nothing is broken". Say what stopped it instead. Checked
    # before staleness because an abort is fresh news, not old news.
    print(f"FAIL: repo-node sweep did not run — {aborted}. Nothing was checked.")
    sys.exit(1)

only = report.get("only")
if only:
    # A --only sweep writes this SAME report path as a full one, so the two are
    # otherwise indistinguishable: the filter drops repos_total to the number that
    # matched and every count below agrees with itself, leaving a green verdict that
    # covers one repo. Refuse it. A partial sweep able to pass for the fleet verdict
    # is the same defect as a guard that quietly stopped running, which this file
    # already refuses on staleness and on abort.
    print(
        "FAIL: the last repo-node sweep ran with --only " + str(only) + ", so it covered "
        "that repo alone and not the fleet. Re-run the sweep with no filter."
    )
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

if ok + failed == 0:
    # Judged, not merely SEEN. repos_total is the wrong quantity to gate on for
    # two separate reasons, and only the first was written down here originally:
    # it includes the unguarded repos the sweep could not judge at all, so a sweep
    # in which every repo came back unguarded prints a repos_total the reader is
    # happy with and an ok count of zero. This check was written against
    # repos_total first and the selftest caught it — an --elf sweep of an empty
    # root reports repos_total=1 having scanned nothing, because the unmatched
    # glob is swept as a repo literally named *.
    #
    # The second reason, measured 2026-08-08 and recorded in repo-elf-status.sh
    # the same day: repos_total does NOT count every repo the sweep looked at,
    # which is what this comment used to claim. It counts what survived the
    # filters — a --node sweep counts packages that reached the install step, and
    # the non-node modes drop the directories with no go.mod and, in smoke, the Go
    # repos with no `package main`. The accounting check below is what closes that
    # gap; this one cannot, because it gates on a number already net of the
    # exclusions.
    #
    # A sweep that judged nothing is not a clean fleet. It writes no `aborted` and
    # no `only`, so every check above passes in turn and this file used to print
    # "ok: 0/0" and exit 0 — the --only defect without the flag. It needs no bug to
    # reach: the root comes from REPOS_DIR, and this guard runs from a systemd unit
    # whose Environment has already been wrong twice.
    print("FAIL: repo-node sweep judged 0 packages, so nothing was checked.")
    sys.exit(1)

if failed:
    # No single quotes anywhere in this block: it is embedded in a single-quoted
    # shell string, and a nested one silently ends it.
    broken = ", ".join(
        [f.get("repo", "?") + " (" + f.get("stage", "?") + ")"
         for f in report.get("failures", [])]
    )
    print(f"FAIL: {failed} node package(s) do not build or check clean from a clean clone of HEAD: {broken}")
    sys.exit(1)

without_check = len(report.get("without_check") or [])
print(
    f"ok: {ok}/{total} node packages install, build and pass their declared checks "
    f"from a clean clone of HEAD ({unguarded} unguarded, {without_check} declaring "
    f"no check script, checked {age_hours:.1f}h ago)"
)
'
