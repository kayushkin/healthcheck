#!/usr/bin/env bash
# process-count-status.sh — a healthcheck `command` guard that goes DOWN when the host
# is accumulating processes, the shape that OOM'd the box on 2026-09-04 when a runaway
# sabotage scorer left 1,688 orphaned python3 interpreters (~10 GB). Each was only
# ~6 MB, so the OOM killer never targeted them; memory sat pinned at 95% for three days.
#
# Why this exists next to the `memory` resource check: `memory` watched the SYMPTOM and
# reported 95% correctly for three days while nothing acted. This watches the CAUSE — a
# process pileup — so a green here means the specific failure that filled memory is not
# building, whatever the percentage reads.
#
# Contract (healthcheck `type: command`, `expect_output: "ok"`): print a line containing
# "ok" and exit 0 when healthy; print a FAIL line and exit 1 otherwise. One `ps` call,
# well under healthcheck's 10s command timeout.
#
# Thresholds are env-overridable so the config.yaml block can tune them without editing
# this file. Defaults chosen against measured extremes: a healthy box ran 235 processes
# with ~4 python3; the incident had 2,066 processes and 1,688 python3.
set -euo pipefail

TOTAL_MAX="${PROC_TOTAL_MAX:-800}"        # total processes, kernel threads included
SAME_COMM_MAX="${PROC_SAME_COMM_MAX:-300}" # instances sharing one command name

# One snapshot of every process's command name. `ps` returns the table even under load,
# so a failure to read it is a real inability to see process state, not a quiet zero.
snapshot="$(ps -eo comm= 2>/dev/null)" || { echo "FAIL: ps could not read the process table"; exit 1; }

# wc -l, never `grep -c` here: grep exits 1 on no match and `set -e` would kill the guard
# on an empty table — the guarded-count-wait footgun this fleet has a whole instrument for.
total="$(printf '%s\n' "$snapshot" | wc -l | tr -d ' ')"

# The largest single command-name population. awk consumes the whole stream and prints
# only the first row, so no `head` closes the pipe early (which under pipefail reads as
# a failed pipeline).
top="$(printf '%s\n' "$snapshot" | sort | uniq -c | sort -rn | awk 'NR==1{print $1, $2; exit}')"
top_count="${top%% *}"
top_comm="${top#* }"

if [ "$total" -gt "$TOTAL_MAX" ]; then
  echo "FAIL: $total processes (ceiling $TOTAL_MAX); largest group ${top_count}x ${top_comm}"
  exit 1
fi
if [ "${top_count:-0}" -gt "$SAME_COMM_MAX" ]; then
  echo "FAIL: ${top_count} instances of '${top_comm}' (ceiling $SAME_COMM_MAX) — process pileup; $total processes total"
  exit 1
fi

echo "ok: $total processes, largest group ${top_count}x ${top_comm} (ceilings ${TOTAL_MAX} total / ${SAME_COMM_MAX} per command)"
