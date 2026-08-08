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
# What it CAN do is not be there at all, and that is the hole this script had
# for its whole life. `go build main.go sheets.go calendar.go` — a file list
# rather than a package — stamps the binary `path command-line-arguments` and
# writes no `mod` line and no vcs stamps. This script read "no mod line" as
# "not a Go binary" and skipped it in silence.
#
# Measured 2026-08-08: 4 such binaries were deployed on this box and 1 was
# RUNNING — ~/bin/kayushkin-server, the process answering the live site. It
# appeared in no report, in no count, and in no failure, and it had never once
# been checked for drift. Every other guard was green, so nothing anywhere
# suggested the live site's binary was unaudited.
#
# Two defects in series produced it, both now fixed in kayushkin.com: deploy.sh
# built a file list (so no module was stamped), and go.mod said `module gohome`,
# whose last segment matches no directory under ~/repos — so even a correctly
# stamped binary would have landed in `unmapped`, which is also not gated. The
# repair went in the package, not here; this script's own job was to stop
# calling an unidentifiable Go binary "not a Go binary". It now reports those as
# `no-module` and fails on them when they are running, exactly as it already did
# for `no-vcs`.
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
# Both are reported. An on-disk artifact that no process runs, when another
# artifact of the SAME COMMAND is running, is flagged as a ghost — that is the
# ~/bin/llm-bridge-server trap above, and naming it is how we stop re-walking
# into it.
#
# "Same command" means the main package path (`go version -m`'s `path` line),
# not the module and not the filename. Both of the other two are wrong here:
#
#   - the module holds many commands. scheduler ships ten, so keying ghosts on
#     the module called all ten a ghost of each other, every night.
#   - the filename differs across copies of one command. The three artifacts
#     built from cmd/llm-bridge-server are two called `llm-bridge` and one
#     called `llm-bridge-server`.
#
# The main package path separates the ten and unites the three. We report the
# idle copies by path, since the path is what you delete.
#
# What it does NOT compare, and how a reader can tell
# ----------------------------------------------------
# `artifacts_total` is the number of executables this sweep could IDENTIFY as Go
# binaries — not the number it looked at. That difference used to be invisible:
# measured 2026-08-08, 76 of 94 candidates were compared and the other 18 left
# through the "not a Go binary" hatch without appearing in any count, list or
# failure. `ok: all 76 deployed artifacts match their committed HEAD` was the
# whole story a reader ever got, and it reads as a statement about the box.
#
# Both halves are reported now — `executables_scanned` and `skipped_not_go` —
# and repo-deploy-status.sh refuses a report in which
#
#     executables_scanned != artifacts_total + len(skipped_not_go)
#
# because a candidate leaving by a route nothing records is precisely how this
# coverage shrinks without anything going red. Note that the candidate list
# includes the exe of every RUNNING process as well as the contents of BIN_DIRS,
# so the scanned count moves a little run to run; it is an identity to reconcile,
# not a constant to compare against last night.
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

started_at="$(date -Iseconds)"

# write_aborted_report <reason> — leave a report saying the sweep did not happen.
#
# This guard used to exit before writing anything, which left the PREVIOUS
# night's deploy-report.json untouched — and repo-deploy-status.sh reads that
# file. Measured 2026-08-08 on a real report: a run that identified nothing at
# all still printed "ok: all 72 deployed artifacts match their committed HEAD
# within 5 commits" and exited 0. Staleness eventually catches it, but only
# after MAX_AGE_HOURS=36, so the guard says nothing for a day and a half and
# then blames the wrong thing.
#
# A refusal to run is a verdict and gets written down like one. Both sibling
# guards already do this (repo-build-audit.sh, session-taxonomy-audit.sh); this
# one was the last that did not, and nothing compared them.
#
# The counts are zero and `aborted` carries the reason, so a check says what
# went wrong the same morning instead of a generic STALE the following
# afternoon. `thresholds` is deliberately absent: a reader that somehow gets
# past the abort branch then has no tolerance number to print, and this
# guard's reader already refuses a report that states none.
#
# Defined here, above the toolchain gate, because that gate is its caller.
write_aborted_report() {
  STARTED_AT="$started_at" REASON="$1" REPORT="$REPORT" python3 -c '
import json, os
with open(os.environ["REPORT"], "w") as fh:
    json.dump({
        "mode": "deploy",
        "generated_at": os.environ["STARTED_AT"],
        "aborted": os.environ["REASON"],
        "duration_seconds": 0,
        "artifacts_total": 0,
        "drift_failures": 0,
        "wip_failures": 0,
        "stale_running": [], "behind": [], "ghost_artifacts": [],
        "stale_wip": [], "artifacts": [], "worktrees": [],
    }, fh, indent=2)
    fh.write("\n")
'
  echo "report: $REPORT (sweep aborted)"
}

# Put the REAL go toolchain on PATH, not mise's shim — `go version -m` on a
# shim resolves the shim, not the binary we asked about.
for candidate in /usr/local/go/bin "$HOME/.local/share/mise/installs/go"/*/bin; do
  [ -x "$candidate/go" ] && { export PATH="$candidate:$PATH"; break; }
done

if ! command -v go >/dev/null 2>&1; then
  echo "FATAL: go is not on PATH — cannot audit anything" >&2
  write_aborted_report "go is not on PATH — no toolchain, nothing was audited"
  exit 2
fi

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

# artifact_meta <path> → "modpath<TAB>mainpkg<TAB>revision<TAB>modified",
# empty ONLY when the file is not a Go binary at all. mainpkg is what tells two
# commands of one module apart.
#
# modpath comes back EMPTY for a Go binary built from a file list
# (`go build a.go b.go`): Go stamps those `path command-line-arguments` and
# emits no `mod` line and no vcs stamps. That is a real, deployed Go binary we
# cannot identify — not a non-Go file — so it must be reported, never dropped.
# Keying "is this Go?" on the module line conflated the two and silently
# excluded ~/bin/kayushkin-server, the binary serving the live site, from every
# drift check this script performs. `seen` keys on the output existing instead.
artifact_meta() {
  go version -m "$1" 2>/dev/null | awk '
    { seen = 1 }
    $1 == "path"  { main_pkg = $2 }
    $1 == "mod"   { mod = $2 }
    $1 == "build" && $2 ~ /^vcs\.revision=/ { rev = substr($2, 14) }
    $1 == "build" && $2 ~ /^vcs\.modified=/ { mod_dirty = substr($2, 14) }
    END { if (seen) printf "%s\t%s\t%s\t%s", mod, main_pkg, rev, mod_dirty }
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

# Coverage accounting. `artifacts_total` is not the number of executables this
# sweep looked at — it is what survived the "is this Go?" filter, and until
# 2026-08-08 nothing anywhere said what the filter removed. The reader printed
# `all 76 deployed artifacts match their committed HEAD` and 17 executables had
# left without a trace.
#
# Counted INSIDE the loop, on the same line the loop considers a candidate,
# rather than as a separate `wc -l` over $candidates. The two would be equal
# today and could stop being equal after any edit to the loop head; a
# denominator that can disagree with the thing it is the denominator OF is the
# defect this accounting exists to catch, so it is not reintroduced here.
executables_scanned=0
# What left through the "not a Go binary" hatch, named rather than merely
# dropped. Full paths, not basenames: ~/bin/foo and /usr/local/bin/foo are two
# different artifacts, and the path is the thing you go and look at — the same
# reason `ghost_artifacts` records paths.
#
# The category claim this hatch makes is TRUE — measured 2026-08-08, all 17 are
# shell scripts, symlinks to .py, or third-party python. This is not a wrong
# comment being corrected. It is that a Go artifact which ever stopped emitting
# buildinfo would join them and vanish from the gate leaving no evidence, and
# that has already happened on this box in a different form: `no-module` is a
# branch the tenth pass had to add for ~/bin/kayushkin-server, the binary
# serving the live site, which this sweep could not see for its whole life.
skipped_not_go=()

while IFS= read -r bin; do
  [ -z "$bin" ] && continue
  executables_scanned=$((executables_scanned + 1))
  meta="$(artifact_meta "$bin")"
  if [ -z "$meta" ]; then
    # Not a Go binary at all — nothing to compare. Named, not dropped: "out of
    # scope" and "silently stopped being covered" are indistinguishable from
    # artifacts_total alone.
    skipped_not_go+=("$bin"); continue
  fi

  modpath="$(printf '%s' "$meta" | cut -f1)"
  main_pkg="$(printf '%s' "$meta" | cut -f2)"
  rev="$(printf '%s' "$meta" | cut -f3)"
  dirty="$(printf '%s' "$meta" | cut -f4)"

  running=false; is_running "$bin" && running=true

  if [ -z "$modpath" ]; then
    # A Go binary carrying no module path: built from an explicit file list, so
    # Go recorded neither where it came from nor which commit it was. Every
    # check below needs the module to find the repo, so none of them can run.
    # Reported and gated exactly like no-vcs, which is the same failure — we
    # cannot verify what is running — one step further along.
    rows="$rows-	$bin	${main_pkg:-?}	$running	no-module	0	$dirty	built from a file list (go build a.go b.go), so it carries no module path and no vcs.revision — cannot verify what it was built from"$'\n'
    [ "$running" = true ] && drift_fail=$((drift_fail + 1))
    continue
  fi

  repo="${modpath##*/}"
  repo_path="$REPOS_DIR/$repo"

  if [ ! -d "$repo_path/.git" ]; then
    rows="$rows$repo	$bin	$main_pkg	$running	unmapped	0	$dirty	no repo at $repo_path for module $modpath"$'\n'
    continue
  fi

  if [ -z "$rev" ]; then
    # Built with -buildvcs=false, or from a tarball. We cannot know what it is.
    rows="$rows$repo	$bin	$main_pkg	$running	no-vcs	0	$dirty	binary carries no vcs.revision — cannot verify what it was built from"$'\n'
    [ "$running" = true ] && drift_fail=$((drift_fail + 1))
    continue
  fi

  if ! git -C "$repo_path" cat-file -e "$rev^{commit}" 2>/dev/null; then
    # Built from a commit that no longer exists here: rebased away, or never
    # pushed. Unreproducible — you cannot rebuild what is running.
    rows="$rows$repo	$bin	$main_pkg	$running	orphan-rev	0	$dirty	built from ${rev:0:7}, which is not in this repo (rebased or never committed)"$'\n'
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

  rows="$rows$repo	$bin	$main_pkg	$running	$status	$behind	$dirty	$detail"$'\n'
done <<<"$candidates"

# Ghost artifacts: one command, deployed to more than one path, and the copy you
# are looking at is not the copy that runs. Those idle copies are decoys — they
# mislead the next audit and the next human, so name them by path.
#
# Keyed on the main package (column 3), never the repo: a repo that ships ten
# commands is not ten ghosts of itself.
ghosts="$(
  printf '%s' "$rows" | awk -F'\t' '
    NF {
      copies[$3]++
      if ($4 == "true") { runs[$3] = 1 } else { idle[$3] = idle[$3] $2 "\n" }
    }
    END { for (pkg in runs) if (copies[pkg] > 1) printf "%s", idle[pkg] }
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
EXECUTABLES_SCANNED="$executables_scanned" \
SKIPPED_NOT_GO="$(printf '%s\n' ${skipped_not_go+"${skipped_not_go[@]}"})" \
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

drift = rows("DRIFT_ROWS", ["repo", "artifact", "main_package", "running", "status", "behind", "built_dirty", "detail"])
for d in drift:
    d["running"] = d["running"] == "true"
    d["built_dirty"] = d["built_dirty"] == "true"
    d["behind"] = int(d["behind"] or 0)

wip = rows("WIP_ROWS", ["repo", "status", "tracked_dirty", "untracked", "age_hours", "agent_active"])
for w in wip:
    w["agent_active"] = w["agent_active"] == "true"
    for k in ("tracked_dirty", "untracked", "age_hours"):
        w[k] = int(w[k] or 0)

# Paths, one per line — split on lines, not on whitespace, so a path with a
# space in it stays one entry.
ghosts = [g.strip() for g in os.environ.get("GHOSTS", "").splitlines() if g.strip()]

# Split on lines for the same reason ghosts does: these are paths, and a path
# with a space in it must stay one entry.
skipped_not_go = [s.strip() for s in os.environ.get("SKIPPED_NOT_GO", "").splitlines() if s.strip()]

report = {
    "mode": "deploy",
    "generated_at": os.environ["STARTED_AT"],
    "thresholds": {
        "max_behind": int(os.environ["MAX_BEHIND"]),
        "max_behind_days": int(os.environ["MAX_BEHIND_DAYS"]),
        "stale_wip_hours": int(os.environ["STALE_WIP_HOURS"]),
    },
    # The coverage pair. `executables_scanned` is every candidate the drift loop
    # considered; `artifacts_total` is how many of them were Go binaries it could
    # compare. The reader closes
    #
    #     executables_scanned == artifacts_total + len(skipped_not_go)
    #
    # which holds structurally, not by luck: past the `skipped_not_go` hatch every
    # branch of that loop appends exactly one row before it continues.
    "executables_scanned": int(os.environ["EXECUTABLES_SCANNED"]),
    "artifacts_total": len(drift),
    "skipped_not_go": skipped_not_go,
    "drift_failures": int(os.environ["DRIFT_FAIL"]),
    "wip_failures": int(os.environ["WIP_FAIL"]),
    # A stale artifact that is RUNNING is the real finding; an idle one on disk
    # is only a nuisance, so the gate keys on running.
    "stale_running": [d for d in drift if d["running"] and d["status"] in ("stale", "orphan-rev", "no-vcs", "no-module")],
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
echo "deployed artifacts: $(printf '%s' "$rows" | grep -c . || true) of $executables_scanned executables scanned (${#skipped_not_go[@]} not Go)   drift failures: $drift_fail   stale WIP: $wip_fail   ($(( finished_epoch - $(date -d "$started_at" +%s) ))s)"
echo "report: $REPORT"

[ "$drift_fail" -eq 0 ] && [ "$wip_fail" -eq 0 ]
