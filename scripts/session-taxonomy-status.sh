#!/usr/bin/env bash
#
# session-taxonomy-status.sh — healthcheck's cheap reader for the report that
# session-taxonomy-audit.sh writes overnight.
#
# Prints one line starting with "ok:" and exits 0 when the session
# classification table is clean, or one starting with "FAIL:" and exits 1
# otherwise. healthcheck runs this on a 60s interval with a 10s timeout, so it
# must not do any work of its own beyond reading a file.
#
# The ladder below is ordered deliberately. An aborted sweep is checked before
# staleness because "the guard refused to run this morning" is fresh news and
# more actionable than "the file is old". Staleness is checked before findings
# because a stale clean report is not evidence of anything.

set -uo pipefail

STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit}"
REPORT="${REPORT:-$STATE_DIR/session-taxonomy-report.json}"
# Nightly cadence plus margin. A report older than this means the sweep is not
# running, whatever it last said.
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"

# No single quotes or apostrophes anywhere inside this python block: it is
# itself inside a single-quoted shell string.
REPORT="$REPORT" MAX_AGE_HOURS="$MAX_AGE_HOURS" python3 -c '
import json, os, sys
from datetime import datetime, timezone

report_path = os.environ["REPORT"]
max_age_hours = float(os.environ["MAX_AGE_HOURS"])

if not os.path.exists(report_path):
    print("FAIL: no session taxonomy report at %s — the nightly guard has never run" % report_path)
    sys.exit(1)

try:
    with open(report_path) as fh:
        report = json.load(fh)
except Exception as exc:
    print("FAIL: session taxonomy report at %s is unreadable: %s" % (report_path, exc))
    sys.exit(1)

if report.get("mode") != "session-taxonomy":
    print("FAIL: report at %s has mode=%r, not session-taxonomy" % (report_path, report.get("mode")))
    sys.exit(1)

aborted = report.get("aborted")
if aborted:
    print("FAIL: session taxonomy sweep did not run — %s. Nothing was checked." % aborted)
    sys.exit(1)

generated_at = report.get("generated_at") or ""
try:
    stamp = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
except ValueError:
    print("FAIL: report generated_at is unparseable: %r" % generated_at)
    sys.exit(1)
if stamp.tzinfo is None:
    print("FAIL: report generated_at %r has no timezone offset" % generated_at)
    sys.exit(1)

age_hours = (datetime.now(timezone.utc) - stamp).total_seconds() / 3600.0
if age_hours > max_age_hours:
    print("FAIL: session taxonomy report is STALE (%.1fh old, limit %.0fh) — the guard is not running" % (age_hours, max_age_hours))
    sys.exit(1)

live = report.get("live_findings", [])
if live:
    worst = ", ".join(
        "%s/%s/%s x%d" % (
            f.get("type") or "-", f.get("purpose") or "-", f.get("origin") or "-",
            f.get("sessions", 0))
        for f in live[:3])
    print("FAIL: %d live session classifications disagree with the registry: %s" % (len(live), worst))
    sys.exit(1)

total = report.get("sessions_total", 0)
historical = report.get("historical_sessions", 0)
note = ""
if historical:
    note = ", %d historical rows left alone" % historical
unused = report.get("unused_purposes", [])
if unused:
    note += ", %d registered purposes unused" % len(unused)
print("ok: %d sessions classified against the registry, 0 live disagreements%s (checked %.1fh ago)" % (
    total, note, age_hours))
'
exit $?
