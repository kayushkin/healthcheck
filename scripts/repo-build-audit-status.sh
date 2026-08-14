#!/usr/bin/env bash
#
# repo-build-audit-status — read the last repo-build-audit report and say
# whether the fleet still builds from a clean clone of HEAD.
#
# healthcheck polls this as a `command` service (60s interval, 10s timeout), so
# it must stay cheap: the expensive clean-clone sweep runs nightly under the
# scheduler and leaves its verdict in report.json. This only reads that verdict.
#
# It fails on a STALE report as loudly as on a failing build. A guard that
# quietly stopped running looks exactly like a guard that is passing, and that
# equivalence is what let a broken tree ship for 3.5 months.
#
# It also refuses a report the sweep stamped for another MODE. This file picks
# its report by path, but the sweep takes its mode from a flag and its path from
# REPORT=, so the pairing can be wrong — and the four modes name their counts
# alike enough that a wrong one reads as a clean fleet rather than an error.
#
# And it refuses a sweep that JUDGED nothing — ok + failed of zero, counted
# rather than the repos_total the sweep merely looked at. Such a sweep writes
# no `aborted` and no `only`, so every check above passes in turn and this
# file used to print "ok: 0/0" and exit 0.
#
# Prints a line containing "ok" (healthcheck's expect_output) and exits 0 when
# the last sweep was clean and recent; otherwise prints why and exits 1.

set -uo pipefail

REPORT="${REPORT:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit/report.json}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"   # nightly job + margin for a missed run

if [ ! -f "$REPORT" ]; then
  echo "FAIL: no repo-build-audit report at $REPORT — the nightly build guard has never run"
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
    print(f"FAIL: repo-build-audit report is unreadable ({err})")
    sys.exit(1)

if report.get("mode") != "build":
    # Checked FIRST, because until the mode is right every field below is being
    # read off the wrong run. This reader picks its report by PATH, but the sweep
    # takes its mode from --smoke/--node/--elf and its path from REPORT=, and the
    # two can be paired wrongly — which is the documented way to run one guard by
    # hand without clobbering the fleet report. The four modes name their counts
    # alike (repos_total, ok, failed, unguarded), so nothing downstream notices:
    # fed the elf report, this file printed "ok: 78/81 repos build from a clean
    # clone of HEAD" and exited 0, for a sweep that compiled nothing at all. The
    # sweep stamps mode on every report it writes, including the aborted ones.
    print("FAIL: repo-build report is not a --build report (mode=" + str(report.get("mode")) + ")")
    sys.exit(1)

aborted = report.get("aborted")
if aborted:
    # The sweep refused to start, so every count below is zero and reporting them
    # would read as "nothing is broken". Say what stopped it instead. Checked
    # before staleness because an abort is fresh news, not old news.
    print(f"FAIL: repo-build sweep did not run — {aborted}. Nothing was checked.")
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
        "FAIL: the last repo-build sweep ran with --only " + str(only) + ", so it covered "
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
        f"FAIL: repo-build-audit is STALE — last ran {age_hours:.1f}h ago "
        f"(max {max_age:.0f}h). The build guard is not running; nothing is "
        f"checking that the committed trees still compile."
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
    print("FAIL: repo-build sweep judged 0 repositories, so nothing was checked.")
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
        "FAIL: repo-build report carries no coverage accounting "
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
        f"FAIL: repo-build coverage does not reconcile — {scanned} directories under "
        f"the repos root, but {total} judged plus {excluded} named as excluded "
        f"= {total + excluded}. Some directory left the sweep by a route the "
        f"report does not record, so the coverage figure below is not trustworthy."
    )
    sys.exit(1)

if failed:
    # No single quotes anywhere in this block: it is embedded in a single-quoted
    # shell string, and a nested one silently ends it.
    # Name the stage that actually failed, rather than asserting "do not build".
    #
    # The sweep runs build, then vet, then — under --with-tests — test, and it
    # stamps the failing stage on every row. This sentence used to say "do not
    # build from a clean clone of HEAD" no matter which of the three broke, while
    # printing the real stage in the same breath. Measured 2026-08-14 by feeding
    # this reader a --with-tests report: it printed
    #
    #   FAIL: 1 repo(s) do not build from a clean clone of HEAD: argraphments (go test)
    #
    # about a repo that builds and vets clean and fails only its tests. The line
    # contradicted itself, and the half a human acts on was the false half — it
    # sends a reader looking for a compile error that is not there.
    #
    # This is the same defect the --only refusal above exists to prevent, in a
    # different direction: there, a report covering a SMALLER population could
    # pass for the fleet verdict; here, a report covering MORE STAGES gets
    # described as though it covered only the first. A report that judged more
    # than building is not wrong to read, it is wrong to paraphrase.
    stages_failed = sorted({f.get("stage", "?") for f in report.get("failures", [])})
    if stages_failed == ["build"]:
        verb = "do not build from a clean clone of HEAD"
    else:
        verb = "fail from a clean clone of HEAD at go " + ", go ".join(stages_failed)
    # When every failure broke at the same stage the verb already names it, so
    # repeating it per repo is noise. When they differ, each repo needs its own.
    if len(stages_failed) == 1:
        broken = ", ".join([f.get("repo", "?") for f in report.get("failures", [])])
    else:
        broken = ", ".join(
            [f.get("repo", "?") + " (go " + f.get("stage", "?") + ")"
             for f in report.get("failures", [])]
        )
    print(f"FAIL: {failed} repo(s) {verb}: {broken}")
    sys.exit(1)

# The coverage figure is printed, not merely reconciled. The identity above
# proves the numbers add up; it cannot tell that 71 was 72 last night. Putting
# both halves on the line a human actually reads is what makes a repo silently
# leaving the sweep look different from a clean fleet.
print(
    f"ok: {ok}/{total} repos build from a clean clone of HEAD "
    f"({total} of {scanned} directories under the repos root are Go repos, "
    f"{unguarded} unguarded, checked {age_hours:.1f}h ago)"
)
'
