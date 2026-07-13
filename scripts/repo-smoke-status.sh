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
# It fails on a STALE report as loudly as on a failing smoke. A guard that
# quietly stopped running looks exactly like a guard that is passing, and that
# equivalence is what let a broken tree ship for 3.5 months.
#
# It does NOT fail on repos that ship no smoke yet. Coverage is reported as a
# number so the gap stays visible and shrinks, but a red-from-day-one check is a
# check people learn to ignore — and an ignored guard is worse than no guard.
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

if failed:
    # No single quotes anywhere in this block: it is embedded in a single-quoted
    # shell string, and a nested one silently ends it.
    broken = ", ".join(
        [f.get("repo", "?") + " (" + f.get("stage", "?") + ")"
         for f in report.get("failures", [])]
    )
    print(f"FAIL: {failed} binary/binaries do not boot from a clean clone of HEAD: {broken}")
    sys.exit(1)

print(
    f"ok: {ok}/{total} binaries boot and answer from a clean clone of HEAD "
    f"({no_smoke} ship no smoke yet, checked {age_hours:.1f}h ago)"
)
'
