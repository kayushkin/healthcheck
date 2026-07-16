#!/usr/bin/env bash
#
# repo-elf-status — read the last repo-build-audit --elf report and say whether
# any repo under ~/repos has committed a compiled ELF binary into its source
# tree at HEAD.
#
# healthcheck polls this as a `command` service (60s interval, 10s timeout), so
# it must stay cheap: the fleet-wide HEAD scan runs nightly under the scheduler
# and leaves its verdict in elf-report.json. This only reads that verdict.
#
# It fails on a STALE report as loudly as on a finding. A guard that quietly
# stopped running looks exactly like a guard that is passing — the precise
# equivalence that let a committed-binary sweep have to be done by a human
# walking ~/repos by hand in the first place.
#
# Why this is a guard at all: a committed multi-MB binary is pure weight in every
# clone and reads as source to anyone (human or agent) grepping the tree, while
# the live service runs its own ~/bin artifact — so the committed blob is a stale
# dropping that nobody notices until it is a habit. On 2026-07-16 nine repos had
# accumulated one each. There is deliberately NO allowlist: a repo that genuinely
# must commit a binary is a decision to make out loud when it happens, not a line
# pre-blessed here.
#
# Prints a line containing "ok" (healthcheck's expect_output) and exits 0 when
# the last scan found no committed binaries and is recent; otherwise prints which
# repos carry one and exits 1.

set -uo pipefail

REPORT="${REPORT:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit/elf-report.json}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"   # nightly job + margin for a missed run

if [ ! -f "$REPORT" ]; then
  echo "FAIL: no repo-elf report at $REPORT — the nightly committed-binary guard has never run"
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
    print(f"FAIL: repo-elf report is unreadable ({err})")
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
        f"FAIL: repo-elf scan is STALE — last ran {age_hours:.1f}h ago "
        f"(max {max_age:.0f}h). The committed-binary guard is not running; nothing "
        f"is checking that a compiled binary has not been committed into a source tree."
    )
    sys.exit(1)

if failed:
    # No single quotes anywhere in this block: it is embedded in a single-quoted
    # shell string, and a nested one silently ends it.
    culprits = ", ".join(
        [f.get("repo", "?") for f in report.get("failures", [])]
    )
    print(f"FAIL: {failed} repo(s) have a committed ELF binary at HEAD: {culprits}")
    sys.exit(1)

print(
    f"ok: {ok}/{total} repos carry no committed ELF binary at HEAD "
    f"({unguarded} unguarded, checked {age_hours:.1f}h ago)"
)
'
