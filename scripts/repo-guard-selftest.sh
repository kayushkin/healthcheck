#!/usr/bin/env bash
#
# repo-guard-selftest — pin the behaviour of this box's repo guards against
# fixtures, without touching ~/repos.
#
# It started as a test of one sweep's repository-discovery rules and grew, one
# finding at a time, to cover both sweep scripts (repo-build-audit.sh in its
# four modes, and repo-deploy-audit.sh) and all six status readers. Renamed
# 2026-08-08, when the deploy cases landed and the old name named one of the two
# scripts it tests. Nothing invokes this file but a human, so the rename cost
# only this comment — see the note about that at the foot of the file.
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
# Usage: scripts/repo-guard-selftest.sh     (exit 0 = all pinned)
#
# ⚠️ NOTHING RUNS THIS. Measured 2026-08-08: no scheduler job invokes it, and
# healthcheck's config.yaml declares no check for it, while the five guards it
# pins all run nightly under the scheduler. So every assertion here is a claim
# that is only true on the last day somebody typed the command. Tracked as its
# own todo rather than fixed in passing, because putting it on a schedule is a
# change to the cron fleet.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/repo-build-audit.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/repo-guard-selftest.XXXXXX")
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

# -------------------------------------------------------------- fixture CHECK
# The node mode's `check` stage: the package's own declared `check` script.
#
# Three packages, because the stage has three outcomes and only running all
# three proves it discriminates. A stage that runs nothing passes the "a broken
# check fails" assertion just as happily as one that runs everything, provided
# nothing else pins that a GOOD package stays green and a package with no check
# script is neither failed nor silently forgotten.
#
# Each fixture package installs with `npm ci` from a lockfile with no
# dependencies at all, so no stage here touches the network.
CHECKDIR="$ROOT/checks"
mkdir -p "$CHECKDIR"

# make_node_pkg <dir> <check script or ->
make_node_pkg() {
  local dir="$1" checkscript="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q .
  git -C "$dir" config user.email selftest@localhost
  git -C "$dir" config user.name selftest
  local name; name=$(basename "$dir")
  CHECK="$checkscript" NAME="$name" python3 -c '
import json, os, sys
scripts = {"build": "node -e \"0\""}
if os.environ["CHECK"] != "-":
    scripts["check"] = os.environ["CHECK"]
pkg = {"name": os.environ["NAME"], "version": "1.0.0", "private": True,
       "scripts": scripts}
sys.stdout.write(json.dumps(pkg, indent=2) + "\n")
' > "$dir/package.json"
  # A lockfile with no packages: npm ci accepts it and installs nothing, which
  # keeps the fixture offline and fast while still exercising the real install
  # stage rather than skipping it.
  NAME="$name" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "name": os.environ["NAME"], "version": "1.0.0", "lockfileVersion": 3,
    "requires": True,
    "packages": {"": {"name": os.environ["NAME"], "version": "1.0.0"}},
}, indent=2) + "\n")
' > "$dir/package-lock.json"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

# Prints a line the detail extractor is supposed to surface, then exits nonzero
# — the shape render-check.mjs actually fails in.
make_node_pkg "$CHECKDIR/redpkg" 'node -e "console.log(\"FAIL: render check tripped\"); process.exit(1)"'
make_node_pkg "$CHECKDIR/greenpkg" 'node -e "console.log(\"all checks pass\")"'
make_node_pkg "$CHECKDIR/nocheckpkg" -

if command -v npm >/dev/null 2>&1; then
  REPOS_DIR="$CHECKDIR" REPORT="$ROOT/check-node.json" bash "$AUDIT" --node >"$ROOT/check.out" 2>&1
  rc=$?

  check "node: a package whose declared check FAILS fails the sweep" "1" "$rc"
  check "node: the failure is attributed to the check stage, not the build" \
        "check" \
        "$(report_field "$ROOT/check-node.json" \
           '[f["stage"] for f in d["failures"] if f["repo"]=="redpkg"][0]')"
  # The detail line is the entire thing a human sees at 03:30, so pin that it
  # carries the check script's own message and not npm exit-code boilerplate.
  check "node: the detail carries the check script's own failure line" "yes" \
        "$(case "$(report_field "$ROOT/check-node.json" \
                  '[f["detail"] for f in d["failures"] if f["repo"]=="redpkg"][0]')" in
             *"FAIL: render check tripped"*) echo yes ;; *) echo no ;; esac)"
  check "node: exactly one package fails — a passing check is not collateral" \
        "1" "$(report_field "$ROOT/check-node.json" 'd["failed"]')"
  check "node: a package whose declared check PASSES stays ok" "ok" \
        "$(report_field "$ROOT/check-node.json" \
           '[r["status"] for r in d["results"] if r["repo"]=="greenpkg"][0]')"
  # Declaring no check script is not a failure — but it must not be silent
  # either, or an uncovered package reads as a covered one.
  check "node: a package with no check script is not failed for it" "ok" \
        "$(report_field "$ROOT/check-node.json" \
           '[r["status"] for r in d["results"] if r["repo"]=="nocheckpkg"][0]')"
  check "node: a package with no check script is named in without_check" \
        "nocheckpkg" \
        "$(report_field "$ROOT/check-node.json" '",".join(d["without_check"])')"
else
  echo "SKIP  node check-stage fixtures (npm is not on PATH)"
fi

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

# ------------------------------------------------- fixture DEPLOY NO TOOLCHAIN
# The same abort path in the OTHER sweep script. repo-deploy-audit.sh is a
# separate file with its own toolchain gate, and until 2026-08-08 that gate
# exited 2 without writing anything — so a missing go left the previous report
# on disk and repo-deploy-status.sh went on printing "ok: all 72 deployed
# artifacts match their committed HEAD" for a run that identified none of them.
# Measured against a real report before the fix: reader exit 0, green line.
#
# The two sweeps had drifted apart with nobody comparing them: the build family
# grew write_aborted_report, session-taxonomy-audit.sh grew it too, and deploy
# never did. Per-file review cannot see that; this fixture pins the parity.
#
# HOME is redirected as well as PATH because this sweep finds go by globbing
# $HOME/.local/share/mise/installs/go/*/bin directly, not through MISE_BIN.
# If a go still resolves (a host with /usr/local/go/bin), the sweep runs for
# real and writes no `aborted` — so the first check below goes red rather than
# passing vacuously.
DEPLOY_AUDIT="$HERE/repo-deploy-audit.sh"
mkdir -p "$ROOT/nohome" "$ROOT/nobin"
PATH="$STRIPPED" HOME="$ROOT/nohome" REPOS_DIR="$OKDIR" BIN_DIRS="$ROOT/nobin" \
  REPORT="$ROOT/deploy-notool.json" bash "$DEPLOY_AUDIT" >/dev/null 2>&1
check "deploy: a missing toolchain writes an aborted report" \
      "True" "$(report_field "$ROOT/deploy-notool.json" 'bool(d.get("aborted"))')"
check "deploy: the aborted report identifies no artifacts" \
      "0" "$(report_field "$ROOT/deploy-notool.json" 'd["artifacts_total"]')"
# Pinned because the reader checks mode FIRST. An aborted report stamped
# anything else is refused for its mode, the abort branch never runs, and every
# check below would pass with that branch deleted.
check "deploy: the aborted report is stamped mode=deploy, so the abort branch is reachable" \
      "deploy" "$(report_field "$ROOT/deploy-notool.json" 'd["mode"]')"

deploy_out=$(REPORT="$ROOT/deploy-notool.json" bash "$HERE/repo-deploy-status.sh" 2>&1)
deploy_rc=$?
check "status: an aborted deploy report fails BY NAME, not as staleness" \
      "1 yes" \
      "$deploy_rc $(case "$deploy_out" in
                      *"did not run"*"go is not on PATH"*) echo yes ;;
                      *) echo "no: $deploy_out" ;;
                    esac)"

# The other direction: the SAME report with the abort key removed must fail for
# a different, named reason. Without this, the check above passes just as well
# if the reader refuses every deploy report it is ever handed, and the abort
# branch would be proving nothing about aborts.
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("aborted")
json.dump(d, open(sys.argv[2], "w"), indent=2)
' "$ROOT/deploy-notool.json" "$ROOT/deploy-noabort.json"
noabort_out=$(REPORT="$ROOT/deploy-noabort.json" bash "$HERE/repo-deploy-status.sh" 2>&1)
noabort_rc=$?
check "status: with the abort key gone the same report fails for another reason — the branch is what catches it" \
      "1 yes" \
      "$noabort_rc $(case "$noabort_out" in
                       *"did not run"*) echo "no: $noabort_out" ;;
                       *"identified 0 deployed artifacts"*) echo yes ;;
                       *) echo "no: $noabort_out" ;;
                     esac)"

# ------------------------------------------------------------ fixture --only
# --only writes the SAME report path as a full sweep, so a filtered run used to
# be indistinguishable from a fleet one: `--only healthcheck` left repos_total=1,
# ok=1, failed=0 behind and every status reader called that a green fleet. It is
# the staleness bug wearing different clothes — a sweep that covered almost
# nothing looking exactly like one that passed — so it is refused the same way.
REPOS_DIR="$OKDIR" REPORT="$ROOT/only-build.json" bash "$AUDIT" --only alpha >/dev/null 2>&1
check "only: a filtered sweep records its filter in the report" \
      "alpha" "$(report_field "$ROOT/only-build.json" 'd["only"]')"
check "only: the filter really did narrow the sweep" \
      "1" "$(report_field "$ROOT/only-build.json" 'd["repos_total"]')"
only_out=$(REPORT="$ROOT/only-build.json" bash "$HERE/repo-build-audit-status.sh" 2>&1)
only_rc=$?
# Exit code and reason are pinned TOGETHER, deliberately. A bare exit-1 assertion
# proves nothing here: the alpha fixture also fails go vet, so this reader exits 1
# whether or not it noticed the filter. The first draft of this check did exactly
# that and went on passing with the refusal deleted.
check "status: a filtered report is refused BY NAME, not read as the fleet verdict" \
      "1 yes" \
      "$only_rc $(case "$only_out" in *"--only alpha"*) echo yes ;; *) echo "no: $only_out" ;; esac)"
# The other direction, so the check above cannot pass by refusing everything: an
# unfiltered sweep records only="" and is still read normally.
#
# Asserted as repr(d.get(...)) rather than d["only"], because report_field sends
# its own errors to /dev/null: a plain d["only"] on a report MISSING the key
# prints nothing, which compares equal to the empty string this is trying to
# prove is present. The first draft of this check passed that way and proved
# nothing.
check "only: a full sweep records an empty filter, and records it" \
      "''" "$(report_field "$ROOT/ok-smoke.json" 'repr(d.get("only", "ABSENT"))')"

# ------------------------------------------------------------- fixture MODE
# Each status reader picks its report by PATH. The sweep picks its mode from a
# flag and its path from REPORT=, independently, so the pairing can be wrong —
# and writing to your own REPORT= path is exactly what the --only finding above
# tells you to do when running a guard by hand. The four modes name their counts
# alike (repos_total, ok, failed, unguarded), so a mismatched pair did not error,
# it went GREEN over a run that measured something else: fed the elf report, the
# build reader announced "78/81 repos build from a clean clone of HEAD" for a
# sweep that compiled nothing. The elf reader fails the other way and names an
# innocent repo as carrying a committed binary.
#
# A full unfiltered build report, deliberately NOT only-build.json: that one
# carries only=alpha, so every reader refuses it for the FILTER and these checks
# would pass with the mode refusal deleted.
REPOS_DIR="$OKDIR" REPORT="$ROOT/ok-build.json" bash "$AUDIT" >/dev/null 2>&1
check "mode: a build sweep stamps its mode" \
      "build" "$(report_field "$ROOT/ok-build.json" 'd["mode"]')"
check "mode: the cross-feed fixture carries no filter, so only the mode can refuse it" \
      "''" "$(report_field "$ROOT/ok-build.json" 'repr(d.get("only", "ABSENT"))')"

# Exit code and reason are pinned TOGETHER for the same reason the --only checks
# are: these fixtures make several readers exit 1 on their own merits, so a bare
# exit-1 assertion would pass with the refusal deleted.
for reader_mode in "repo-node-status.sh:node:ok-build.json" \
                   "repo-deploy-status.sh:deploy:ok-build.json" \
                   "repo-build-audit-status.sh:build:ok-smoke.json" \
                   "repo-elf-status.sh:elf:ok-build.json"; do
  reader="${reader_mode%%:*}"; rest="${reader_mode#*:}"
  want="${rest%%:*}"; fixture="${rest#*:}"
  mode_out=$(REPORT="$ROOT/$fixture" bash "$HERE/$reader" 2>&1)
  mode_rc=$?
  check "mode: $reader refuses $fixture BY NAME instead of reading it as its own verdict" \
        "1 yes" \
        "$mode_rc $(case "$mode_out" in *"is not a"*"$want report"*) echo yes ;; *) echo "no: $mode_out" ;; esac)"
done

# The other direction, so the four checks above cannot pass by refusing
# everything. Asserted on the ABSENCE of the refusal rather than on exit 0,
# because the alpha fixture fails go vet and this reader exits 1 on its merits.
same_out=$(REPORT="$ROOT/ok-build.json" bash "$HERE/repo-build-audit-status.sh" 2>&1)
check "mode: a correctly paired report is NOT refused for its mode" \
      "no" \
      "$(case "$same_out" in *"is not a --build report"*) echo "yes: $same_out" ;; *) echo no ;; esac)"

# ---------------------------------------------------------- fixture COVERAGE
# What the sweep EXCLUDED, and whether the report says so.
#
# `repos_total` is not the number of directories the sweep looked at — it is
# what survived the filters. On the real box: 81 directories, --build judges 71,
# --smoke judges 61. Until 2026-08-08 the 10 and the 20 left no trace anywhere
# in the report, while every other exclusion in the same script was announced by
# name (worktrees, unguarded, no_smoke, without_check). Those two were the
# biggest and the only silent ones.
#
# It matters because coverage shrinks in the direction that looks healthy. A repo
# that loses its go.mod, or whose only `package main` moves somewhere uncommitted,
# just leaves the denominator — and `ok: N/N` prints exactly as before with a
# smaller N. There is no red state to notice.
#
# Four directories, one per route out of the sweep, so the identity below has
# something in every term instead of being satisfied by zeros.
COV="$ROOT/coverage"
mkdir -p "$COV"

# make_cov_repo <dir> <go.mod yes|no> <package main yes|no> <smoke port or ->
make_cov_repo() {
  local dir="$1" gomod="$2" main="$3" port="$4" base
  base="$(basename "$dir")"
  mkdir -p "$dir/scripts"
  git -C "$dir" init -q .
  git -C "$dir" config user.email selftest@localhost
  git -C "$dir" config user.name selftest
  [ "$gomod" = yes ] && printf 'module %s\n\ngo 1.22\n' "$base" > "$dir/go.mod"
  if [ "$main" = yes ]; then
    printf 'package main\n\nfunc main() {}\n' > "$dir/main.go"
  else
    printf 'package lib\n' > "$dir/lib.go"
  fi
  if [ "$port" != "-" ]; then
    {
      echo '#!/usr/bin/env bash'
      echo "PORT=\"\${E2E_$(echo "$base" | tr 'a-z-' 'A-Z_')_PORT:-$port}\""
      echo 'echo smoke'
    } > "$dir/scripts/e2e-smoke.sh"
    chmod +x "$dir/scripts/e2e-smoke.sh"
  fi
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

make_cov_repo "$COV/covmain" yes yes 19921   # judged by build AND smoke
make_cov_repo "$COV/covlib"  yes no  -       # go.mod, no main -> smoke excludes it
make_cov_repo "$COV/covnongo" no no  -       # no go.mod       -> build+smoke exclude it
git -C "$COV/covmain" worktree add -q --detach "$COV/covwt" HEAD

# identity <report> — directories_scanned minus everything the report accounts
# for. Zero means every directory left by a route the report names.
identity() {
  report_field "$1" \
    'd["directories_scanned"] - (d["repos_total"] + len(d["worktrees"])
     + len(d.get("without_go_mod") or []) + len(d.get("without_main_package") or [])
     + d["skipped_by_only"])'
}

REPOS_DIR="$COV" REPORT="$ROOT/cov-build.json" bash "$AUDIT" >/dev/null 2>&1
REPOS_DIR="$COV" REPORT="$ROOT/cov-smoke.json" bash "$AUDIT" --smoke >/dev/null 2>&1
REPOS_DIR="$COV" REPORT="$ROOT/cov-elf.json"   bash "$AUDIT" --elf   >/dev/null 2>&1

check "coverage: build counts every directory under the root, not just the judged ones" \
      "4" "$(report_field "$ROOT/cov-build.json" 'd["directories_scanned"]')"
check "coverage: build judges only the Go repositories" \
      "2" "$(report_field "$ROOT/cov-build.json" 'd["repos_total"]')"
# The assertion the whole section exists for. Naming it is what separates "this
# directory is out of scope" from "this directory silently stopped being covered",
# and the two are indistinguishable from repos_total alone.
check "coverage: build NAMES the directory it excluded for having no go.mod" \
      "covnongo" \
      "$(report_field "$ROOT/cov-build.json" '",".join(d["without_go_mod"])')"
check "coverage: the build accounting closes" "0" "$(identity "$ROOT/cov-build.json")"

check "coverage: smoke judges only repositories that ship a main package" \
      "1" "$(report_field "$ROOT/cov-smoke.json" 'd["repos_total"]')"
check "coverage: smoke NAMES the Go repository it excluded for shipping no main package" \
      "covlib" \
      "$(report_field "$ROOT/cov-smoke.json" '",".join(d["without_main_package"])')"
check "coverage: smoke still names the non-Go directory too" \
      "covnongo" \
      "$(report_field "$ROOT/cov-smoke.json" '",".join(d["without_go_mod"])')"
check "coverage: the smoke accounting closes" "0" "$(identity "$ROOT/cov-smoke.json")"

# elf filters on nothing but worktrees, so its denominator IS the directory
# count. Pinned because it is the one mode where the two numbers should agree,
# and an accounting bug that made every mode agree would otherwise look right.
check "coverage: elf judges every directory, so its two counts agree" \
      "3 4" \
      "$(report_field "$ROOT/cov-elf.json" 'str(d["repos_total"]) + " " + str(d["directories_scanned"])')"
check "coverage: the elf accounting closes" "0" "$(identity "$ROOT/cov-elf.json")"

# --only is the fourth route out of the sweep, and it has to be counted for the
# identity to be an invariant rather than a property of full sweeps only. If it
# were not, the reader could not tell a filtered sweep from a broken one — it
# would have to rely on the `only` refusal alone, which is a different check.
REPOS_DIR="$COV" REPORT="$ROOT/cov-only.json" bash "$AUDIT" --only covmain >/dev/null 2>&1
check "coverage: a filtered sweep counts what the filter excluded" \
      "2" "$(report_field "$ROOT/cov-only.json" 'd["skipped_by_only"]')"
check "coverage: the accounting closes for a filtered sweep too" \
      "0" "$(identity "$ROOT/cov-only.json")"

# --- and now the reader half: an unreconcilable report must be refused. ---
#
# Two separate refusals, sabotage-verified separately, because they fail for
# different reasons and one does not imply the other: a report can carry the
# accounting keys and still not add up.
python3 - "$ROOT/cov-build.json" "$ROOT/cov-nokeys.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["directories_scanned"]
json.dump(d, open(sys.argv[2], "w"))
PY
nokeys_out=$(REPORT="$ROOT/cov-nokeys.json" bash "$HERE/repo-build-audit-status.sh" 2>&1)
nokeys_rc=$?
check "coverage: the reader refuses a report with no coverage accounting at all" \
      "1 yes" \
      "$nokeys_rc $(case "$nokeys_out" in *"no coverage accounting"*) echo yes ;; *) echo "no: $nokeys_out" ;; esac)"

# Drop the excluded directory from the list while leaving the count alone: the
# exact shape of a sweep that grew a new way to skip something and did not
# record it. Every other field stays self-consistent, which is why nothing else
# in the reader catches it.
python3 - "$ROOT/cov-build.json" "$ROOT/cov-unbalanced.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["without_go_mod"] = []
json.dump(d, open(sys.argv[2], "w"))
PY
unbal_out=$(REPORT="$ROOT/cov-unbalanced.json" bash "$HERE/repo-build-audit-status.sh" 2>&1)
unbal_rc=$?
check "coverage: the reader refuses a report whose coverage does not reconcile" \
      "1 yes" \
      "$unbal_rc $(case "$unbal_out" in *"does not reconcile"*) echo yes ;; *) echo "no: $unbal_out" ;; esac)"

# And the converse, which is the assertion that keeps the two above honest: a
# report that DOES reconcile must still pass. A refusal that fires on everything
# is not a check, and both refusals above are satisfied by a reader that exits 1
# unconditionally.
good_out=$(REPORT="$ROOT/cov-build.json" bash "$HERE/repo-build-audit-status.sh" 2>&1)
good_rc=$?
check "coverage: a reconciling report is still accepted" \
      "0 yes" \
      "$good_rc $(case "$good_out" in ok:*) echo yes ;; *) echo "no: $good_out" ;; esac)"
# The coverage figure has to reach the line a human reads. The identity proves
# the numbers add up; it cannot tell that 71 was 72 last night, and only the
# printed pair makes that visible.
check "coverage: the reader prints the excluded directories, not just the judged ones" \
      "yes" \
      "$(case "$good_out" in *"2 of 4 directories"*) echo yes ;; *) echo "no: $good_out" ;; esac)"

# ------------------------------------------------------ fixture EMPTY SWEEP
# The sweep does not treat "discovered nothing" as a refusal. An empty repos root
# exits 0 and writes repos_total=0 with no `aborted` and no `only`, so every check
# the readers already carried passed in turn and they printed "ok: 0/0 repos build
# from a clean clone of HEAD" — green, fresh, self-consistent, covering nothing.
# It is the --only defect without the flag, and it needs no bug to reach: the root
# comes from REPOS_DIR, and this guard runs from a systemd unit whose Environment
# has already been wrong twice in this file's history.
EMPTY="$ROOT/empty-root"
mkdir -p "$EMPTY"
for mode_reader in ":build:repo-build-audit-status.sh" \
                   "--smoke:smoke:repo-smoke-status.sh" \
                   "--elf:elf:repo-elf-status.sh"; do
  flag="${mode_reader%%:*}"; rest="${mode_reader#*:}"
  tag="${rest%%:*}"; reader="${rest#*:}"
  # shellcheck disable=SC2086
  REPOS_DIR="$EMPTY" REPORT="$ROOT/empty-$tag.json" bash "$AUDIT" $flag >/dev/null 2>&1
  check "empty: a $tag sweep of an empty root judges nothing" \
        "0" "$(report_field "$ROOT/empty-$tag.json" 'd["ok"] + d["failed"]')"
  # `ok + failed` is deliberately NOT enough, and this pair is here because the
  # check above was green throughout the whole life of a real bug. Discovery
  # globbed "$REPOS_DIR"/*/ without nullglob, so an empty root yielded the
  # PATTERN as a directory name and --elf booked a repository literally called
  # `*` — as `unguarded`, which is counted by neither `ok` nor `failed`. The
  # denominator every reader prints said 1 while the assertion above said 0 and
  # both were reporting the same run. Pin the count the readers actually use,
  # and pin the name too: a future miscount that happens to land on zero would
  # slip past a bare total, and the name is what made the defect legible.
  check "empty: a $tag sweep counts no repository at all, not merely no verdict" \
        "0" "$(report_field "$ROOT/empty-$tag.json" 'd["repos_total"]')"
  check "empty: a $tag sweep invents no repository from the unexpanded glob" \
        "[]" "$(report_field "$ROOT/empty-$tag.json" '[r["repo"] for r in d.get("results") or []]')"
  # Pinned because it is the whole reason a count check is needed: if the sweep
  # DID record an abort here, the pre-existing abort check would already catch
  # this and the refusal below would be untestable dead code.
  check "empty: a $tag sweep records no abort, so only a count check can catch it" \
        "None" "$(report_field "$ROOT/empty-$tag.json" 'repr(d.get("aborted"))')"
  empty_out=$(REPORT="$ROOT/empty-$tag.json" bash "$HERE/$reader" 2>&1)
  empty_rc=$?
  check "empty: $reader refuses a sweep that judged nothing instead of calling it a clean fleet" \
        "1 yes" \
        "$empty_rc $(case "$empty_out" in *"judged 0 repositories"*) echo yes ;; *) echo "no: $empty_out" ;; esac)"
done

# --node needs npm, so it cannot ride the loop above. It gets its own gated case
# rather than none: the first draft left it out, and deleting the node refusal
# then changed nothing in this file — an assertion that only looks like one.
if command -v npm >/dev/null 2>&1; then
  REPOS_DIR="$EMPTY" REPORT="$ROOT/empty-node.json" bash "$AUDIT" --node >/dev/null 2>&1
  check "empty: a node sweep of an empty root judges nothing" \
        "0" "$(report_field "$ROOT/empty-node.json" 'd["ok"] + d["failed"]')"
  # Same pair as the loop above, but it is NOT the same assertion, and the
  # difference is written down because the first draft of this comment got it
  # wrong. The other three modes count directories, so an unexpanded glob
  # becomes a counted repository; node counts PACKAGES, emitted row by row from
  # `git ls-tree` against each candidate. A path that does not exist yields no
  # rows, so node contributes nothing whatever the glob does.
  #
  # Verified, not assumed: with nullglob removed AND node's `git -C rev-parse`
  # guard deleted, these two stayed green while the elf pair went red. So node
  # is immune structurally, not by the lucky ordering that saved build and
  # smoke. This pair is a regression pin on the count — it cannot detect the
  # `*` defect, and must not be cited as coverage for it.
  check "empty: a node sweep counts no package at all, not merely no verdict" \
        "0" "$(report_field "$ROOT/empty-node.json" 'd["repos_total"]')"
  check "empty: a node sweep invents no package from the unexpanded glob" \
        "[]" "$(report_field "$ROOT/empty-node.json" '[r["repo"] for r in d.get("results") or []]')"
  check "empty: a node sweep records no abort, so only a count check can catch it" \
        "None" "$(report_field "$ROOT/empty-node.json" 'repr(d.get("aborted"))')"
  empty_out=$(REPORT="$ROOT/empty-node.json" bash "$HERE/repo-node-status.sh" 2>&1)
  empty_rc=$?
  check "empty: repo-node-status.sh refuses a sweep that judged nothing instead of calling it a clean fleet" \
        "1 yes" \
        "$empty_rc $(case "$empty_out" in *"judged 0 packages"*) echo yes ;; *) echo "no: $empty_out" ;; esac)"
else
  echo "SKIP  node empty-sweep fixture (npm is not on PATH)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
