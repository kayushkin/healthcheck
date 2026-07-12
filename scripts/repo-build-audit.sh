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
# Consumed by scripts/repo-build-audit-status.sh, which healthcheck polls.

set -uo pipefail

REPOS_DIR="${REPOS_DIR:-$HOME/repos}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/repo-build-audit}"
REPORT="${REPORT:-$STATE_DIR/report.json}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d /tmp/repo-build-audit.XXXXXX)}"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-600}"
WITH_TESTS=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --with-tests) WITH_TESTS=1 ;;
    --only) ONLY="${2:-}"; shift ;;
    --help|-h)
      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

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

results=()   # name<TAB>status<TAB>stage<TAB>seconds<TAB>detail
total=0; ok=0; failed=0; unguarded=0

for path in "$REPOS_DIR"/*/; do
  name=$(basename "$path")
  [ -f "$path/go.mod" ] || continue
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  total=$((total + 1))

  if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    # No committed HEAD exists, so there is nothing for this guard to verify.
    # Report it rather than passing it silently: an unguarded repo is precisely
    # where the next 3.5-month break will live.
    results+=("$name	unguarded	-	0	not a git repo — no committed HEAD to build")
    unguarded=$((unguarded + 1))
    echo "UNGUARDED $name (not a git repo)"
    continue
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
  TOTAL="$total" OK="$ok" FAILED="$failed" UNGUARDED="$unguarded" \
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
report = {
    "generated_at": os.environ["STARTED_AT"],
    "duration_seconds": int(os.environ["DURATION"]),
    "go_version": os.environ["GO_VERSION"],
    "with_tests": os.environ["WITH_TESTS"] == "1",
    "repos_total": int(os.environ["TOTAL"]),
    "ok": int(os.environ["OK"]),
    "failed": int(os.environ["FAILED"]),
    "unguarded": int(os.environ["UNGUARDED"]),
    "failures": [r for r in rows if r["status"] == "fail"],
    "results": rows,
}
with open(os.environ["REPORT"], "w") as fh:
    json.dump(report, fh, indent=2)
    fh.write("\n")
'

echo
echo "$ok/$total build from a clean clone of HEAD; $failed failing, $unguarded unguarded ($(( finished_epoch - start_epoch ))s)"
echo "report: $REPORT"

[ "$failed" -eq 0 ]
