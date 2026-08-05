#!/usr/bin/env bash
#
# session-taxonomy-audit.sh — nightly check that sessions say true things
# about themselves.
#
# Every session row carries three classification fields:
#
#   type     how it runs      interactive | autonomous | system | herald | external
#   purpose  what it does     chat, autoworker, subagent, conformance, ...
#   origin   who created it   frontend, scheduler, healthcheck, discovery, ...
#
# They are load-bearing. Permission gating reads type to decide whether a
# human is there to answer a tool prompt. Folder routing reads purpose. The
# chat list, the kanban classifier and every dashboard filter read all three.
# A row that misstates them is not a cosmetic problem: it routes real
# decisions off a false premise, and it cannot be corrected later because the
# caller that knew the truth is long gone.
#
# WHAT WENT WRONG, which is what this guard exists to catch
#
# For months nothing validated these fields. POST /sessions logged whatever
# arrived and stored it, including empty strings, while the wire contract
# documented all three as required. Two failures grew in that gap:
#
#   1. Six callers sent no classification at all — healthcheck's two alert
#      paths, marginalia, the TUI and the e2e scripts. Four of them were
#      still sending "source", a field renamed to "purpose" in May 2026 and
#      silently dropped on decode ever since.
#
#   2. bridge-agent exposes a free-text -purpose flag, so agents wrote
#      descriptions into it: "dashv2 browser verification + A/B perf",
#      "waitwell-dmv-api-recon", "harness-session-id smoke". A vocabulary of
#      slugs turned into a column of one-off sentences that nothing can
#      group or filter.
#
# Then a startup migration read "no type" as "interactive" and rewrote those
# rows into human chats. It ran on every open, not once, so it kept doing it
# to each night's new imports. 987 sessions were misclassified before anyone
# looked, including 91 `claude -p` runs from a shell that the bridge never
# ran at all.
#
# WHAT THIS CHECKS
#
# The vocabulary lives in Go, in llm-bridge/msg/purpose.go, and the analysis
# lives in bridge-server behind GET /session-taxonomy/report. This script
# does not know what a purpose is and must not learn: a list of valid slugs
# here would be a second copy of the registry, which is the exact failure
# above — the folder map was a second copy and drifted from it for months.
# Fetch, judge freshness, write it down.
#
# LIVE VERSUS HISTORICAL
#
# A finding is graded on when sessions with that classification were last
# created, not on whether it exists. History cannot be un-created, and a
# guard that stays red over 21 one-off rows from months ago is a guard people
# learn to ignore — at which point it is worse than no guard, because the
# dashboard still claims something is being watched.
#
# So: a bad classification still being produced within RECENT_DAYS is a live
# caller writing bad rows right now, and fails. Anything older is reported,
# counted, and left alone for a human to decide about. Nothing is hidden
# either way — a report that quietly dropped the old rows would be lying by
# omission about what is in the table.
#
# Exit codes follow the house rule: 0 = ran clean, 1 = ran and found live
# problems, 2 = could not run and checked nothing.

set -uo pipefail

BRIDGE_URL="${BRIDGE_URL:-http://localhost:8160}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit}"
REPORT="${REPORT:-$STATE_DIR/session-taxonomy-report.json}"
# How recently a bad classification must have been created to count as live.
# Nightly cadence plus margin, so a caller fixed yesterday goes green today
# rather than staying red for a week.
RECENT_DAYS="${RECENT_DAYS:-7}"

started_at="$(date --iso-8601=seconds)"
mkdir -p "$STATE_DIR"

# write_aborted_report records a refusal to run as a verdict.
#
# Exiting without touching the report used to leave the previous night's file
# on disk, and the status script reads that file — so a run that checked
# nothing went on reporting yesterday's "ok" for another 36 hours. A guard
# that cannot run must say so in the same place it would have said anything
# else.
write_aborted_report() {
  local reason="$1"
  python3 - "$REPORT" "$started_at" "$reason" <<'PY'
import json, sys
report_path, generated_at, reason = sys.argv[1], sys.argv[2], sys.argv[3]
report = {
    "mode": "session-taxonomy",
    "generated_at": generated_at,
    "aborted": reason,
    "duration_seconds": 0,
    "sessions_total": 0,
    "sessions_flagged": 0,
    "triples_total": 0,
    "triples_flagged": 0,
    "live_findings": [],
    "historical_findings": [],
    "unused_purposes": [],
    "failed": 0,
}
with open(report_path, "w") as fh:
    json.dump(report, fh, indent=2)
    fh.write("\n")
PY
  echo "FAIL: $reason"
}

command -v python3 >/dev/null 2>&1 || {
  echo "FAIL: no python3 on PATH"
  exit 2
}
command -v curl >/dev/null 2>&1 || {
  write_aborted_report "curl is not on PATH — could not reach the bridge"
  exit 2
}

# -f so an HTTP error becomes a non-zero exit rather than an error page that
# python would then fail to parse with a less useful message.
raw="$(curl -fsS --max-time 60 "$BRIDGE_URL/session-taxonomy/report" 2>&1)"
rc=$?
if [ $rc -ne 0 ]; then
  write_aborted_report "GET $BRIDGE_URL/session-taxonomy/report failed (curl rc=$rc): ${raw:0:300}"
  exit 2
fi

RAW="$raw" REPORT="$REPORT" GENERATED_AT="$started_at" RECENT_DAYS="$RECENT_DAYS" \
  STARTED_EPOCH="$(date +%s)" python3 -c '
import json, os, sys
from datetime import datetime, timedelta, timezone

raw = os.environ["RAW"]
report_path = os.environ["REPORT"]
generated_at = os.environ["GENERATED_AT"]
recent_days = int(os.environ["RECENT_DAYS"])
started_epoch = int(os.environ["STARTED_EPOCH"])

try:
    data = json.loads(raw)
except Exception as exc:
    print("FAIL: bridge returned unparseable JSON: %s" % exc)
    sys.exit(2)

cutoff = datetime.now(timezone.utc) - timedelta(days=recent_days)

def last_seen(finding):
    value = finding.get("last_seen") or ""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None

live, historical = [], []
for finding in data.get("findings", []):
    seen = last_seen(finding)
    # An unparseable or missing date is treated as live. The alternative
    # buries a finding nobody will look at again on the strength of a
    # timestamp we could not read.
    if seen is None or seen >= cutoff:
        live.append(finding)
    else:
        historical.append(finding)

live_sessions = sum(f.get("sessions", 0) for f in live)
historical_sessions = sum(f.get("sessions", 0) for f in historical)

report = {
    "mode": "session-taxonomy",
    "generated_at": generated_at,
    "duration_seconds": max(0, int(datetime.now(timezone.utc).timestamp()) - started_epoch),
    "recent_days": recent_days,
    "sessions_total": data.get("sessions_total", 0),
    "sessions_flagged": data.get("sessions_flagged", 0),
    "triples_total": data.get("triples_total", 0),
    "triples_flagged": data.get("triples_flagged", 0),
    "problems_by_kind": data.get("problems_by_kind", {}),
    "unused_purposes": data.get("unused_purposes", []),
    "live_sessions": live_sessions,
    "historical_sessions": historical_sessions,
    "live_findings": live,
    "historical_findings": historical,
    "failed": len(live),
}
with open(report_path, "w") as fh:
    json.dump(report, fh, indent=2)
    fh.write("\n")

print("sessions: %d total, %d flagged (%d live, %d historical)" % (
    report["sessions_total"], report["sessions_flagged"],
    live_sessions, historical_sessions))
for f in live:
    kinds = ",".join(p.get("kind", "?") for p in f.get("problems", []))
    print("  LIVE %4d  type=%-11s purpose=%-32s origin=%-20s %s" % (
        f.get("sessions", 0), f.get("type") or "(none)",
        f.get("purpose") or "(none)", f.get("origin") or "(none)", kinds))
for f in historical:
    kinds = ",".join(p.get("kind", "?") for p in f.get("problems", []))
    print("  old  %4d  type=%-11s purpose=%-32s origin=%-20s %s" % (
        f.get("sessions", 0), f.get("type") or "(none)",
        f.get("purpose") or "(none)", f.get("origin") or "(none)", kinds))
if report["unused_purposes"]:
    print("  registered purposes nothing creates: %s" % ", ".join(report["unused_purposes"]))

sys.exit(1 if live else 0)
'
exit $?
