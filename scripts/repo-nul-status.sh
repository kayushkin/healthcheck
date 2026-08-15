#!/usr/bin/env bash
#
# repo-nul-status — read the last repo-build-audit --nul report and say whether
# any source file committed under ~/repos contains a raw NUL byte.
#
# healthcheck polls this as a `command` service (60s interval, 10s timeout), so
# it must stay cheap: the fleet-wide HEAD scan runs nightly under the scheduler
# and leaves its verdict in nul-report.json. This only reads that verdict.
#
# Why this is a guard at all. One raw NUL byte makes the whole file binary to
# every content search on this box, and the failure is silent in the direction
# of "nothing here": the `grep` every agent runs is a ugrep wrapper invoked with
# -I (skip binary files), so the file answers every query with zero matches, no
# error and no warning. `file(1)` calls it `data`; git cannot diff it. So a
# search returning zero because the file is binary is indistinguishable from one
# returning zero because the pattern is absent, and every census phrased as
# "grep found N" silently excluded such a file. Two on this box carried one for
# three weeks each before anything noticed, and what noticed was a sweep whose
# own ranking was a grep count that could not see the file it most needed.
#
# It fails on a STALE report as loudly as on a finding, for the reason the whole
# family exists: a guard that quietly stopped running looks exactly like a guard
# that is passing.
#
# It also refuses a report the sweep stamped for another MODE. This file picks
# its report by path, but the sweep takes its mode from a flag and its path from
# REPORT=, so the pairing can be wrong — and a mismatched report is not merely
# uninformative, it names repos for a defect they do not have.
#
# And it refuses a sweep that read no FILES. That refusal is specific to this
# mode and is the important one: every other check here would pass on a sweep
# that walked zero blobs, because zero blobs contain zero NUL bytes. "Scanned
# nothing" and "found nothing" are the same output, which is the identical
# equivalence the defect itself has — so the floor is the one assertion that
# separates a clean fleet from a walk that never happened.
#
# Prints a line containing "ok" (healthcheck's expect_output) and exits 0 when
# the last scan found no raw NUL in committed source and is recent; otherwise
# prints which files carry one and exits 1.

set -uo pipefail

REPORT="${REPORT:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit/nul-report.json}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"       # nightly job + margin for a missed run
# The floor, deliberately far below the real figure (4143 source files at HEAD
# across 82 repos, measured 2026-08-15) rather than near it. It is here to catch
# a walk that collapsed to nothing — an empty REPOS_DIR, a systemd Environment
# without HOME, a git that stopped resolving HEAD — not to track fleet growth. A
# floor set close to the true count would go red every time a repo was archived,
# which is how a guard earns being ignored.
MIN_FILES_SCANNED="${MIN_FILES_SCANNED:-500}"

if [ ! -f "$REPORT" ]; then
  echo "FAIL: no repo-nul report at $REPORT — the nightly raw-NUL guard has never run"
  exit 1
fi

REPORT="$REPORT" MAX_AGE_HOURS="$MAX_AGE_HOURS" MIN_FILES_SCANNED="$MIN_FILES_SCANNED" python3 -c '
import datetime, json, os, sys

path = os.environ["REPORT"]
max_age = float(os.environ["MAX_AGE_HOURS"])
min_files = int(os.environ["MIN_FILES_SCANNED"])

try:
    with open(path) as fh:
        report = json.load(fh)
except Exception as err:
    print(f"FAIL: repo-nul report is unreadable ({err})")
    sys.exit(1)

if report.get("mode") != "nul":
    # Checked FIRST, because until the mode is right every field below is being
    # read off the wrong run. This reader picks its report by PATH, but the
    # sweep takes its mode from --smoke/--node/--elf/--nul and its path from
    # REPORT=, and the two can be paired wrongly — which is the documented way
    # to run one guard by hand without clobbering the fleet report. Fed another
    # mode s report the failure is loud rather than quiet, which is worse to
    # read: it would name a repo for a defect it does not have and send someone
    # after a byte that is not there. The sweep stamps mode on every report it
    # writes, including the aborted ones.
    print("FAIL: repo-nul report is not a --nul report (mode=" + str(report.get("mode")) + ")")
    sys.exit(1)

aborted = report.get("aborted")
if aborted:
    # The sweep refused to start, so every count below is zero and reporting
    # them would read as "nothing is broken". Say what stopped it instead.
    # Checked before staleness because an abort is fresh news, not old news.
    print(f"FAIL: repo-nul sweep did not run — {aborted}. Nothing was checked.")
    sys.exit(1)

only = report.get("only")
if only:
    # A --only sweep writes this SAME report path as a full one, so the two are
    # otherwise indistinguishable: the filter drops repos_total to the number
    # that matched and every count below agrees with itself, leaving a green
    # verdict that covers one repo. A partial sweep able to pass for the fleet
    # verdict is the same defect as a guard that quietly stopped running.
    print(
        "FAIL: the last repo-nul sweep ran with --only " + str(only) + ", so it covered "
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
        f"FAIL: repo-nul scan is STALE — last ran {age_hours:.1f}h ago "
        f"(max {max_age:.0f}h). The raw-NUL guard is not running; nothing is "
        f"checking that a source file has not gone invisible to every search."
    )
    sys.exit(1)

if ok + failed == 0:
    # Judged, not merely SEEN. repos_total includes the unguarded repos the
    # sweep could not judge at all, so a sweep in which every repo came back
    # unguarded prints a repos_total a reader is happy with and an ok count of
    # zero. A sweep that judged nothing is not a clean fleet, and it writes no
    # `aborted` and no `only`, so every check above passes in turn.
    print("FAIL: repo-nul sweep judged 0 repositories, so nothing was checked.")
    sys.exit(1)

if "files_scanned" not in report:
    # Written by every --nul sweep. Its absence means the report came from
    # something other than this sweep, and without it the floor below cannot be
    # applied at all — which would leave exactly the vacuous pass the floor is
    # here to refuse.
    print(
        "FAIL: repo-nul report carries no files_scanned count, so whether the "
        "sweep read any source at all cannot be established. Re-run the sweep."
    )
    sys.exit(1)

files_scanned = report["files_scanned"]
if files_scanned < min_files:
    # THE floor. Every other refusal in this file is shared with its sibling
    # readers; this one exists because of what the guard measures. A walk that
    # opens no file finds no NUL byte, so repos_total, ok and failed can all be
    # perfectly self-consistent over a sweep that read nothing — 82 repos, 82
    # ok, 0 failed, 0 bytes examined. "Scanned nothing" and "found nothing"
    # produce the same verdict, which is the very equivalence a raw NUL creates
    # in a content search. Refusing it here is the guard applying its own
    # lesson to itself.
    print(
        f"FAIL: repo-nul sweep read only {files_scanned} source files "
        f"(floor {min_files}). A walk that scans nothing finds no NUL bytes and "
        f"reports a clean fleet, so this verdict says nothing about the source."
    )
    sys.exit(1)

if "directories_scanned" not in report:
    print(
        "FAIL: repo-nul report carries no coverage accounting "
        "(directories_scanned is absent), so how much of the fleet it covered "
        "cannot be established. Re-run the sweep."
    )
    sys.exit(1)

# The coverage identity:
#
#   directories_scanned == repos_total + worktrees + skipped_by_only
#
# It is an identity, not a policy. It passes no judgement on whether an
# exclusion was reasonable — only that every directory under the root left the
# sweep by a route the report names. When it fails, a directory stopped being
# covered through a path nobody wrote down, and shrinking coverage is invisible
# in the direction that looks healthy.
scanned = report["directories_scanned"]
excluded = (
    len(report.get("worktrees", []))
    + len(report.get("without_go_mod", []))
    + len(report.get("without_main_package", []))
    + report.get("skipped_by_only", 0)
)
if scanned != total + excluded:
    print(
        f"FAIL: repo-nul coverage does not reconcile — {scanned} directories under "
        f"the repos root, but {total} judged plus {excluded} named as excluded "
        f"= {total + excluded}. Some directory left the sweep by a route the "
        f"report does not record, so the coverage figure below is not trustworthy."
    )
    sys.exit(1)

if failed:
    # No single quotes anywhere in this block: it is embedded in a
    # single-quoted shell string, and a nested one silently ends it.
    culprits = "; ".join(
        [f.get("repo", "?") + ": " + f.get("detail", "") for f in report.get("failures", [])]
    )
    print(f"FAIL: {failed} repo(s) commit a source file containing a raw NUL byte — {culprits}")
    sys.exit(1)

# Generated blobs are named in the green line as well as the red one. They are
# not a failure (the fix for a bundle is always the source file upstream of it),
# but a reader who never sees the count cannot tell "none exist" from "the mode
# does not look".
generated_hits = len(report.get("generated_with_nul", []))
print(
    f"ok: {ok}/{total} repos carry no raw NUL byte in committed source "
    f"({files_scanned} source files read across {total} of {scanned} directories "
    f"under the repos root, {unguarded} unguarded, {generated_hits} generated "
    f"blob(s) named but not failed, checked {age_hours:.1f}h ago)"
)
'
