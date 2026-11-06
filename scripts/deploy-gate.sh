#!/usr/bin/env bash
#
# deploy-gate — the one check every deploy.sh runs before it builds, and the one
# record it writes after it ships. Installed as ~/bin/deploy-gate.
#
#   deploy-gate check     run first, from the repo. Exits 1 and names every
#                         reason when the tree is not fit to deploy from.
#   deploy-gate record    run last, after the service is up. Appends the deploy
#                         to repo-store's ledger.
#   deploy-gate status    print what check would say, exit 0 either way.
#   deploy-gate register  register this tree, and every sibling tree its Go build
#                         reads, with repo-store, as the main clone of its repo.
#                         Refuses a tree whose name repo-store already has at
#                         another path: that one is a second clone.
#   deploy-gate install   run from a healthcheck main clone: install this script
#                         as ~/bin/deploy-gate. Checks only what needs no
#                         repo-store, so a fresh host can install the gate first.
#   deploy-gate detach <log> [--setenv NAME]... -- <command> [args]
#                         for a deploy that restarts the service its caller runs
#                         in. Runs <command> in a transient systemd unit, logging
#                         to a file of its own beside <log> (<log> minus .log,
#                         then .<unit>.log), points <log> at it with a symlink,
#                         and returns at once. When the command ends,
#                         pass or fail, the unit sends the outcome and the end of
#                         the log to the bridge session that started it.
#   deploy-gate run-detached <command> [args]
#                         what that unit runs. Not for calling by hand.
#
# WHY THIS EXISTS
#
# Measured 2026-09-17: of the binaries running on this box, 5 were built from a
# commit that is not on main and 5 from a dirty tree; 29 of 85 main clones were
# parked on a side branch; 492 local branches were unmerged. The nightly
# repo-deploy audit (repo-deploy-audit.sh) reports all of it the morning after.
# Nothing stopped it at the moment it happened, because 49 of 50 deploy.sh
# scripts would build whatever tree they were run in.
#
# An earlier attempt pasted a 23-line guard into each deploy.sh, on a branch per
# repo. About 38 of those branches exist and 2 were merged — the fix for
# unmerged branches became 36 unmerged branches. So this is ONE script that
# deploy.sh calls, not a block to copy. Do not inline it.
#
# WHAT IT REFUSES, and why each one
#
#   linked worktree     A worktree is scratch space for one task. What it holds
#                       is whatever that task left, at whatever age.
#   wrong path          The tree is not the path repo-store has for this repo
#                       (~/repos/<name>). A second clone is a second truth.
#   side branch         The tree is not on the default branch.
#   dirty               Tracked files are modified: the commit the binary gets
#                       stamped with is not what was built.
#   not on origin       HEAD is not contained in origin/<default>: unpushed, or
#                       a side-branch commit. Nobody else can see what is live.
#   behind origin       origin/<default> has commits this tree lacks: deploying
#                       rolls somebody's merged work back.
#   sibling trees       A Go build reads the trees its replace directives (and
#                       GOWORK) point at. Each must itself be a registered main
#                       clone, on its default branch, clean — or the binary
#                       ships somebody's half-done work under this repo's sha.
#                       (2026-09-17: a bridge built against a stale agent-store
#                       worktree came up with no agent data at all.)
#
# A FRESH HOST
#
# The path checks ask repo-store, and repo-store is deployed through this gate,
# so a host with neither needs an order that never skips a check:
#
#   1. healthcheck clone:  scripts/deploy-gate.sh install
#   2. repo-store clone:   ./deploy.sh — repo-store is the one repo the gate
#      lets through while repo-store does not answer, because the repo-store
#      checks cannot be asked of a store that is not running yet. Every other
#      check still runs. Its record step registers it and its siblings.
#   3. any other repo:     deploy-gate register, once, for siblings repo-store
#      has never seen; then ./deploy.sh.
#
# For any other repo, a repo-store that does not answer is a refusal of its
# own, never read as "this path is not registered".
#
# THE OVERRIDE
#
#   DEPLOY_GATE_OVERRIDE="why" ./deploy.sh
#
# The deploy goes ahead and the ledger keeps the refusals and the reason
# forever. There is no quiet way through. An empty reason is refused.
#
# The default branch is resolved exactly as repo-deploy-audit.sh resolves it, so
# the gate and the audit can never disagree about what "main" is.
#
# WHY DETACH REPORTS BACK
#
# An agent that deploys llm-bridge-server runs inside llm-bridge.service, so the
# deploy's restart kills it. The bridge resumes a session only when a turn was
# cut off; if the agent had already ended its turn, which is the natural thing
# to do after starting a deploy it cannot wait for, the session sits idle and
# nothing ever tells it how the deploy went. That happened on 2026-09-09,
# 2026-09-22 and 2026-09-26 (br_1790462284393059025: turn ended at 22:49:48,
# restart at 22:49:51, never picked up again). So the detached unit sends the
# outcome to the session named by LLM_BRIDGE_SESSION_ID, which the bridge puts
# in every local harness child, and the message wakes the session whatever
# state the restart left it in.
#
# Detach used to be a block pasted into each deploy.sh. The copies drifted: two
# of them stopped carrying CLAUDE_CODE_SESSION_ID and AI_AGENT into the unit, so
# the ledger recorded those deploys as "by user kayushkincom". There is one copy
# now, here.

set -euo pipefail

REPO_STORE_URL="${REPO_STORE_URL:-http://localhost:8306}"
mode="${1:-}"

die() { echo "deploy-gate: $*" >&2; exit 2; }

command -v git >/dev/null || die "git not found"
command -v python3 >/dev/null || die "python3 not found"

top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository: $PWD"

# default_branch_of <tree> — the branch origin/HEAD names, else a local main,
# else a local master. Empty when none exists.
default_branch_of() {
  local tree="$1" name
  name="$(git -C "$tree" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  name="${name#origin/}"
  if [ -z "$name" ]; then
    for candidate in main master; do
      if git -C "$tree" show-ref --verify --quiet "refs/heads/$candidate"; then name="$candidate"; break; fi
    done
  fi
  printf '%s' "$name"
}

is_linked_worktree() { [ -f "$1/.git" ]; }

# tree_faults <tree> <label> — print one line per reason <tree> is not a clean
# main clone on its default branch. Used for the repo itself and its siblings.
tree_faults() {
  local tree="$1" label="$2" branch default
  if is_linked_worktree "$tree"; then echo "$label is a linked git worktree ($tree)"; fi
  default="$(default_branch_of "$tree")"
  branch="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$default" ]; then
    echo "$label has no default branch this gate can resolve (no origin/HEAD, no main, no master)"
  elif [ "$branch" != "$default" ]; then
    echo "$label is on '${branch:-a detached HEAD}', not its default branch '$default'"
  fi
  if [ -n "$(git -C "$tree" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "$label has modified tracked files: $(git -C "$tree" status --porcelain --untracked-files=no | head -3 | tr '\n' ';')"
  fi
}

repo_store() { # repo_store <method> <path> [json] → body on stdout, fails on non-2xx
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sfS -X "$method" -H 'Content-Type: application/json' -d "$body" "$REPO_STORE_URL$path"
  else
    curl -sfS -X "$method" "$REPO_STORE_URL$path"
  fi
}

json_field() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print("" if v is None else v)' "$1"; }

urlencode() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

# repo_store_answers — true when repo-store takes a request at all. A 404 from
# /by-path means "not registered"; no answer means nothing is known, and the
# two must never be read as one.
repo_store_answers() { curl -sfS -o /dev/null --max-time 5 "$REPO_STORE_URL/health" 2>/dev/null; }

# go_module_of <tree> — the module path its go.mod declares, or empty.
go_module_of() { [ -f "$1/go.mod" ] && sed -n 's/^module[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$1/go.mod" | head -1; }

repo_store_module="github.com/kayushkin/repo-store"
healthcheck_module="github.com/kayushkin/healthcheck"

# origin_name_of <tree> — the repo name in its origin URL, or the folder name.
origin_name_of() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  if [ -n "$url" ]; then basename "${url%.git}"; else basename "$1"; fi
}

# registration_fault <tree> <label> — empty when repo-store has <tree> at its
# path. Otherwise one line: a second clone, or a main clone nobody registered.
registration_fault() {
  local tree="$1" label="$2" name other
  repo_store GET "/by-path?path=$(urlencode "$tree")" >/dev/null 2>&1 && return 0
  name="$(origin_name_of "$tree")"
  other="$(repo_store GET "/repos/by-name/$name" 2>/dev/null || true)"
  if [ -n "$other" ]; then
    echo "$label is a second clone: repo-store has $name at $(printf '%s' "$other" | json_field path)"
  else
    echo "$label is not registered with repo-store: if it is the main clone of $name, run deploy-gate register in $top"
  fi
}

# register_tree <tree> — register <tree> as the main clone of its repo, unless
# repo-store already has it. Prints what it did; fails on a second clone or a
# tree that is not a clean main clone.
register_tree() {
  local tree="$1" name other faults body
  if repo_store GET "/by-path?path=$(urlencode "$tree")" >/dev/null 2>&1; then
    echo "deploy-gate: $tree is already registered"; return 0
  fi
  name="$(origin_name_of "$tree")"
  other="$(repo_store GET "/repos/by-name/$name" 2>/dev/null || true)"
  if [ -n "$other" ]; then
    echo "deploy-gate: not registering $tree: repo-store has $name at $(printf '%s' "$other" | json_field path)" >&2; return 1
  fi
  faults="$(tree_faults "$tree" "$tree")"
  if [ -n "$faults" ]; then
    echo "deploy-gate: not registering $tree, which is not a clean main clone:" >&2
    printf '  - %s\n' "$faults" >&2; return 1
  fi
  body="$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"path":sys.argv[2]}))' "$name" "$tree")"
  repo_store POST /repos "$body" >/dev/null || { echo "deploy-gate: repo-store at $REPO_STORE_URL would not register $tree" >&2; return 1; }
  echo "deploy-gate: registered $tree as $name"
}

# Sibling trees a Go build reads: every local-directory replace in go.mod, and
# every use/replace in the go.work that GOWORK (or a go.work up the tree) names.
# Read with `go mod edit` / `go work edit`, which parse the files and resolve
# nothing — `go list -m all` fails outright in a repo whose replaced modules
# are not fetchable, and a check that fails quietly passes everything.
go_local_dirs() { # go_local_dirs <kind: mod|work> <file> → absolute dirs, one per line
  local kind="$1" file="$2" base
  base="$(cd "$(dirname "$file")" && pwd)"
  go "$kind" edit -json "$file" | python3 -c '
import json,os,sys
base=sys.argv[1]; d=json.load(sys.stdin); out=set()
for r in d.get("Replace") or []:
    new=r.get("New") or {}
    if new.get("Path") and not new.get("Version"): out.add(new["Path"])   # a directory, not a module version
for u in d.get("Use") or []:
    if u.get("DiskPath"): out.add(u["DiskPath"])
for p in sorted(out): print(os.path.normpath(p if os.path.isabs(p) else os.path.join(base,p)))' "$base"
}
# sibling_trees — the top of every git tree, other than this one, that the Go
# build reads. Dies when a file cannot be read: a check that fails quietly
# passes everything. A missing directory is printed as "missing:<dir>".
sibling_trees() {
  [ -f "$top/go.mod" ] || return 0
  command -v go >/dev/null || die "this is a Go repo and go is not on PATH, so the trees it builds against cannot be checked"
  local dirs workfile sibling sibling_top
  dirs="$(go_local_dirs mod "$top/go.mod")" || die "could not read $top/go.mod"
  workfile="$(cd "$top" && go env GOWORK)"
  if [ -n "$workfile" ] && [ "$workfile" != "off" ]; then
    dirs+=$'\n'"$(go_local_dirs work "$workfile")" || die "could not read $workfile"
  fi
  while IFS= read -r sibling; do
    [ -z "$sibling" ] && continue
    if [ ! -d "$sibling" ]; then echo "missing:$sibling"; continue; fi
    sibling_top="$(git -C "$sibling" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -z "$sibling_top" ] && continue          # a plain directory inside this repo, or not a repo
    [ "$sibling_top" = "$top" ] && continue
    echo "$sibling_top"
  done < <(printf '%s\n' "$dirs" | sort -u) | sort -u
}

# --- detached deploys, and the report back ------------------------------------

BRIDGE_URL="${LLM_BRIDGE_URL:-http://localhost:8160}"
BRIDGE_TOKEN_FILE="${LLM_BRIDGE_TOKEN_FILE:-$HOME/.config/principal-gating-tokens.env}"
# How long the report waits for the bridge to answer /health before it gives up.
BRIDGE_HEALTH_WAIT_SECONDS="${DEPLOY_GATE_BRIDGE_HEALTH_WAIT_SECONDS:-180}"

# What the detached run needs from its caller's environment, whatever the repo.
# record names the deployer from CLAUDE_CODE_SESSION_ID and AI_AGENT, and must
# see an override; the report goes to LLM_BRIDGE_SESSION_ID.
detach_carried_variables=(HOME PATH LLM_BRIDGE_SESSION_ID CLAUDE_CODE_SESSION_ID AI_AGENT DEPLOY_GATE_OVERRIDE)

# report_to_starting_session <exit status> — tell the bridge session that started
# this deploy how it ended. Returns non-zero when a session should have been told
# and was not; the caller turns that into a failed unit.
report_to_starting_session() {
  local status="$1" session="${LLM_BRIDGE_SESSION_ID:-}" token body attempt
  if [ -z "$session" ]; then
    echo "deploy-gate: no LLM_BRIDGE_SESSION_ID, so this deploy was not started from a bridge session and no session is told how it went"
    return 0
  fi
  token="$(sed -n 's/^LLMBRIDGE_SERVICE_TOKEN=//p' "$BRIDGE_TOKEN_FILE" 2>/dev/null | head -1)"
  if [ -z "$token" ]; then
    echo "deploy-gate: ERROR: no LLMBRIDGE_SERVICE_TOKEN in $BRIDGE_TOKEN_FILE, so session $session is NOT told how the deploy went" >&2
    return 1
  fi
  body="$(python3 - "$status" "$(basename "$top")" "$(git -C "$top" rev-parse --short=9 HEAD)" "${DEPLOY_GATE_LOG:-}" <<'PY'
import json,sys
status,repo,sha,log=sys.argv[1:]
outcome="succeeded" if status=="0" else "FAILED (exit %s)" % status
try:
    tail="".join(open(log).readlines()[-25:]) if log else ""
except OSError as error:
    tail="(could not read the log: %s)" % error
text=("[deploy-gate] The deploy of %s at %s that this session started has finished: it %s.\n\n" % (repo,sha,outcome) +
      "This is a report, not a new instruction; the user's last request still stands. If the deploy restarted "
      "llm-bridge, your turn may have been cut off and resumed on its own before this arrived. Check what the "
      "deploy changed, finish what the request still needs, and tell the user the outcome.\n\n"
      "Last 25 lines of %s:\n```\n%s```" % (log or "the log", tail))
# A bridge report (llm-bridge msg.WrapBridgeReport): the whole message is one
# <bridge-report kind="deploy"> block, so the chat folds it instead of drawing it
# as something the person wrote.
text='<bridge-report kind="deploy">\n' + text + '\n</bridge-report>'
print(json.dumps({"message":text}))
PY
)"
  # The bridge may still be coming up after the restart this deploy caused, or
  # after a rollback. Wait for it to answer /health before the first try, so the
  # tries below are spent on a bridge that is up rather than on a port that
  # refuses connections.
  local waited=0
  until curl -sf -o /dev/null --max-time 5 "$BRIDGE_URL/health"; do
    if [ "$waited" -ge "$BRIDGE_HEALTH_WAIT_SECONDS" ]; then
      echo "deploy-gate: ERROR: $BRIDGE_URL/health did not answer within ${BRIDGE_HEALTH_WAIT_SECONDS}s, so the bridge is down; session $session is NOT told how the deploy went" >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
  [ "$waited" -gt 0 ] && echo "deploy-gate: $BRIDGE_URL answered /health after ${waited}s"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sfS -o /dev/null -X POST -H "X-LLM-Bridge-Service-Token: $token" -H 'Content-Type: application/json' \
      -d "$body" "$BRIDGE_URL/sessions/$session/send"; then
      echo "deploy-gate: told session $session how the deploy went"
      return 0
    fi
    sleep 3
  done
  echo "deploy-gate: ERROR: $BRIDGE_URL would not take the report for session $session after 10 tries; it is NOT told how the deploy went" >&2
  return 1
}

case "$mode" in
  detach)
    shift
    log="${1:-}"
    [ -n "$log" ] || die "usage: deploy-gate detach <log> [--setenv NAME]... -- <command> [args]"
    shift
    carried=("${detach_carried_variables[@]}")
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
      case "$1" in
        --setenv) [ $# -ge 2 ] || die "detach: --setenv needs a variable name"; carried+=("$2"); shift 2 ;;
        *) die "detach: unknown option $1" ;;
      esac
    done
    [ "${1:-}" = "--" ] || die "detach: put -- before the command"
    shift
    [ $# -gt 0 ] || die "detach: no command to run"
    case "$log" in /*) ;; *) die "detach: the log path must be absolute: $log" ;; esac
    # The log lives under $HOME, not /tmp: a transient unit gets a private /tmp.
    mkdir -p "$(dirname "$log")"
    unit_stem="$(basename "$top")-deploy-$$"
    unit="$unit_stem.service"
    # Each run writes its own file, and <log> is a symlink to the newest one.
    # Emptying one shared file let a second deploy wipe the log of a first that
    # was still building (two llm-bridge deploys on 2026-11-04 08:13 and 08:14
    # UTC), and the two runs' lines and reports then mixed in one file.
    run_log="${log%.log}.$unit_stem.log"
    : >"$run_log"
    ln -sfn "$run_log" "$log"
    # Drop run logs no deploy has written to for a week. A run still going
    # writes to its file, so its mtime keeps it.
    find "$(dirname "$log")" -maxdepth 1 -type f -name "$(basename "${log%.log}").*-deploy-*.log" -mtime +7 -delete
    unit_environment=(--setenv=DEPLOY_DETACHED=1 --setenv=DEPLOY_GATE_LOG="$run_log")
    for name in "${carried[@]}"; do
      if [ -n "${!name+x}" ]; then unit_environment+=(--setenv="$name=${!name}"); fi
    done
    # A transient unit under system.slice is outside the caller's cgroup, so
    # restarting llm-bridge.service does not take the deploy down with the agent.
    # setsid and nohup do not escape a cgroup kill.
    sudo systemd-run --collect --unit="$unit" --description="$(basename "$top") deploy ($USER)" \
      --uid="$(id -u)" --gid="$(id -g)" --working-directory="$top" "${unit_environment[@]}" \
      --property=StandardOutput=append:"$run_log" --property=StandardError=append:"$run_log" \
      "$(readlink -f "$0")" run-detached "$@" >/dev/null
    echo "deploy-gate: detached deploy (unit=$unit), tail -f $run_log ($log points at the newest run)"
    if [ -n "${LLM_BRIDGE_SESSION_ID:-}" ]; then
      echo "deploy-gate: when it finishes, pass or fail, the outcome is sent to session $LLM_BRIDGE_SESSION_ID as a new message."
      echo "deploy-gate: do not wait for it in this turn: if it restarts llm-bridge, it kills this process. End the turn; the report starts the next one."
    else
      echo "deploy-gate: no LLM_BRIDGE_SESSION_ID here, so nothing will report back: read $run_log for the outcome."
    fi
    exit 0
    ;;

  run-detached)
    shift
    [ -n "${DEPLOY_DETACHED:-}" ] || die "run-detached runs only inside the unit that deploy-gate detach starts"
    [ $# -gt 0 ] || die "run-detached: no command to run"
    if "$@"; then status=0; else status=$?; fi
    if ! report_to_starting_session "$status" && [ "$status" -eq 0 ]; then
      status=3
    fi
    exit "$status"
    ;;
esac

# --- modes that run before the full check ------------------------------------

case "$mode" in
  install)
    [ "$(go_module_of "$top")" = "$healthcheck_module" ] || die "install runs from a healthcheck clone; $top is not one"
    install_refusals="$(tree_faults "$top" "this tree")"
    install_default="$(default_branch_of "$top")"
    if git -C "$top" remote get-url origin >/dev/null 2>&1 && [ -n "$install_default" ]; then
      git -C "$top" fetch --quiet origin "$install_default" || die "could not fetch origin/$install_default"
      git -C "$top" merge-base --is-ancestor HEAD "origin/$install_default" \
        || install_refusals+=$'\n'"HEAD is not on origin/$install_default: merge it and push first"
      [ "$(git -C "$top" rev-list --count "HEAD..origin/$install_default")" -eq 0 ] \
        || install_refusals+=$'\n'"this tree is behind origin/$install_default: pull first"
    else
      install_refusals+=$'\n'"this tree has no origin to check against"
    fi
    install_refusals="$(printf '%s\n' "$install_refusals" | sed '/^$/d')"
    if [ -n "$install_refusals" ]; then
      echo "deploy-gate: not installing from $top:" >&2
      printf '%s\n' "$install_refusals" | sed 's/^/  - /' >&2
      exit 1
    fi
    target="${DEPLOY_GATE_INSTALL_PATH:-$HOME/bin/deploy-gate}"
    mkdir -p "$(dirname "$target")"
    install -m 755 "$top/scripts/deploy-gate.sh" "$target"
    echo "deploy-gate: installed $target from healthcheck @ $(git -C "$top" rev-parse --short=9 HEAD)"
    exit 0
    ;;

  register)
    repo_store_answers || die "repo-store at $REPO_STORE_URL does not answer: deploy repo-store first"
    register_failed=0
    register_tree "$top" || register_failed=1
    while IFS= read -r sibling; do
      [ -z "$sibling" ] && continue
      case "$sibling" in missing:*) echo "deploy-gate: the build reads ${sibling#missing:}, which does not exist" >&2; register_failed=1; continue ;; esac
      register_tree "$sibling" || register_failed=1
    done < <(sibling_trees)
    exit "$register_failed"
    ;;

  record)
    # A repo that is deployed while repo-store was down (repo-store itself, on a
    # fresh host) registers the trees it was built from, now that it answers.
    # repo-store's deploy.sh records seconds after the start, so give it time to listen.
    if [ "$(go_module_of "$top")" = "$repo_store_module" ]; then
      for _ in $(seq 1 20); do repo_store_answers && break; sleep 1; done
    fi
    if [ "$(go_module_of "$top")" = "$repo_store_module" ] && repo_store_answers \
       && ! repo_store GET "/by-path?path=$(urlencode "$top")" >/dev/null 2>&1; then
      register_tree "$top" || die "repo-store came up but would not register $top; the deploy happened and is NOT recorded"
      while IFS= read -r sibling; do
        case "$sibling" in ""|missing:*) continue ;; esac
        register_tree "$sibling" || die "repo-store came up but would not register $sibling; the deploy happened and is NOT recorded"
      done < <(sibling_trees)
    fi
    ;;
esac

# --- facts about this tree ---------------------------------------------------

default="$(default_branch_of "$top")"
branch="$(git -C "$top" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
head_sha="$(git -C "$top" rev-parse HEAD)"
dirty=false
[ -n "$(git -C "$top" status --porcelain --untracked-files=no)" ] && dirty=true

refusals=()
while IFS= read -r line; do [ -n "$line" ] && refusals+=("$line"); done < <(tree_faults "$top" "this tree")

# Is repo-store there to ask? When it is not, nothing about paths is known.
# The one tree let through is repo-store itself, which has to run before it can
# answer; every other check still applies to it.
repo_store_up=true
bootstrapping_repo_store=false
if ! repo_store_answers; then
  repo_store_up=false
  if [ "$(go_module_of "$top")" = "$repo_store_module" ]; then
    bootstrapping_repo_store=true
  else
    refusals+=("repo-store at $REPO_STORE_URL does not answer, so whether this tree and its siblings are main clones cannot be checked: deploy repo-store first")
  fi
fi

# Which repo is this, by repo-store's id? First by the tree's own path. A clone
# somewhere else is matched by the name in its origin URL, and then refused for
# being in the wrong place.
repo_json=""
if $repo_store_up; then
  repo_json="$(repo_store GET "/by-path?path=$(urlencode "$top")" 2>/dev/null || true)"
  if [ -z "$repo_json" ]; then
    origin_name="$(origin_name_of "$top")"
    repo_json="$(repo_store GET "/repos/by-name/$origin_name" 2>/dev/null || true)"
    if [ -n "$repo_json" ]; then
      refusals+=("this tree ($top) is not where repo-store has $origin_name ($(printf '%s' "$repo_json" | json_field path)): deploy from the main clone")
    fi
  fi
fi
repo_id=""; [ -n "$repo_json" ] && repo_id="$(printf '%s' "$repo_json" | json_field id)"

on_default=false
if [ -n "$default" ] && git -C "$top" remote get-url origin >/dev/null 2>&1; then
  git -C "$top" fetch --quiet origin "$default" 2>/dev/null || refusals+=("could not fetch origin/$default, so nothing here can be checked against it")
  if git -C "$top" rev-parse --verify --quiet "origin/$default" >/dev/null; then
    if git -C "$top" merge-base --is-ancestor "$head_sha" "origin/$default"; then
      on_default=true
    else
      refusals+=("HEAD ${head_sha:0:9} is not on origin/$default: it is unpushed or a side-branch commit — merge it and push first")
    fi
    behind="$(git -C "$top" rev-list --count "HEAD..origin/$default")"
    [ "$behind" -gt 0 ] && refusals+=("this tree is $behind commit(s) behind origin/$default: deploying it rolls merged work back — pull first")
  fi
elif [ -n "$default" ]; then
  # No origin at all: the local default branch is the only trunk there is.
  git -C "$top" merge-base --is-ancestor "$head_sha" "$default" && on_default=true
fi

# Sibling trees a Go build reads must each be a clean main clone, registered.
while IFS= read -r sibling; do
  [ -z "$sibling" ] && continue
  case "$sibling" in missing:*) refusals+=("the build reads ${sibling#missing:}, which does not exist"); continue ;; esac
  while IFS= read -r line; do [ -n "$line" ] && refusals+=("$line"); done < <(tree_faults "$sibling" "the build reads $sibling, which")
  if $repo_store_up; then
    line="$(registration_fault "$sibling" "the build reads $sibling, which")"
    [ -n "$line" ] && refusals+=("$line")
  fi
done < <(sibling_trees)

# --- what is live now, from the ledger ---------------------------------------

last_line="no deployment of this repo is recorded yet"
if [ -n "$repo_id" ]; then
  last_line="$(repo_store GET "/deployments?repo_id=$repo_id&limit=1" | python3 -c '
import json,sys,time
rows=json.load(sys.stdin)
if not rows:
    print("no deployment of this repo is recorded yet"); raise SystemExit
d=rows[0]; age=int(time.time())-d["created_at"]
ago=str(age//86400)+"d" if age>=86400 else str(age//3600)+"h" if age>=3600 else str(age//60)+"m"
how="clean" if not d["refusals"] else "OVERRIDDEN: "+d["override_reason"]
print("last deployed", d["commit_sha"][:9], "from", d["branch"] or "a detached HEAD", ago, "ago by", d.get("deployed_by") or "unknown,", how)')" || last_line="the deploy ledger at $REPO_STORE_URL could not be read"
fi

report() {
  echo "deploy-gate: $(basename "$top") @ ${head_sha:0:9} on ${branch:-a detached HEAD} (default: ${default:-unknown})"
  echo "deploy-gate: $last_line"
  if $bootstrapping_repo_store; then
    echo "deploy-gate: repo-store at $REPO_STORE_URL does not answer and this is repo-store: its own path checks wait for it to start; record registers this tree and its siblings"
  fi
  if [ "${#refusals[@]}" -eq 0 ]; then
    echo "deploy-gate: fit to deploy"
  else
    echo "deploy-gate: NOT fit to deploy — ${#refusals[@]} reason(s):" >&2
    for r in "${refusals[@]}"; do echo "  - $r" >&2; done
  fi
}

case "$mode" in
  status)
    report
    ;;

  check)
    report
    [ "${#refusals[@]}" -eq 0 ] && exit 0
    if [ -n "${DEPLOY_GATE_OVERRIDE+x}" ]; then
      [ -n "${DEPLOY_GATE_OVERRIDE// /}" ] || die "DEPLOY_GATE_OVERRIDE is set but empty: an override needs its reason"
      echo "deploy-gate: OVERRIDDEN — \"$DEPLOY_GATE_OVERRIDE\". The ledger will keep these refusals and this reason." >&2
      exit 0
    fi
    echo "deploy-gate: refusing. Land the work (merge to $default, push), deploy from the main clone, or set DEPLOY_GATE_OVERRIDE=\"why\" — which is recorded." >&2
    exit 1
    ;;

  record)
    if [ -z "$repo_id" ]; then
      # A repo repo-store has never heard of. Register it rather than lose the record.
      repo_json="$(repo_store POST /repos "$(python3 -c 'import json,sys,os; print(json.dumps({"name":os.path.basename(sys.argv[1]),"path":sys.argv[1]}))' "$top")")" || die "could not register $top with repo-store at $REPO_STORE_URL; the deploy happened and is NOT recorded"
      repo_id="$(printf '%s' "$repo_json" | json_field id)"
    fi
    if [ "${#refusals[@]}" -gt 0 ] && [ -z "${DEPLOY_GATE_OVERRIDE:-}" ]; then
      # check passed and the tree changed under the deploy, or record was called
      # without check. Either way say so rather than drop the row.
      export DEPLOY_GATE_OVERRIDE="recorded without a passing check: the tree was not fit at record time"
    fi
    payload="$(python3 - "$head_sha" "$branch" "$default" "$top" "$on_default" "$dirty" "${DEPLOY_GATE_OVERRIDE:-}" "${CLAUDE_CODE_SESSION_ID:-}" "${AI_AGENT:-}" "${USER:-}" "${refusals[@]+"${refusals[@]}"}" <<'PY'
import json,sys
sha,branch,default,top,on_default,dirty,override,session,agent,user,*refusals=sys.argv[1:]
who=" ".join(x for x in (agent, ("session "+session) if session else "", ("user "+user) if not session and user else "") if x)
print(json.dumps({"commit_sha":sha,"branch":branch,"default_branch":default,"source_path":top,
  "on_default":on_default=="true","dirty":dirty=="true","override_reason":override if refusals else "",
  "refusals":refusals,"deployed_by":who}))
PY
)"
    repo_store POST "/repos/$repo_id/deployments" "$payload" >/dev/null || die "repo-store at $REPO_STORE_URL refused or did not answer; the deploy happened and is NOT recorded. Payload: $payload"
    echo "deploy-gate: recorded ${head_sha:0:9} in the deploy ledger (repo $repo_id)"
    ;;

  *)
    die "usage: deploy-gate check | record | status | register | install | detach <log> [--setenv NAME]... -- <command> [args]"
    ;;
esac
