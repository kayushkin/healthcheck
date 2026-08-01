#!/usr/bin/env bash
#
# repo-build-audit-selftest — pin the repository-discovery rules of
# repo-build-audit.sh against fixtures, without touching ~/repos.
#
# The sweep decides what a repository IS by looping over the directories under
# the repos root, and that decision had no test at all. It cost a full night of
# coverage: `git worktree add` — the workflow this box's own todos prescribe —
# leaves a sibling directory that answers `rev-parse --git-dir` like a real repo,
# so the worktree was swept as one. In smoke mode that is fatal rather than
# merely wasteful, because a worktree ships its parent's committed smoke and the
# derived port registry then sees two claims on one number. On 2026-08-01 the
# 03:30 run died in one second, all 61 smokes went unrun, and smoke-report.json
# kept the previous night's verdict.
#
# Each fixture is a throwaway git repository under a temp directory, so REPOS_DIR
# points somewhere harmless and no clone, build or smoke of a real repo happens.
#
# The two halves are equally load-bearing:
#   - a linked worktree must NOT be swept (the bug),
#   - two INDEPENDENT repos on one port must STILL abort the sweep (the check the
#     fix must not have disarmed — an "is not counted" assertion is trivially
#     satisfied by counting nothing).
#
# Usage: scripts/repo-build-audit-selftest.sh     (exit 0 = all pinned)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/repo-build-audit.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/repo-build-audit-selftest.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0

check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); echo "PASS  $1"
  else
    fail=$((fail + 1)); echo "FAIL  $1 — expected [$2], got [$3]"
  fi
}

# make_repo <dir> <smoke port or ->  — a minimal repo with a committed HEAD.
make_repo() {
  local dir="$1" port="$2"
  mkdir -p "$dir/scripts"
  git -C "$dir" init -q .
  git -C "$dir" config user.email selftest@localhost
  git -C "$dir" config user.name selftest
  printf 'module %s\n\ngo 1.22\n' "$(basename "$dir")" > "$dir/go.mod"
  printf '{"name":"%s","version":"1.0.0"}\n' "$(basename "$dir")" > "$dir/package.json"
  if [ "$port" != "-" ]; then
    {
      echo '#!/usr/bin/env bash'
      echo "PORT=\"\${E2E_$(basename "$dir" | tr 'a-z-' 'A-Z_')_PORT:-$port}\""
      echo 'echo smoke'
    } > "$dir/scripts/e2e-smoke.sh"
    chmod +x "$dir/scripts/e2e-smoke.sh"
  fi
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

report_field() {  # report_field <json> <python expression over `d`>
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null
}

# ---------------------------------------------------------------- fixture WT
# One repository plus a linked worktree of it, the shape a worker leaves behind.
WT="$ROOT/with-worktree"
mkdir -p "$WT"
make_repo "$WT/alpha" 19901
# Named so it looks nothing like a worktree: the rule under test is
# structural (git's own per-worktree vs common git dir), and a name
# heuristic on "*-workdir" would pass a fixture that spelled it that way.
git -C "$WT/alpha" worktree add -q --detach "$WT/zeta" HEAD

run_wt() {  # run_wt <mode flag or ""> <report path>
  REPOS_DIR="$WT" REPORT="$2" bash "$AUDIT" ${1:+"$1"} >"$ROOT/out.$$" 2>&1
  echo $?
}

rc=$(run_wt --smoke "$ROOT/wt-smoke.json")
check "smoke: a linked worktree does not abort the sweep" "0" "$rc"
check "smoke: the worktree is not counted as a repo" \
      "0" "$(report_field "$ROOT/wt-smoke.json" 'd["repos_total"]')"
check "smoke: the report names the skipped worktree" \
      "zeta" \
      "$(report_field "$ROOT/wt-smoke.json" 'd["worktrees"][0]["dir"]')"
check "smoke: the report names the repository it belongs to" \
      "$WT/alpha" \
      "$(report_field "$ROOT/wt-smoke.json" 'd["worktrees"][0]["repository"]')"

run_wt --elf "$ROOT/wt-elf.json" >/dev/null
check "elf: the worktree is not scanned as a second repo" \
      "1" "$(report_field "$ROOT/wt-elf.json" 'd["repos_total"]')"

run_wt "" "$ROOT/wt-build.json" >/dev/null
check "build: the worktree is not built as a second repo" \
      "1" "$(report_field "$ROOT/wt-build.json" 'd["repos_total"]')"

run_wt --node "$ROOT/wt-node.json" >/dev/null
check "node: the worktree's package.json is not counted twice" \
      "1" "$(report_field "$ROOT/wt-node.json" 'd["packages_total"]')"

# ------------------------------------------------------------- fixture CLASH
# Two INDEPENDENT repositories claiming one port. This is what the port registry
# exists to catch, and skipping worktrees must not have weakened it.
CLASH="$ROOT/with-clash"
mkdir -p "$CLASH"
make_repo "$CLASH/alpha" 19901
make_repo "$CLASH/beta" 19901

REPOS_DIR="$CLASH" REPORT="$ROOT/clash-smoke.json" bash "$AUDIT" --smoke >"$ROOT/clash.out" 2>&1
rc=$?
check "smoke: two independent repos on one port still abort the sweep" "1" "$rc"
check "smoke: the abort names both claimants" "alpha beta" \
      "$(grep -oE 'alpha\(PORT\) beta\(PORT\)' "$ROOT/clash.out" | sed 's/(PORT)//g')"

# An abort must overwrite the report, not leave the previous verdict standing.
# The counts are what a reader trusts, so they have to read as "nothing checked".
check "smoke: an aborted sweep writes a report saying so" \
      "True" "$(report_field "$ROOT/clash-smoke.json" 'bool(d.get("aborted"))')"
check "smoke: an aborted sweep reports no repos checked" \
      "0" "$(report_field "$ROOT/clash-smoke.json" 'd["repos_total"]')"

# ...and the status script must refuse it, rather than reading zero failures as
# health. This is the assertion that connects the two files: a report nobody
# rejects is the same as no report at all.
status_out=$(REPORT="$ROOT/clash-smoke.json" bash "$HERE/repo-smoke-status.sh" 2>&1)
check "status: an aborted report fails the check" "1" "$?"
check "status: the failure names the reason, not staleness" "yes" \
      "$(case "$status_out" in *"did not run"*"same default port"*) echo yes ;; *) echo "no: $status_out" ;; esac)"

# ---------------------------------------------------------- fixture DISTINCT
# Two independent repositories on different ports: nothing to complain about.
OKDIR="$ROOT/distinct"
mkdir -p "$OKDIR"
make_repo "$OKDIR/alpha" 19901
make_repo "$OKDIR/beta" 19902

REPOS_DIR="$OKDIR" REPORT="$ROOT/ok-smoke.json" bash "$AUDIT" --smoke >/dev/null 2>&1
check "smoke: distinct ports carry no worktree entries" \
      "0" "$(report_field "$ROOT/ok-smoke.json" 'len(d["worktrees"])')"

# ------------------------------------------------------- fixture NO TOOLCHAIN
# The other abort path, and the one the script's own comments already named: a
# --node run from the scheduler's empty environment finds no npm and exits 2.
# That used to leave the previous night's report in place, so repo-node-status.sh
# went on reporting a healthy build count for a sweep that never started.
STRIPPED="$ROOT/bin"
mkdir -p "$STRIPPED"
for c in bash sh git python3 date mktemp basename dirname awk sed grep sort tr cat rm mkdir printf timeout nice; do
  real=$(command -v "$c") && ln -sf "$real" "$STRIPPED/$c"
done

PATH="$STRIPPED" MISE_BIN=/nonexistent REPOS_DIR="$OKDIR" REPORT="$ROOT/notool.json" \
  bash "$AUDIT" --node >/dev/null 2>&1
check "node: a missing toolchain writes an aborted report" \
      "True" "$(report_field "$ROOT/notool.json" 'bool(d.get("aborted"))')"
status_out=$(REPORT="$ROOT/notool.json" bash "$HERE/repo-node-status.sh" 2>&1)
check "status: a missing toolchain fails the check" "1" "$?"
check "status: the failure names the toolchain" "yes" \
      "$(case "$status_out" in *"npm is not on PATH"*) echo yes ;; *) echo "no: $status_out" ;; esac)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
