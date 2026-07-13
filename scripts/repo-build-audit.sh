#!/usr/bin/env bash
#
# repo-build-audit — build every Go repo in ~/repos from a CLEAN CLONE of its
# committed HEAD, and report the ones that don't compile.
#
# Why this exists
# ---------------
# On 2026-07-12 a sweep found SEVEN repos whose committed tree did not build —
# three of them running production services. downloadstack had been broken for
# 3.5 months, serving from a binary that could no longer be rebuilt from its own
# source. Every one was the same shape: a rename or removal was finished in the
# source and a caller was left behind.
#
# Not one was noticed, because nothing ever built these repos from a clean
# checkout. A working tree builds for reasons that do not survive a fresh clone:
# stale build artifacts, sibling directories that happen to be present, and
# `-mod=mod` silently rewriting go.mod instead of failing. `git status` stays
# clean the whole time. **git status cannot see this class of bug** — only a
# clean clone can.
#
# So: clone the committed HEAD (never the working tree), resolve the relative
# `replace` siblings by cloning THEIR committed HEADs too, and build with
# DEFAULT flags. Anything else re-creates the blind spot this guard exists to
# close.
#
# What it runs, and what it deliberately does not
# -----------------------------------------------
#   go build ./...   compiles the package tree
#   go vet ./...     type-checks the TEST tree too, without executing it
#
# `go test ./...` is NOT part of the nightly gate (pass --with-tests to add it).
# vet already compiles test files, which is what catches this bug class; several
# repos' suites need live services or credentials, so gating on them would make
# the guard cry wolf nightly — and a guard everyone has learned to ignore is
# worse than no guard at all.
#
# Tier 2: --smoke
# ---------------
# Compiling is necessary and not sufficient. A repo can build green and still
# ship a DEAD binary: Go 1.22+ `http.ServeMux` panics on a conflicting route
# pattern at REGISTRATION time, so a route collision is invisible to the
# compiler and fatal at boot. That is not hypothetical — it is what agent-store
# `3876e8e` did to llm-bridge-server, across a repo boundary, without either
# repo changing a line of the other's code.
#
# `--smoke` answers the next question: does the committed HEAD still BOOT and
# ANSWER? For every repo whose HEAD ships an executable `scripts/e2e-smoke.sh`,
# it clones that HEAD, resolves the same relative-`replace` siblings, and runs
# the smoke from inside the clean clone. The convention IS the registration —
# there is no service list to keep in sync with reality, because a list is one
# more thing that can silently drift out of date.
#
# Smokes run with HOME redirected into a scratch directory (see run_smoke).
# A smoke that forgets to override its DB path must not be able to open the
# LIVE database of the service it is testing — an audit that can damage what it
# audits is worse than no audit.
#
# Consumed by scripts/repo-build-audit-status.sh and scripts/repo-smoke-status.sh,
# which healthcheck polls.

set -uo pipefail

MODE=build

REPOS_DIR="${REPOS_DIR:-$HOME/repos}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d /tmp/repo-build-audit.XXXXXX)}"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-600}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"
WITH_TESTS=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) MODE=smoke ;;
    --with-tests) WITH_TESTS=1 ;;
    --only) ONLY="${2:-}"; shift ;;
    --help|-h)
      sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# Each mode owns its own report. They run as separate scheduler jobs, and two
# jobs writing one file would race and clobber each other's verdict.
if [ "$MODE" = "smoke" ]; then
  REPORT="${REPORT:-$STATE_DIR/smoke-report.json}"
else
  REPORT="${REPORT:-$STATE_DIR/report.json}"
fi

mkdir -p "$STATE_DIR"
trap 'rm -rf "$WORK_ROOT"' EXIT

# Put the REAL go toolchain on PATH, not mise's shim.
#
# Two distinct failures hide here. The scheduler runs this from a systemd unit
# whose Environment sets only NATS_URL/SCHEDULER_PORT/HOME — no PATH at all — so
# go is not found and the guard dies every night with "go: not found", which the
# status check would then report as a STALE report rather than a broken build.
#
# But fixing that by prepending mise's shims is worse than useless: a shim re-reads
# mise config from the current working directory, and every clean clone lands on a
# fresh /tmp path that mise does not trust, so the shim REFUSES to exec go and the
# repo gets reported broken for a reason that has nothing to do with its code.
# kayushkin.com ships a mise.toml and failed exactly this way. Worse, it is
# invisible interactively, where a mise-activated shell already has the real binary
# on PATH — so the guard would pass by hand and fail nightly.
#
# Ask mise for the real toolchain binary and prepend THAT, shadowing any shim, so
# an interactive run and the nightly run resolve the same go. Falls back to whatever
# go is on PATH when mise is absent (e.g. a checkout on another host).
MISE_BIN="${MISE_BIN:-$HOME/.local/bin/mise}"
if [ -x "$MISE_BIN" ]; then
  mise_go="$("$MISE_BIN" which go 2>/dev/null)"
  [ -n "$mise_go" ] && export PATH="$(dirname "$mise_go"):$PATH"
fi
if ! command -v go >/dev/null 2>&1; then
  echo "FATAL: go is not on PATH — cannot audit anything" >&2
  exit 2
fi

# Default flags, deliberately. GOFLAGS could carry -mod=mod from the ambient
# environment, which masks go.mod drift by fixing it in place; GOWORK could
# paper over a missing dependency the same way a stray sibling directory does.
# Both are exactly the "it builds on my machine" mechanisms this guard defeats.
export GOFLAGS=
export GOWORK=off
export CGO_ENABLED="${CGO_ENABLED:-1}"

started_at=$(date --iso-8601=seconds)
start_epoch=$(date +%s)

# provision <name> <dest_parent> — materialise a repo at its committed HEAD.
# Prints "clone" if it came from a commit, "copy" if the repo is not under git
# and we had to fall back to its working tree (a weaker guarantee — the caller
# records that as "degraded", never as a pass).
provision() {
  # Assign separately: bash expands every word of a `local` line before it
  # performs any of the assignments, so `local name="$1" src="$REPOS_DIR/$name"`
  # would resolve $name against the CALLER's scope, silently cloning the wrong
  # repo into the right directory name.
  local name="$1"
  local parent="$2"
  local src="$REPOS_DIR/$name"
  [ -d "$parent/$name" ] && { echo "cached"; return 0; }
  [ -d "$src" ] || { echo "missing"; return 1; }
  if git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    git clone --quiet --local "$src" "$parent/$name" >/dev/null 2>&1 || { echo "clone-failed"; return 1; }
    echo "clone"
  else
    # Not a git repo (e.g. tool-store) — there is no committed HEAD to clone.
    cp -a "$src" "$parent/$name" || { echo "copy-failed"; return 1; }
    rm -rf "$parent/$name/node_modules"
    echo "copy"
  fi
}

# resolve_replaces <repo_dir> <workspace> — clone/copy every sibling named in a
# relative replace directive, recursively (a sibling has siblings of its own).
# Echoes the names of any siblings that had to be copied from a working tree.
resolve_replaces() {
  local dir="$1" ws="$2" sib
  local -a siblings
  mapfile -t siblings < <(
    cd "$dir" && go mod edit -json 2>/dev/null |
      python3 -c '
import json,sys
try: mod = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in mod.get("Replace") or []:
    p = (r.get("New") or {}).get("Path","")
    if p.startswith("../"):
        print(p[3:].strip("/"))
'
  )
  for sib in "${siblings[@]}"; do
    [ -n "$sib" ] || continue
    local how
    how=$(provision "$sib" "$ws")
    case "$how" in
      copy) echo "$sib" ;;              # degraded: working tree, not a commit
      cached) continue ;;               # already provisioned; don't recurse twice
      clone) ;;
      *) echo "!$sib" ;;                # unresolvable
    esac
    [ -d "$ws/$sib" ] && resolve_replaces "$ws/$sib" "$ws"
  done
}

run_stage() {  # run_stage <dir> <stage...> ; captures output into STAGE_OUT
  local dir="$1"; shift
  STAGE_OUT=$(cd "$dir" && timeout "$STAGE_TIMEOUT" nice -n 10 "$@" 2>&1)
  return $?
}

# The go caches live under the real HOME. Resolve them ONCE, before any smoke
# runs, so that redirecting HOME below cannot make every smoke re-download the
# whole module graph from the network — which would turn a nightly guard into a
# nightly outbound-traffic burst that fails whenever the proxy hiccups.
REAL_GOCACHE="$(go env GOCACHE)"
REAL_GOMODCACHE="$(go env GOMODCACHE)"
REAL_GOPATH="$(go env GOPATH)"

# smoke_status <repo_src> — is there a smoke to run, and can it actually run?
#   yes         HEAD ships scripts/e2e-smoke.sh, mode 100755
#   not-exec    HEAD ships it, but not executable — a FAILURE, see below
#   none        HEAD does not ship one
#
# Checked against HEAD, not the working tree, for the same reason the build is:
# a smoke that exists only on someone's disk guards nothing.
#
# not-exec is a hard failure rather than a skip. A non-executable smoke silently
# does not run, and a guard that silently does not run is indistinguishable from
# a guard that is passing — the precise equivalence that let a broken tree ship
# for three and a half months.
smoke_status() {
  local src="$1" line
  line=$(git -C "$src" ls-tree HEAD -- scripts/e2e-smoke.sh 2>/dev/null)
  [ -n "$line" ] || { echo none; return; }
  case "$line" in
    100755*) echo yes ;;
    *)       echo not-exec ;;
  esac
}

# check_port_collisions — no two smokes may declare the same default port.
#
# Smokes run SERIALLY, and for a long time that was taken to mean sharing a port
# was harmless. It is not. `kill` + `wait` reaps the process, but the kernel does
# not hand the listening socket back instantly — so the next smoke to bind the
# SAME number can lose the race and die with "address already in use". The result
# is a guard that fails a repo whose tree is perfectly fine, intermittently, at
# 03:30, which is precisely the kind of red that people learn to ignore.
#
# It happened: three separate batches of smokes were written months apart, each
# author picking port numbers from a hand-maintained list in a note, and the list
# went stale. Nine repos ended up sharing five ports before anything went red.
#
# So the registry is DERIVED from the smokes themselves rather than maintained by
# hand — the same reason the guard discovers smokes by convention instead of from
# a service list. A note can drift from reality; this cannot. Any two smokes that
# claim one port is a hard failure of the guard, reported before a single smoke
# runs, because the alternative is a flake that looks like a real regression.
#
# Read from HEAD, not the working tree, for the same reason everything else here
# is: the guard clones HEAD and runs THAT. A port fix sitting uncommitted on
# someone's disk would make this check pass while the clones still collide —
# the check would be guarding a file that never runs.
#
# Matches the established shape: `VAR="${E2E_SOMETHING:-19123}"`.
check_port_collisions() {
  local path name dupes
  dupes=$(
    for path in "$REPOS_DIR"/*/; do
      name=$(basename "$path")
      git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || continue
      git -C "$path" show HEAD:scripts/e2e-smoke.sh 2>/dev/null |
        grep -oE '^[A-Z_]+="\$\{E2E_[A-Z_]+:-[0-9]{4,5}\}"' |
        while IFS= read -r line; do
          printf '%s\t%s(%s)\n' "$(expr "$line" : '.*:-\([0-9]*\)}')" "$name" "${line%%=*}"
        done
    done | sort -n | awk -F'\t' '
      { owners[$1] = owners[$1] $2 " "; n[$1]++ }
      END { for (p in n) if (n[p] > 1) printf "  port %s claimed by: %s\n", p, owners[p] }
    ' | sort
  )
  [ -z "$dupes" ] && return 0
  echo "FAIL: two or more smokes declare the same default port." >&2
  echo "$dupes" >&2
  echo "" >&2
  echo "Smokes run serially, but a killed server does not release its listening" >&2
  echo "socket instantly — a shared port makes the guard fail intermittently on a" >&2
  echo "repo whose tree is fine. Give each smoke its own number." >&2
  return 1
}

# run_smoke <repo_dir> <scratch> — run the repo's own smoke from the clean clone.
#
# HOME points at a scratch directory that is thrown away afterwards. Every
# service here defaults its SQLite path to something under $HOME, so a smoke
# that forgets to override that path would otherwise open — and write to — the
# LIVE database of the very service it is testing, nightly, unattended. With
# HOME redirected, the worst such a bug can do is create a stray file in a temp
# directory. The go caches are passed through explicitly (above) because they
# are the one thing under HOME that a build legitimately needs.
run_smoke() {
  local dir="$1" scratch="$2"
  mkdir -p "$scratch/home"
  STAGE_OUT=$(cd "$dir" && timeout "$SMOKE_TIMEOUT" nice -n 10 \
    env \
      HOME="$scratch/home" \
      XDG_CONFIG_HOME="$scratch/home/.config" \
      XDG_STATE_HOME="$scratch/home/.local/state" \
      XDG_DATA_HOME="$scratch/home/.local/share" \
      XDG_CACHE_HOME="$scratch/home/.cache" \
      GOCACHE="$REAL_GOCACHE" \
      GOMODCACHE="$REAL_GOMODCACHE" \
      GOPATH="$REAL_GOPATH" \
      GOFLAGS= GOWORK=off \
      PATH="$PATH" \
      ./scripts/e2e-smoke.sh 2>&1)
  return $?
}

# Fail fast, before any smoke boots: two smokes on one port make the guard flaky,
# and a flaky guard is worse than no guard. See check_port_collisions.
if [ "$MODE" = "smoke" ] && ! check_port_collisions; then
  exit 1
fi

results=()   # name<TAB>status<TAB>stage<TAB>seconds<TAB>detail
total=0; ok=0; failed=0; unguarded=0
no_smoke=0   # smoke mode only: repos with a committed HEAD but no smoke to run

for path in "$REPOS_DIR"/*/; do
  name=$(basename "$path")
  [ -f "$path/go.mod" ] || continue
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue

  if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    # No committed HEAD exists, so there is nothing for this guard to verify.
    # Report it rather than passing it silently: an unguarded repo is precisely
    # where the next 3.5-month break will live.
    total=$((total + 1))
    results+=("$name	unguarded	-	0	not a git repo — no committed HEAD to build")
    unguarded=$((unguarded + 1))
    echo "UNGUARDED $name (not a git repo)"
    continue
  fi

  if [ "$MODE" = "smoke" ]; then
    # A repo with no main package produces no binary, so there is nothing to
    # boot and it is out of scope — not a coverage gap. Asked of HEAD, not the
    # working tree, and answered without the go toolchain so that the coverage
    # count costs nothing.
    git -C "$path" grep -qE '^package main$' HEAD -- '*.go' 2>/dev/null || continue
    total=$((total + 1))

    case "$(smoke_status "$path")" in
      none)
        no_smoke=$((no_smoke + 1))
        results+=("$name	no-smoke	-	0	HEAD ships no scripts/e2e-smoke.sh — this binary is never booted by the guard")
        echo "NO-SMOKE  $name"
        continue ;;
      not-exec)
        failed=$((failed + 1))
        results+=("$name	fail	mode	0	scripts/e2e-smoke.sh is committed non-executable (mode is not 100755), so it would silently never run")
        echo "FAIL      $name — scripts/e2e-smoke.sh committed non-executable"
        continue ;;
    esac
  else
    total=$((total + 1))
  fi

  ws="$WORK_ROOT/$name"
  mkdir -p "$ws"
  repo_start=$(date +%s)

  how=$(provision "$name" "$ws")
  if [ "$how" != "clone" ]; then
    results+=("$name	fail	clone	0	could not clone committed HEAD: $how")
    failed=$((failed + 1)); echo "FAIL      $name (clone: $how)"
    rm -rf "$ws"; continue
  fi

  degraded=$(resolve_replaces "$ws/$name" "$ws" | tr '\n' ' ' | sed 's/ *$//')

  status="ok"; stage="-"; detail=""

  if [ "$MODE" = "smoke" ]; then
    # The workspace deliberately mirrors ~/repos: the repo sits at $ws/$name and
    # its replace-siblings sit beside it at $ws/<sibling>. A smoke that reaches
    # for a sibling the way llm-bridge-server's does — $(dirname $REPO_DIR)/log-store
    # — therefore resolves to the sibling's CLEAN CLONE, not to a working tree.
    run_smoke "$ws/$name" "$ws"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      status="fail"; stage="smoke"
      detail=$(echo "$STAGE_OUT" | grep -vE '^\s*$' | tail -8 | tr '\n' ' ' | cut -c1-500)
      [ "$rc" -eq 124 ] && detail="smoke timed out after ${SMOKE_TIMEOUT}s"
    fi

    secs=$(( $(date +%s) - repo_start ))
    if [ "$status" = "ok" ]; then
      ok=$((ok + 1))
      # A hermetic smoke writes nothing under HOME. One that does still passes —
      # it is not a broken binary — but it is one missing override away from
      # having written to the LIVE database instead, so say so out loud.
      #
      # The go toolchain's own footprint is excluded: it plants .config/go and
      # .cache under whatever HOME it is handed, no matter what the smoke does.
      # Reporting that would mark every repo non-hermetic, and a warning that
      # fires on everything says nothing.
      strays=$(find "$ws/home" -mindepth 1 -maxdepth 3 \
        -not -path "$ws/home/.cache*" \
        -not -path "$ws/home/.config" \
        -not -path "$ws/home/.config/go*" \
        2>/dev/null | head -3 | tr '\n' ' ')
      [ -n "$strays" ] && detail="not hermetic — wrote under HOME: $strays"
      echo "OK        $name (${secs}s)${detail:+  [$detail]}"
    else
      failed=$((failed + 1))
      echo "FAIL      $name — smoke: $detail"
    fi
    results+=("$name	$status	$stage	$secs	$detail")
    rm -rf "$ws"
    continue
  fi

  # The two `go build` invocations have opposite failure modes, so choose per repo:
  #
  #   go build ./...          drops each main package's binary into the CURRENT
  #                           directory, named after the package. dash and llmux
  #                           both keep their main package in server/, so the write
  #                           collides with that very directory — `build output
  #                           "server" already exists and is a directory`.
  #   go build -o DIR/ ./...  sends binaries elsewhere, but REFUSES a tree with no
  #                           main package at all — `no main packages to build` —
  #                           which is most of the store/bridge libraries here.
  #
  # Neither is a defect in the tree; both repos compile and vet clean. A guard that
  # reports either as a break is crying wolf, and its own verdict stops being read.
  outdir="$ws/.build-out"
  mkdir -p "$outdir"

  stages=(build vet)
  [ "$WITH_TESTS" -eq 1 ] && stages+=(test)
  for s in "${stages[@]}"; do
    if [ "$s" = "build" ]; then
      # If go list can't resolve the tree, it prints nothing and we fall through to
      # plain `go build`, which surfaces the real dependency error rather than hiding
      # it behind "no main packages".
      if (cd "$ws/$name" && go list -f '{{.Name}}' ./... 2>/dev/null | grep -qx main); then
        run_stage "$ws/$name" go build -o "$outdir/" ./...
      else
        run_stage "$ws/$name" go build ./...
      fi
    else
      run_stage "$ws/$name" go "$s" ./...
    fi
    # Capture rc directly. Reading $? inside `if ! run_stage ...; then` yields the
    # status of the negation (always 0), so the timeout branch below could never fire.
    rc=$?
    if [ "$rc" -ne 0 ]; then
      status="fail"; stage="$s"
      detail=$(echo "$STAGE_OUT" | grep -v '^#' | grep -v '^$' | head -6 | tr '\n' ' ' | cut -c1-500)
      [ "$rc" -eq 124 ] && detail="timed out after ${STAGE_TIMEOUT}s"
      break
    fi
  done

  secs=$(( $(date +%s) - repo_start ))
  if [ "$status" = "ok" ]; then
    ok=$((ok + 1))
    [ -n "$degraded" ] && detail="verified against working-tree copies of: $degraded"
    echo "OK        $name (${secs}s)${degraded:+  [degraded: $degraded]}"
  else
    failed=$((failed + 1))
    echo "FAIL      $name — go $stage: $detail"
  fi
  results+=("$name	$status	$stage	$secs	$detail")
  rm -rf "$ws"   # reclaim as we go; the box runs tight on disk-backed tmp
done

finished_epoch=$(date +%s)

printf '%s\n' "${results[@]}" |
  STARTED_AT="$started_at" \
  DURATION=$((finished_epoch - start_epoch)) \
  GO_VERSION="$(go env GOVERSION)" \
  WITH_TESTS="$WITH_TESTS" \
  MODE="$MODE" \
  TOTAL="$total" OK="$ok" FAILED="$failed" UNGUARDED="$unguarded" NO_SMOKE="$no_smoke" \
  REPORT="$REPORT" \
  python3 -c '
import json, os, sys
rows = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    name, status, stage, secs, *rest = line.split("\t")
    rows.append({
        "repo": name, "status": status, "stage": stage,
        "seconds": int(secs), "detail": rest[0] if rest else "",
    })
mode = os.environ["MODE"]
report = {
    "mode": mode,
    "generated_at": os.environ["STARTED_AT"],
    "duration_seconds": int(os.environ["DURATION"]),
    "go_version": os.environ["GO_VERSION"],
    "repos_total": int(os.environ["TOTAL"]),
    "ok": int(os.environ["OK"]),
    "failed": int(os.environ["FAILED"]),
    "failures": [r for r in rows if r["status"] == "fail"],
    "results": rows,
}
if mode == "smoke":
    # repos_total counts only repos that BUILD A BINARY — a library has nothing
    # to boot, so counting it would make coverage look worse than it is.
    report["no_smoke"] = int(os.environ["NO_SMOKE"])
    report["without_smoke"] = [r["repo"] for r in rows if r["status"] == "no-smoke"]
else:
    report["with_tests"] = os.environ["WITH_TESTS"] == "1"
    report["unguarded"] = int(os.environ["UNGUARDED"])
with open(os.environ["REPORT"], "w") as fh:
    json.dump(report, fh, indent=2)
    fh.write("\n")
'

echo
if [ "$MODE" = "smoke" ]; then
  echo "$ok/$total binaries boot and answer from a clean clone of HEAD; $failed failing, $no_smoke with no smoke to run ($(( finished_epoch - start_epoch ))s)"
else
  echo "$ok/$total build from a clean clone of HEAD; $failed failing, $unguarded unguarded ($(( finished_epoch - start_epoch ))s)"
fi
echo "report: $REPORT"

[ "$failed" -eq 0 ]
