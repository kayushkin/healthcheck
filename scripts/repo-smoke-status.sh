#!/usr/bin/env bash
#
# repo-smoke-status — read the last repo-build-audit --smoke report and say
# whether every committed HEAD that ships a boot smoke still BOOTS and ANSWERS.
#
# The build guard (repo-build-audit-status.sh) answers "does it compile". This
# answers the question compiling cannot: "does the binary actually run". They are
# different questions with different answers — noteboard's tree compiles clean
# and the resulting binary dies on its first request with `no such module: fts5`,
# because FTS5 needs CGO flags that a bare `go build` does not pass. A guard that
# only compiles would call that repo green forever.
#
# healthcheck polls this as a `command` service, so it must stay cheap: the
# expensive clean-clone-and-boot sweep runs nightly under the scheduler and
# leaves its verdict in smoke-report.json. This only reads that verdict.
#
# It fails on a STALE report as loudly as on a failing smoke, and on an ABORTED
# one sooner still. A guard that quietly stopped running looks exactly like a
# guard that is passing, and that equivalence is what let a broken tree ship for
# 3.5 months. A sweep that refused to start writes `aborted` into the report
# rather than leaving the previous night's verdict in place, so the same morning
# says what stopped it instead of a generic STALE the next afternoon.
#
# It does NOT fail on repos that ship no smoke yet. Coverage is reported as a
# number so the gap stays visible and shrinks, but a red-from-day-one check is a
# check people learn to ignore — and an ignored guard is worse than no guard.
#
# And it refuses a sweep that JUDGED nothing — ok + failed of zero, counted
# rather than the repos_total the sweep merely looked at. Such a sweep writes
# no `aborted` and no `only`, so every check above passes in turn and this
# file used to print "ok: 0/0" and exit 0.
#
# Prints a line containing "ok" (healthcheck's expect_output) and exits 0 when
# the last sweep was clean and recent; otherwise prints why and exits 1.

set -uo pipefail

REPORT="${REPORT:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit/smoke-report.json}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"   # nightly job + margin for a missed run

if [ ! -f "$REPORT" ]; then
  echo "FAIL: no repo-smoke report at $REPORT — the nightly boot-and-answer guard has never run"
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
    print(f"FAIL: repo-smoke report is unreadable ({err})")
    sys.exit(1)

if report.get("mode") != "smoke":
    print("FAIL: repo-smoke report is not a --smoke report (mode=" + str(report.get("mode")) + ")")
    sys.exit(1)

aborted = report.get("aborted")
if aborted:
    # The sweep refused to start, so every count below is zero and reporting them
    # would read as "nothing is broken". Say what stopped it instead. Checked
    # before staleness because an abort is fresh news, not old news.
    print(f"FAIL: repo-smoke sweep did not run — {aborted}. No binary was checked.")
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
        "FAIL: the last repo-smoke sweep ran with --only " + str(only) + ", so it covered "
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
no_smoke = report.get("no_smoke", 0)

if age_hours > max_age:
    print(
        f"FAIL: repo-smoke sweep is STALE — last ran {age_hours:.1f}h ago "
        f"(max {max_age:.0f}h). Nothing is checking that the committed binaries "
        f"still boot."
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
    # The second reason, measured 2026-08-08: repos_total does NOT count every
    # repo the sweep looked at, which is what the sentence here used to claim. It
    # counts what survived the filters — --build drops the 10 directories with no
    # go.mod, --smoke drops those plus the 10 Go repos with no `package main`,
    # and until that date neither left any trace in the report. The accounting
    # check below is what closes that gap; this one cannot, because it gates on a
    # number that is already net of the exclusions.
    #
    # A sweep that judged nothing is not a clean fleet. It writes no `aborted` and
    # no `only`, so every check above passes in turn and this file used to print
    # "ok: 0/0" and exit 0 — the --only defect without the flag. It needs no bug to
    # reach: the root comes from REPOS_DIR, and this guard runs from a systemd unit
    # whose Environment has already been wrong twice.
    print("FAIL: repo-smoke sweep judged 0 repositories, so nothing was checked.")
    sys.exit(1)

if "directories_scanned" not in report:
    # Written by every non-node sweep since 2026-08-08. A report without it is
    # either older than that or was produced by something other than this sweep;
    # either way the coverage below cannot be reconciled, and an unreconcilable
    # coverage claim is the thing this file exists to refuse.
    #
    # ⚠️ What this branch buys, measured by deleting it: NOT the difference
    # between green and red. Without it the next line raises KeyError, python
    # exits 1, and the check goes red anyway — safe, just illegible. It buys a
    # sentence that names the cause instead of a traceback. Said plainly because
    # the alternative is a future reader disproving an overclaim here and reading
    # that as clearance to delete the branch. The refusal that genuinely changes
    # the verdict is the reconciliation below: with THAT one removed, an
    # unbalanced report prints ok: 2/2 and exits 0.
    print(
        "FAIL: repo-smoke report carries no coverage accounting "
        "(directories_scanned is absent), so how much of the fleet it covered "
        "cannot be established. Re-run the sweep."
    )
    sys.exit(1)

# The coverage identity:
#
#   directories_scanned == repos_total
#                        + worktrees + without_go_mod + without_main_package
#                        + skipped_by_only
#
# It is an identity, not a policy. It passes no judgement on whether an exclusion
# was reasonable — only that every directory under the root left the sweep by a
# route the report names. When it fails, a directory stopped being covered
# through a path nobody wrote down.
#
# That is worth a refusal because shrinking coverage is invisible in the
# direction that looks healthy: a repo that loses its go.mod, or whose only
# `package main` moves somewhere uncommitted, simply leaves repos_total, and
# ok: N/N goes on printing with a smaller N. Every other exclusion in this sweep
# was already announced — worktrees, unguarded, no_smoke, without_check. These
# two were the ones that were not.
scanned = report["directories_scanned"]
excluded = (
    len(report.get("worktrees", []))
    + len(report.get("without_go_mod", []))
    + len(report.get("without_main_package", []))
    + report.get("skipped_by_only", 0)
)
if scanned != total + excluded:
    print(
        f"FAIL: repo-smoke coverage does not reconcile — {scanned} directories under "
        f"the repos root, but {total} judged plus {excluded} named as excluded "
        f"= {total + excluded}. Some directory left the sweep by a route the "
        f"report does not record, so the coverage figure below is not trustworthy."
    )
    sys.exit(1)

if failed:
    # No single quotes anywhere in this block: it is embedded in a single-quoted
    # shell string, and a nested one silently ends it.
    broken = ", ".join(
        [f.get("repo", "?") + " (" + f.get("stage", "?") + ")"
         for f in report.get("failures", [])]
    )
    print(f"FAIL: {failed} binary/binaries do not boot from a clean clone of HEAD: {broken}")
    sys.exit(1)

# Both halves of the coverage claim, for the reason given in the accounting
# block: N/N stays green as N falls, so N alone is not a coverage figure.
# --smoke has the largest exclusion of any mode, and none of it was visible here
# before 2026-08-08. Measured 2026-08-17 that is 20 of the 82 real directories
# under the repos root — real meaning not a `-wt-` git worktree, of which there
# are now 27 more, dropped before this exclusion runs. Re-take both numbers from
# the report: directories_scanned, worktrees, without_go_mod, without_main_package.
print(
    f"ok: {ok}/{total} binaries boot and answer from a clean clone of HEAD "
    f"({total} of {scanned} directories under the repos root ship a Go main "
    f"package, {no_smoke} ship no smoke yet, checked {age_hours:.1f}h ago)"
)
'
