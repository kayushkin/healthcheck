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
        "parked_checkouts": [], "parked_failures": 0,
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
#
# One request per active state, filtered by the bridge: each answers bytes to a few
# KB. This used to fetch GET /sessions whole — every session with its info blob,
# 64 MB and 2.6 s on 2026-09-16 — under a 5-second timeout, so as the table grew the
# request would have started timing out and every repo would have looked idle.
ACTIVE_STATES="starting running model_generating tool_running compacting rate_limited"
active_dirs="$(
  for state in $ACTIVE_STATES; do
    curl -sfS -m 5 "$BRIDGE_URL/sessions?state=$state" 2>/dev/null
    echo
  done |
  python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        sessions = json.loads(line)
    except Exception:
        continue
    if isinstance(sessions, dict):
        sessions = sessions.get("sessions", [])
    for s in sessions or []:
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

# default_branch_ref <repo_path> — the ref drift is measured AGAINST.
#
# Until 2026-08-31 that ref was HEAD, and HEAD is whatever branch the last agent
# left checked out. That is the blind spot that shipped a regression: the
# llm-bridge-claudecode clone sat parked on a side branch forked BEFORE main
# gained the 2026-08-11 unprompted-turn fix, an agent hand-built and installed
# from the tree, and this guard read the binary as 0 behind — 0 behind the very
# stale branch it was built from. Measured that night: 0 behind HEAD, 4 behind
# main, and the missing commits included the fix users then re-hit all
# afternoon.
#
# So drift is measured against the repo's DEFAULT branch. Resolution order,
# each step taken only when the previous one names nothing (a resolution of one
# canonical ref, not a fallback chain inventing a value):
#   1. the branch origin/HEAD names — as a local ref if present, else the
#      remote-tracking ref;
#   2. a local `main`, then a local `master` — for the repos with no origin
#      remote at all (job-store, quote-store, prediction-store);
#   3. HEAD, the old behaviour, for a repo where none of those exist — and the
#      row says so, because the point is knowing which yardstick was used.
# Prints "<ref> <display name>" (space-separated; refs contain no spaces).
default_branch_ref() {
  local p="$1" name
  name="$(git -C "$p" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  name="${name#origin/}"
  if [ -n "$name" ]; then
    if git -C "$p" rev-parse --verify --quiet "refs/heads/$name" >/dev/null; then
      echo "refs/heads/$name $name"; return
    fi
    if git -C "$p" rev-parse --verify --quiet "refs/remotes/origin/$name" >/dev/null; then
      echo "refs/remotes/origin/$name origin/$name"; return
    fi
  fi
  for name in main master; do
    if git -C "$p" rev-parse --verify --quiet "refs/heads/$name" >/dev/null; then
      echo "refs/heads/$name $name"; return
    fi
  done
  echo "HEAD HEAD"
}

rows=""
drift_fail=0
regression_fail=0
regression_lines=""

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

  base_line="$(default_branch_ref "$repo_path")"
  base_ref="${base_line%% *}"
  base_name="${base_line#* }"
  rev_short="${rev:0:7}"
  behind="$(git -C "$repo_path" rev-list --count "$rev".."$base_ref" 2>/dev/null || echo 0)"
  detail=""
  status=ok

  if [ "$behind" -gt 0 ]; then
    oldest_epoch="$(git -C "$repo_path" log --format=%ct --reverse "$rev".."$base_ref" 2>/dev/null | head -1)"
    age_days=0
    [ -n "$oldest_epoch" ] && age_days=$(( ( $(date +%s) - oldest_epoch ) / 86400 ))
    detail="$behind commit(s) behind $base_name; oldest undeployed is ${age_days}d old"
    status=behind
    if [ "$behind" -ge "$MAX_BEHIND" ] || [ "$age_days" -ge "$MAX_BEHIND_DAYS" ]; then
      status=stale
      [ "$running" = true ] && drift_fail=$((drift_fail + 1))
    fi
  fi
  # REGRESSION CLASS — a running binary that was NOT BUILT FROM ITS DEFAULT
  # BRANCH: its commit is not an ancestor of main (a side-branch build), or it
  # was built dirty (vcs.modified=true, so its commit names only what it was
  # built NEAR). That is the shape of 2026-08-31 / 09-01 (a parked branch forked
  # before main's fix) and of the harness that ran a dirty feature-branch build
  # from 2026-09-02 to 09-10. It is NOT "behind main": nightly workers commit
  # scripts to every trunk daily, so being behind is the fleet's resting state
  # (20 of 26 running binaries the morning this was written) and a class that
  # red every day is one nobody reads. Counted separately, exits separately
  # (3), named on stdout, and carried as ONE standing noteboard todo.
  if [ "$running" = true ]; then
    on_default=true
    git -C "$repo_path" merge-base --is-ancestor "$rev" "$base_ref" 2>/dev/null || on_default=false
    if [ "$on_default" = false ] || [ "$dirty" = true ]; then
      regression_fail=$((regression_fail + 1))
      why=""
      [ "$on_default" = false ] && why="built from $rev_short, which is NOT on $base_name (a side-branch build)"
      [ "$dirty" = true ] && why="${why:+$why; }built DIRTY (vcs.modified=true — $rev_short is only where the tree was, not what it held)"
      regression_lines="$regression_lines$repo: running $bin — $why; missing $behind commit(s) of $base_name"$'\n'
    fi
  fi

  rows="$rows$repo	$bin	$main_pkg	$running	$status	$behind	$dirty	$detail"$'\n'
done <<<"$candidates"

# Ghost artifacts: one command, deployed to more than one path, and the copy you
# are looking at is not the copy that runs. Those idle copies are decoys — they
# mislead the next audit and the next human, so name them by path.
#
# Keyed on the main package (column 3), never the repo: a repo that ships ten
# commands is not ten ghosts of itself. That reasoning is right and is kept.
#
# ⚠️ But the main package is not always an identity, and for six months this
# read one particular non-identity as though it were. A binary built from an
# explicit file list (`go build a.go b.go`) carries no main package at all, and
# Go stamps the literal `command-line-arguments` in its place. That string is
# the ABSENCE of an identity, and every file-list-built binary on the box wears
# it. Keyed on directly, all of them collapse into one command, so a single
# running one turned every unrelated idle one into its ghost.
#
# Measured on the live fleet 2026-08-08, before this fix: 11 ghosts reported, of
# which `/usr/local/bin/mangastack-bin` and `/usr/local/bin/podcaststack-bin`
# were named as idle decoy copies of the running `~/bin/kayushkin-server`. They
# are three different programs — mangastack.go, podcaststack.go and the
# kayushkin.com server — sharing nothing but the placeholder.
#
# The fix is a substitute identity, not an exclusion, because one of those three
# WAS a genuine ghost: `/usr/local/bin/kayushkin-server` really is an idle copy
# of the running one, and dropping file-list binaries from the check wholesale
# would have thrown that true finding away with the two false ones. When Go
# recorded no main package, the deployed filename is the only identity left —
# and it is the identity a human is already using when they ask whether the same
# command sits in two places. It is strictly narrower than the placeholder: it
# separates mangastack-bin from podcaststack-bin while still matching
# kayushkin-server to kayushkin-server.
#
# The substitution is NAMED in the report (`ghost_identity_from_filename`), not
# applied silently, for the same reason `skipped_not_go` is named: a weaker
# identity being used for an artifact is exactly the kind of thing that should
# be visible when the next reader wonders why a ghost was or was not reported.
ghosts="$(
  printf '%s' "$rows" | awk -F'\t' '
    function identity(main_pkg, artifact,   seg, n) {
      # `?` is what the no-module row writes when even the placeholder is absent.
      if (main_pkg != "command-line-arguments" && main_pkg != "" && main_pkg != "?")
        return main_pkg
      n = split(artifact, seg, "/")
      return "file-list:" seg[n]
    }
    NF {
      key = identity($3, $2)
      copies[key]++
      if ($4 == "true") { runs[key] = 1 } else { idle[key] = idle[key] $2 "\n" }
    }
    END { for (pkg in runs) if (copies[pkg] > 1) printf "%s", idle[pkg] }
  ' | sort -u
)"

# The escape hatch, counted and named rather than merely taken — the rule this
# guard already applies to `skipped_not_go`. These are the artifacts whose ghost
# identity came from their filename because Go recorded no main package for them.
ghost_identity_from_filename="$(
  printf '%s' "$rows" | awk -F'\t' '
    NF && ($3 == "command-line-arguments" || $3 == "" || $3 == "?") { print $2 }
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
# 3b. Main clones parked off their default branch.
# ---------------------------------------------------------------------------
# The state that armed the 2026-08-31 llm-bridge-claudecode regression, checked
# directly rather than only through the binaries it eventually taints. A nightly
# agent checks a fix branch out IN THE MAIN CLONE, commits, and walks away; the
# clone then sits on that branch — measured that night: 42 of 83 clones — and
# every later `cd <repo> && go build` builds a tree that may be missing weeks of
# main. The drift check above catches the binary AFTER such a build is deployed;
# this catches the loaded gun before anything is built from it.
#
# A parked clone FAILS only when all three hold:
#   - its HEAD is missing commits the default branch has (`missing` > 0) — a
#     parked branch that contains all of the default is a landmine only once
#     the default moves, so it is reported but not failed;
#   - no active agent session has the repo as its working directory;
#   - the parked branch's last commit is older than PARKED_GRACE_HOURS — a
#     branch an agent committed to this afternoon is work in progress, not an
#     abandonment, even though the session that made it has ended.
parked_rows=""
parked_fail=0
PARKED_GRACE_HOURS="${PARKED_GRACE_HOURS:-24}"

for repo_path in "$REPOS_DIR"/*; do
  [ -d "$repo_path/.git" ] || continue
  repo="$(basename "$repo_path")"

  current="$(git -C "$repo_path" branch --show-current 2>/dev/null)"
  base_line="$(default_branch_ref "$repo_path")"
  base_ref="${base_line%% *}"
  base_name="${base_line#* }"

  # Detached HEAD ("" from --show-current) counts as parked too: a build from a
  # detached tree is just as untethered from main as one from a side branch.
  [ "$base_ref" = "HEAD" ] && continue   # no yardstick — nothing to compare against
  [ "$current" = "$base_name" ] && continue

  missing="$(git -C "$repo_path" rev-list --count HEAD.."$base_ref" 2>/dev/null || echo 0)"
  last_commit_epoch="$(git -C "$repo_path" log -1 --format=%ct 2>/dev/null || echo 0)"
  parked_hours=$(( ( $(date +%s) - last_commit_epoch ) / 3600 ))

  live=false
  repo_has_active_session "$repo_path" && live=true

  status=parked
  if [ "$missing" -gt 0 ] && [ "$live" = false ] && [ "$parked_hours" -ge "$PARKED_GRACE_HOURS" ]; then
    status=parked-stale
    parked_fail=$((parked_fail + 1))
    regression_fail=$((regression_fail + 1))
    regression_lines="$regression_lines$repo: main clone parked on ${current:-<detached>} for ${parked_hours}h, missing $missing commit(s) of $base_name — any build from it ships without them"$'\n'
  fi

  parked_rows="$parked_rows$repo	${current:-<detached>}	$base_name	$missing	$parked_hours	$live	$status"$'\n'
done

# ---------------------------------------------------------------------------
# 4. Report.
# ---------------------------------------------------------------------------
finished_epoch="$(date +%s)"

DRIFT_ROWS="$rows" WIP_ROWS="$wip_rows" GHOSTS="$ghosts" \
PARKED_ROWS="$parked_rows" PARKED_FAIL="$parked_fail" \
GHOST_IDENTITY_FROM_FILENAME="$ghost_identity_from_filename" \
STARTED_AT="$started_at" \
MAX_BEHIND="$MAX_BEHIND" MAX_BEHIND_DAYS="$MAX_BEHIND_DAYS" STALE_WIP_HOURS="$STALE_WIP_HOURS" \
DRIFT_FAIL="$drift_fail" WIP_FAIL="$wip_fail" REPORT="$REPORT" \
REGRESSION_FAIL="$regression_fail" REGRESSION_LINES="$regression_lines" \
PARKED_GRACE_HOURS="$PARKED_GRACE_HOURS" \
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
parked = rows("PARKED_ROWS", ["repo", "branch", "default_branch", "missing_from_default", "parked_hours", "agent_active", "status"])
for row in parked:
    row["agent_active"] = row["agent_active"] == "true"
    for k in ("missing_from_default", "parked_hours"):
        row[k] = int(row[k] or 0)
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

# Same line-splitting rule again, same reason: these are paths.
ghost_identity_from_filename = [
    g.strip()
    for g in os.environ.get("GHOST_IDENTITY_FROM_FILENAME", "").splitlines()
    if g.strip()
]

report = {
    "mode": "deploy",
    "generated_at": os.environ["STARTED_AT"],
    "thresholds": {
        "max_behind": int(os.environ["MAX_BEHIND"]),
        "max_behind_days": int(os.environ["MAX_BEHIND_DAYS"]),
        "stale_wip_hours": int(os.environ["STALE_WIP_HOURS"]),
        "parked_grace_hours": int(os.environ["PARKED_GRACE_HOURS"]),
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
    # Artifacts whose ghost identity had to be taken from their filename because
    # Go recorded no main package for them. Named so the weaker identity is
    # visible; no reader refuses a report for lacking this key, deliberately —
    # the live fleet report is written by a nightly job, and a refusal added here
    # would silence the real findings this guard already makes, until that job
    # next runs. (No apostrophes in this block: it is a single-quoted shell
    # string, and the header says so 500 lines above where you are reading.)
    "ghost_identity_from_filename": ghost_identity_from_filename,
    "stale_wip": [w for w in wip if w["status"] == "stale-wip"],
    # Main clones checked out on something other than their default branch. A
    # parked-stale row is a clone that would BUILD A REGRESSION today: its HEAD
    # is missing commits from the default branch, nobody is working in it, and
    # it has sat that way past the grace window. The 2026-08-31
    # llm-bridge-claudecode incident is the row shape this exists to catch.
    "parked_checkouts": parked,
    "parked_failures": int(os.environ["PARKED_FAIL"]),
    # The regression class, verbatim as printed: running binaries missing ANY
    # default-branch commit, plus parked-stale clones. Non-empty means exit 3.
    "regression_class": [l for l in os.environ["REGRESSION_LINES"].split("\n") if l.strip()],
    "regression_failures": int(os.environ["REGRESSION_FAIL"]),
    "artifacts": drift,
    "worktrees": wip,
}
with open(os.environ["REPORT"], "w") as fh:
    json.dump(report, fh, indent=2)
    fh.write("\n")
'

echo
echo "deployed artifacts: $(printf '%s' "$rows" | grep -c . || true) of $executables_scanned executables scanned (${#skipped_not_go[@]} not Go)   drift failures: $drift_fail   stale WIP: $wip_fail   parked clones: $parked_fail   ($(( finished_epoch - $(date -d "$started_at" +%s) ))s)"
echo "report: $REPORT"

if [ "$regression_fail" -gt 0 ]; then
  echo
  echo "REGRESSION CLASS ($regression_fail) — a running binary behind its default branch, or a parked-stale main clone:"
  printf '%s' "$regression_lines" | sed 's/^/    /'
  # One standing noteboard todo, tagged deploy-regression, rewritten in place so
  # the reminder-coordinator (the only thing that nudges) carries it; never a
  # second todo and never a cron nudge of its own. Due now, so it is overdue
  # from the first morning it exists.
  NOTEBOARD_URL="${NOTEBOARD_URL:-http://localhost:8191}"
  todo_title="⚠️ Deploy regression class: $regression_fail running-binary/parked-clone finding(s) — see body"
  todo_body="$(printf '%s\n\nWritten by repo-deploy-audit.sh at %s. Report: %s\n\n%s' "A running binary built from a commit not on its default branch or built dirty, or a main clone parked on a stale branch. Redeploy from main (or land/delete the branch); the audit rewrites this todo each morning and closes it the morning the class is empty." "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPORT" "$regression_lines")"
  existing_id="$(curl -sf "$NOTEBOARD_URL/api/items?type=todo&status=open&tag=deploy-regression&limit=5" 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get("items",[])
print(items[0]["id"] if items else "")' 2>/dev/null || true)"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"type":"todo","title":sys.argv[1],"body":sys.argv[2],"tags":["deploy-regression","ops"],"priority":1,"due_at":sys.argv[3]}))' "$todo_title" "$todo_body" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  if [ -n "$existing_id" ]; then
    curl -sf -X PATCH "$NOTEBOARD_URL/api/items/$existing_id" -H 'Content-Type: application/json' -d "$payload" >/dev/null \
      && echo "    noteboard todo $existing_id rewritten" || echo "    WARNING: could not rewrite noteboard todo $existing_id" >&2
  else
    new_id="$(curl -sf -X POST "$NOTEBOARD_URL/api/items" -H 'Content-Type: application/json' -d "$payload" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
    [ -n "$new_id" ] && echo "    noteboard todo $new_id filed" || echo "    WARNING: could not file the noteboard todo" >&2
  fi
  exit 3
fi

# Class empty: close the standing todo if one is open, so it is never stale.
NOTEBOARD_URL="${NOTEBOARD_URL:-http://localhost:8191}"
open_id="$(curl -sf "$NOTEBOARD_URL/api/items?type=todo&status=open&tag=deploy-regression&limit=5" 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get("items",[])
print(items[0]["id"] if items else "")' 2>/dev/null || true)"
if [ -n "$open_id" ]; then
  curl -sf -X PATCH "$NOTEBOARD_URL/api/items/$open_id" -H 'Content-Type: application/json' \
    -d "{\"status\":\"done\",\"body\":\"Closed by repo-deploy-audit.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ): the regression class is empty.\"}" >/dev/null \
    && echo "regression class empty — noteboard todo $open_id closed" || echo "WARNING: could not close noteboard todo $open_id" >&2
fi

[ "$drift_fail" -eq 0 ] && [ "$wip_fail" -eq 0 ] && [ "$parked_fail" -eq 0 ]
