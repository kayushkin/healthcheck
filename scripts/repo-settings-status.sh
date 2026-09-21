#!/usr/bin/env bash
#
# repo-settings-status — read the last repo-build-audit --settings report and say
# whether every Go repo that uses llm-bridge servicesettings still holds its
# environment reads to its declarations.
#
# healthcheck polls this as a `command` service (60s interval, 10s timeout), so
# it must stay cheap: the sweep runs nightly under the scheduler and leaves its
# verdict in settings-report.json. This only reads that verdict.
#
# Why this is a guard at all. Each converted service carries a test,
# TestEveryEnvironmentVariable…IsDeclared, that fails on any os.Getenv its
# declarations do not name — a setting the /settings page cannot show and the
# registry cannot refuse. That test runs only when somebody runs `go test`, and
# no other guard here does. So an undeclared read could land in a converted
# service and every nightly check would stay green.
#
# It fails on a STALE report as loudly as on a finding, for the reason the whole
# family exists: a guard that quietly stopped running looks exactly like a guard
# that is passing. It refuses a report stamped for another mode, an aborted
# sweep, and a --only sweep, as its siblings do.
#
# And it refuses a sweep that PASSED too few scan tests. A sweep that runs none
# fails none, so "no scan ran" and "every scan passed" are the same verdict
# without the floor.
#
# Prints a line containing "ok" (healthcheck's expect_output) and exits 0 when
# the last sweep found every converted repo's scan passing and is recent;
# otherwise prints which repos failed and exits 1.

set -uo pipefail

REPORT="${REPORT:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit/settings-report.json}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"       # nightly job + margin for a missed run
# The floor, deliberately far below the real figure (22 scan tests passed
# across 21 repos, measured 2026-09-21) rather than near it. It is here to catch a sweep
# that collapsed to nothing — an empty REPOS_DIR, a renamed test pattern, a go
# that stopped running tests — not to track the conversion's progress.
MIN_SCAN_TESTS_PASSED="${MIN_SCAN_TESTS_PASSED:-10}"

if [ ! -f "$REPORT" ]; then
  echo "FAIL: no repo-settings report at $REPORT — the nightly environment-read guard has never run"
  exit 1
fi

REPORT="$REPORT" MAX_AGE_HOURS="$MAX_AGE_HOURS" MIN_SCAN_TESTS_PASSED="$MIN_SCAN_TESTS_PASSED" python3 -c '
import datetime, json, os, sys

path = os.environ["REPORT"]
max_age = float(os.environ["MAX_AGE_HOURS"])
min_passed = int(os.environ["MIN_SCAN_TESTS_PASSED"])

try:
    with open(path) as fh:
        report = json.load(fh)
except Exception as err:
    print(f"FAIL: repo-settings report is unreadable ({err})")
    sys.exit(1)

if report.get("mode") != "settings":
    # Checked first: until the mode is right every field below is being read off
    # the wrong run, and another mode s failures would be named as findings here.
    print("FAIL: repo-settings report is not a --settings report (mode=" + str(report.get("mode")) + ")")
    sys.exit(1)

aborted = report.get("aborted")
if aborted:
    print(f"FAIL: repo-settings sweep did not run — {aborted}. Nothing was checked.")
    sys.exit(1)

only = report.get("only")
if only:
    # A --only sweep writes the same path as a full one, and its counts agree
    # with themselves over one repo.
    print(
        "FAIL: the last repo-settings sweep ran with --only " + str(only) + ", so it covered "
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
        f"FAIL: repo-settings sweep is STALE — last ran {age_hours:.1f}h ago "
        f"(max {max_age:.0f}h). Nothing is checking that a converted service reads "
        f"only the environment variables it declares."
    )
    sys.exit(1)

if ok + failed == 0:
    print("FAIL: repo-settings sweep judged 0 repositories, so nothing was checked.")
    sys.exit(1)

if "scan_tests_passed" not in report:
    print(
        "FAIL: repo-settings report carries no scan_tests_passed count, so whether "
        "any scan ran cannot be established. Re-run the sweep."
    )
    sys.exit(1)

passed = report["scan_tests_passed"]
if passed < min_passed and not failed:
    # Only when nothing failed: a red fleet is already reported below with its
    # culprits, and the floor would hide them behind a less useful sentence.
    print(
        f"FAIL: repo-settings sweep passed only {passed} scan tests "
        f"(floor {min_passed}). A sweep that runs no scan fails none, so this "
        f"verdict says nothing about the fleet."
    )
    sys.exit(1)

if "directories_scanned" not in report:
    print(
        "FAIL: repo-settings report carries no coverage accounting "
        "(directories_scanned is absent), so how much of the fleet it covered "
        "cannot be established. Re-run the sweep."
    )
    sys.exit(1)

# The coverage identity:
#
#   directories_scanned == repos_total + worktrees + without_go_mod
#                        + without_servicesettings + skipped_by_only
#
# Every directory under the root must leave the sweep by a route the report names.
scanned = report["directories_scanned"]
without_library = report.get("without_servicesettings", [])
excluded = (
    len(report.get("worktrees", []))
    + len(report.get("without_go_mod", []))
    + len(without_library)
    + report.get("skipped_by_only", 0)
)
if scanned != total + excluded:
    print(
        f"FAIL: repo-settings coverage does not reconcile — {scanned} directories under "
        f"the repos root, but {total} judged plus {excluded} named as excluded "
        f"= {total + excluded}. Some directory left the sweep by a route the "
        f"report does not record, so the coverage figure below is not trustworthy."
    )
    sys.exit(1)

if failed:
    # No single quotes anywhere in this block: it is embedded in a
    # single-quoted shell string, and a nested one silently ends it.
    culprits = "; ".join(
        [f.get("repo", "?") + " (" + f.get("stage", "") + "): " + f.get("detail", "") for f in report.get("failures", [])]
    )
    print(f"FAIL: {failed} repo(s) that use servicesettings do not hold their environment reads to their declarations — {culprits}")
    sys.exit(1)

# The services still reading the environment on their own are named in the
# green line, so the conversion s remainder is in front of whoever reads it.
unconverted = sorted(r["repo"] for r in without_library if r.get("ships_main_package"))
print(
    f"ok: {ok}/{total} repos that use servicesettings hold every environment read "
    f"to their declarations ({passed} scan tests passed, {unguarded} unguarded, "
    f"checked {age_hours:.1f}h ago); {len(unconverted)} Go service(s) not converted: "
    + (", ".join(unconverted) if unconverted else "none")
)
'
