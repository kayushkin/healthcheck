#!/usr/bin/env bash
#
# repo-deploy-audit — compare what is RUNNING against what is COMMITTED, and
# report the repos where the two have drifted apart.
#
# Why this exists
# ---------------
# repo-build-guard asks "does HEAD compile?". repo-smoke-guard asks "does HEAD
# boot?". Both interrogate the COMMITTED tree. Neither one ever asks the
# question that actually bit us:
#
#     is the binary currently serving traffic the one we committed?
#
# On 2026-07-13 llm-bridge-server was found running a Jun-15 binary, 14 commits
# behind HEAD — including the fix for the very bug being investigated. The cause
# was a chain no existing guard could see: a `.gitignore` glob (`credentials.*`)
# silently swallowed internal/harness/credentials.go, so the COMMITTED tree did
# not compile, so HEAD could not be deployed, so commits piled up for a month.
# Every working tree built fine, so `git status` stayed clean throughout.
# repo-build-guard eventually caught the unbuildable tree — but once it was
# fixed, nothing noticed that the running process was still a month stale.
#
# Drift is invisible precisely because a stale service looks identical to a
# healthy one: it's up, it answers, its health check is green. It just isn't
# running your code.
#
# How it identifies an artifact (this is the load-bearing part)
# ------------------------------------------------------------
# NOT by filename. Go stamps every binary with its module path and the git
# revision it was built from:
#
#     $ go version -m /usr/local/bin/llm-bridge
#         mod   github.com/kayushkin/llm-bridge-server
#         build vcs.revision=e7e1a2a440137ee19d2b37f2dca1ca453538052d
#         build vcs.modified=true
#
# So we read the artifact's OWN claim about where it came from and map that back
# to a repo, rather than guessing from its name. This is not fussiness. The name
# lies in both directions on this host:
#
#   - llm-bridge-server/ deploys a binary called `llm-bridge` (no `-server`)
#   - ~/bin/llm-bridge-server is a DEAD Apr-13 leftover that nothing runs
#
# A filename-based audit reads that leftover, reports "176 commits behind", and
# sends you chasing a binary that has not served a request in three months.
# That false lead cost real time during the incident this script came out of.
# The embedded module path cannot lie that way.
#
# What counts as deployed
# -----------------------
# Two populations, and the difference matters:
#
#   running    — resolved from /proc/<pid>/exe of live processes. AUTHORITATIVE.
#                This is what is actually serving.
#   on-disk    — executables in ~/bin and /usr/local/bin. What the NEXT spawn
#                (or `-discover` subprocess) would pick up.
#
# Both are reported. A module with an on-disk artifact that no process runs, when
# another artifact of the SAME module is running, is flagged as a ghost — that is
# the ~/bin/llm-bridge-server trap above, and naming it is how we stop re-walking
# into it.
#
# The second check: stale uncommitted work
# ----------------------------------------
# Same family of drift, other direction — code that exists only in a working
# tree. A repo with modified TRACKED files that no agent has touched in hours is
# not "work in progress", it is work that was abandoned mid-flight, and it will
# quietly conflict with the next agent that opens the repo.
#
# "Is an agent working on it right now?" is answered from the bridge, not
# guessed: we ask llm-bridge for sessions in an ACTIVE state and read their
# working_dir. A repo holding an active session is left alone. As a backstop for
# agents whose cwd does not match the repo they are editing, anything modified
# within FRESH_MINUTES is also treated as live.
#
# Untracked files are reported but never fail the run: they are usually scratch
# (llm-bridge-server has carried two stray patch_*.py since Jun 6). Modified
# TRACKED files are the ones that represent lost work.
#
# Consumed by scripts/repo-deploy-status.sh, which healthcheck polls.

set -uo pipefail

REPOS_DIR="${REPOS_DIR:-$HOME/repos}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit}"
REPORT="${REPORT:-$STATE_DIR/deploy-report.json}"

BIN_DIRS="${BIN_DIRS:-$HOME/bin /usr/local/bin}"
BRIDGE_URL="${BRIDGE_URL:-http://localhost:8160}"

# Gates. A single commit sitting undeployed for a month is worse than ten from
# this morning, so age and count are both gates, not just count.
MAX_BEHIND="${MAX_BEHIND:-5}"           # commits behind HEAD before it's a fail
MAX_BEHIND_DAYS="${MAX_BEHIND_DAYS:-7}" # age of the OLDEST undeployed commit
STALE_WIP_HOURS="${STALE_WIP_HOURS:-24}"
FRESH_MINUTES="${FRESH_MINUTES:-120}"   # touched this recently ⇒ assume live

mkdir -p "$STATE_DIR"

# Put the REAL go toolchain on PATH, not mise's shim — `go version -m` on a
# shim resolves the shim, not the binary we asked about.
for candidate in /usr/local/go/bin "$HOME/.local/share/mise/installs/go"/*/bin; do
  [ -x "$candidate/go" ] && { export PATH="$candidate:$PATH"; break; }
done

command -v go >/dev/null 2>&1 || { echo "FAIL: no go toolchain on PATH"; exit 2; }

started_at="$(date -Iseconds)"

# ---------------------------------------------------------------------------
# 1. Which repos have an active agent session right now?
#
# Ask the bridge. A session in an active state (its harness subprocess is live)
# whose working_dir sits inside a repo means someone is mid-edit there. Failing
# to ask is how two nightly workers end up rewriting each other's work.
#
# If the bridge is down we get an empty set, which makes the WIP check MORE
# conservative (nothing looks live) — so a bridge outage cannot mask stale work,
# it can only produce a false "stale" that a human dismisses. That asymmetry is
# deliberate: the failure mode of this guard should be noise, never silence.
# ---------------------------------------------------------------------------
active_dirs="$(
  curl -sfS -m 5 "$BRIDGE_URL/sessions" 2>/dev/null |
  python3 -c '
import json, sys
ACTIVE = {"starting", "running", "model_generating", "tool_running", "compacting", "rate_limited"}
try:
    sessions = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(sessions, dict):
    sessions = sessions.get("sessions", [])
for s in sessions:
    if s.get("state") in ACTIVE:
        wd = (s.get("info") or {}).get("working_dir") or ""
        if wd:
            print(wd)
' 2>/dev/null | sort -u
)"

repo_has_active_session() {
  local repo_path="$1"
  [ -z "$active_dirs" ] && return 1
  while IFS= read -r wd; do
    [ -z "$wd" ] && continue
    # working_dir inside the repo (or exactly it). "/" is the catch-all cwd many
    # agents run with and would match every repo, so it is never a match.
    [ "$wd" = "/" ] && continue
    case "$wd/" in "$repo_path"/*) return 0 ;; esac
  done <<<"$active_dirs"
  return 1
}

# ---------------------------------------------------------------------------
# 2. Enumerate deployed Go artifacts and ask each one where it came from.
# ---------------------------------------------------------------------------

# artifact_meta <path> → "modpath<TAB>revision<TAB>modified", empty if not Go.
artifact_meta() {
  go version -m "$1" 2>/dev/null | awk '
    $1 == "mod"   { mod = $2 }
    $1 == "build" && $2 ~ /^vcs\.revision=/ { rev = substr($2, 14) }
    $1 == "build" && $2 ~ /^vcs\.modified=/ { mod_dirty = substr($2, 14) }
    END { if (mod != "") printf "%s\t%s\t%s", mod, rev, mod_dirty }
  '
}

# Running processes first — these are authoritative.
running_bins=""
for pid_dir in /proc/[0-9]*; do
  exe="$(readlink -f "$pid_dir/exe" 2>/dev/null)" || continue
  [ -n "$exe" ] || continue
  case "$exe" in
    *"/bin/"*|*/usr/local/bin/*) ;;
    *) continue ;;
  esac
  running_bins="$running_bins$exe"$'\n'
done
running_bins="$(printf '%s' "$running_bins" | sort -u)"

is_running() {
  printf '%s\n' "$running_bins" | grep -qxF "$1"
}

# On-disk deployable artifacts.
candidates=""
for d in $BIN_DIRS; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] && [ -x "$f" ] && candidates="$candidates$f"$'\n'
  done
done
candidates="$(printf '%s%s' "$candidates" "$running_bins" | sort -u | sed '/^$/d')"

rows=""
drift_fail=0

while IFS= read -r bin; do
  [ -z "$bin" ] && continue
  meta="$(artifact_meta "$bin")"
  [ -z "$meta" ] && continue   # not a Go binary — nothing to compare

  modpath="$(printf '%s' "$meta" | cut -f1)"
  rev="$(printf '%s' "$meta" | cut -f2)"
  dirty="$(printf '%s' "$meta" | cut -f3)"

  repo="${modpath##*/}"
  repo_path="$REPOS_DIR/$repo"
  running=false; is_running "$bin" && running=true

  if [ ! -d "$repo_path/.git" ]; then
    rows="$rows$repo	$bin	$running	unmapped	0	$dirty	no repo at $repo_path for module $modpath"$'\n'
    continue
  fi

  if [ -z "$rev" ]; then
    # Built with -buildvcs=false, or from a tarball. We cannot know what it is.
    rows="$rows$repo	$bin	$running	no-vcs	0	$dirty	binary carries no vcs.revision — cannot verify what it was built from"$'\n'
    [ "$running" = true ] && drift_fail=$((drift_fail + 1))
    continue
  fi

  if ! git -C "$repo_path" cat-file -e "$rev^{commit}" 2>/dev/null; then
    # Built from a commit that no longer exists here: rebased away, or never
    # pushed. Unreproducible — you cannot rebuild what is running.
    rows="$rows$repo	$bin	$running	orphan-rev	0	$dirty	built from ${rev:0:7}, which is not in this repo (rebased or never committed)"$'\n'
    [ "$running" = true ] && drift_fail=$((drift_fail + 1))
    continue
  fi

  behind="$(git -C "$repo_path" rev-list --count "$rev"..HEAD 2>/dev/null || echo 0)"
  detail=""
  status=ok

  if [ "$behind" -gt 0 ]; then
    oldest_epoch="$(git -C "$repo_path" log --format=%ct --reverse "$rev"..HEAD 2>/dev/null | head -1)"
    age_days=0
    [ -n "$oldest_epoch" ] && age_days=$(( ( $(date +%s) - oldest_epoch ) / 86400 ))
    detail="$behind commit(s) behind HEAD; oldest undeployed is ${age_days}d old"
    status=behind
    if [ "$behind" -ge "$MAX_BEHIND" ] || [ "$age_days" -ge "$MAX_BEHIND_DAYS" ]; then
      status=stale
      [ "$running" = true ] && drift_fail=$((drift_fail + 1))
    fi
  fi

  rows="$rows$repo	$bin	$running	$status	$behind	$dirty	$detail"$'\n'
done <<<"$candidates"

# Ghost artifacts: same module deployed twice, one running, one not. The idle one
# is a decoy that will mislead the next audit (and the next human).
ghosts="$(
  printf '%s' "$rows" | awk -F'\t' '
    NF { seen[$1] = seen[$1] " " $2; if ($3 == "true") runs[$1] = 1 }
    END { for (m in seen) if (runs[m] && split(seen[m], a, " ") > 2) print m }
  ' | sort -u
)"

# ---------------------------------------------------------------------------
# 3. Uncommitted work nobody is working on.
# ---------------------------------------------------------------------------
wip_rows=""
wip_fail=0
now_epoch="$(date +%s)"

for repo_path in "$REPOS_DIR"/*; do
  [ -d "$repo_path/.git" ] || continue
  repo="$(basename "$repo_path")"

  porcelain="$(git -C "$repo_path" status --porcelain 2>/dev/null)"
  [ -z "$porcelain" ] && continue

  # Modified TRACKED files are lost work. Untracked files are usually scratch.
  tracked="$(printf '%s\n' "$porcelain" | grep -vc '^??' || true)"
  untracked="$(printf '%s\n' "$porcelain" | grep -c '^??' || true)"

  # Freshness is judged from TRACKED files only. An untracked build artifact is
  # touched by every build, so letting it vote would let a `go build` mask
  # abandoned work indefinitely — which it did: scheduler's deploy rebuilt an
  # untracked `ask` binary, whose fresh mtime hid a 32-day-old modified
  # logging.go on this guard's very first run.
  newest=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in '??'*) continue ;; esac
    f="${line:3}"
    f="${f##* -> }"   # rename entries: "R  old -> new"
    p="$repo_path/$f"
    [ -e "$p" ] || continue
    m="$(stat -c %Y "$p" 2>/dev/null || echo 0)"
    [ "$m" -gt "$newest" ] && newest="$m"
  done <<<"$porcelain"

  age_hours=$(( (now_epoch - newest) / 3600 ))
  [ "$newest" -eq 0 ] && age_hours=0

  live=false
  repo_has_active_session "$repo_path" && live=true
  if [ "$newest" -gt 0 ] && [ $(( (now_epoch - newest) / 60 )) -lt "$FRESH_MINUTES" ]; then
    live=true   # touched minutes ago — an agent is almost certainly mid-edit
  fi

  status=ok
  if [ "$live" = true ]; then
    status=active
  elif [ "$tracked" -gt 0 ] && [ "$age_hours" -ge "$STALE_WIP_HOURS" ]; then
    status=stale-wip
    wip_fail=$((wip_fail + 1))
  elif [ "$tracked" -gt 0 ]; then
    status=recent-wip
  else
    status=untracked-only
  fi

  wip_rows="$wip_rows$repo	$status	$tracked	$untracked	$age_hours	$live"$'\n'
done

# ---------------------------------------------------------------------------
# 4. Report.
# ---------------------------------------------------------------------------
finished_epoch="$(date +%s)"

DRIFT_ROWS="$rows" WIP_ROWS="$wip_rows" GHOSTS="$ghosts" \
STARTED_AT="$started_at" \
MAX_BEHIND="$MAX_BEHIND" MAX_BEHIND_DAYS="$MAX_BEHIND_DAYS" STALE_WIP_HOURS="$STALE_WIP_HOURS" \
DRIFT_FAIL="$drift_fail" WIP_FAIL="$wip_fail" REPORT="$REPORT" \
python3 -c '
import json, os

def rows(env, fields):
    out = []
    for line in os.environ.get(env, "").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        parts += [""] * (len(fields) - len(parts))
        out.append(dict(zip(fields, parts)))
    return out

drift = rows("DRIFT_ROWS", ["repo", "artifact", "running", "status", "behind", "built_dirty", "detail"])
for d in drift:
    d["running"] = d["running"] == "true"
    d["built_dirty"] = d["built_dirty"] == "true"
    d["behind"] = int(d["behind"] or 0)

wip = rows("WIP_ROWS", ["repo", "status", "tracked_dirty", "untracked", "age_hours", "agent_active"])
for w in wip:
    w["agent_active"] = w["agent_active"] == "true"
    for k in ("tracked_dirty", "untracked", "age_hours"):
        w[k] = int(w[k] or 0)

ghosts = [g for g in os.environ.get("GHOSTS", "").split() if g]

report = {
    "mode": "deploy",
    "generated_at": os.environ["STARTED_AT"],
    "thresholds": {
        "max_behind": int(os.environ["MAX_BEHIND"]),
        "max_behind_days": int(os.environ["MAX_BEHIND_DAYS"]),
        "stale_wip_hours": int(os.environ["STALE_WIP_HOURS"]),
    },
    "artifacts_total": len(drift),
    "drift_failures": int(os.environ["DRIFT_FAIL"]),
    "wip_failures": int(os.environ["WIP_FAIL"]),
    # A stale artifact that is RUNNING is the real finding; an idle one on disk
    # is only a nuisance, so the gate keys on running.
    "stale_running": [d for d in drift if d["running"] and d["status"] in ("stale", "orphan-rev", "no-vcs")],
    "behind": [d for d in drift if d["status"] in ("behind", "stale")],
    "ghost_artifacts": ghosts,
    "stale_wip": [w for w in wip if w["status"] == "stale-wip"],
    "artifacts": drift,
    "worktrees": wip,
}
with open(os.environ["REPORT"], "w") as fh:
    json.dump(report, fh, indent=2)
    fh.write("\n")
'

echo
echo "deployed artifacts: $(printf '%s' "$rows" | grep -c . || true)   drift failures: $drift_fail   stale WIP: $wip_fail   ($(( finished_epoch - $(date -d "$started_at" +%s) ))s)"
echo "report: $REPORT"

[ "$drift_fail" -eq 0 ] && [ "$wip_fail" -eq 0 ]
