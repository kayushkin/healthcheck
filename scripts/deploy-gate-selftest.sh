#!/usr/bin/env bash
#
# deploy-gate-selftest — pin how deploy-gate behaves on a fresh host, where
# neither ~/bin/deploy-gate nor repo-store exists yet, without touching ~/repos
# or the real repo-store.
#
# Each case builds throwaway clones under a temp directory (each with a bare
# origin) and, where a case needs one, a stand-in repo-store: a small Python
# server holding repos and deployments in memory, on a free loopback port.
#
# What it pins:
#   - install puts the gate in place from a clean, pushed healthcheck clone with
#     no repo-store, and refuses a dirty one;
#   - with repo-store down, repo-store's own tree passes check (all other checks
#     still run), and record registers it and its siblings once it is up;
#   - with repo-store down, any other repo is refused, naming repo-store;
#   - an unregistered sibling is refused until register runs, then passes;
#   - a second clone of a registered repo is refused by check and by register;
#   - a detached deploy's report waits for a bridge that is still starting, and
#     gives up with a reason when the bridge stays down;
#   - two detached deploys with one log path each write their own file, and the
#     second does not empty the first's.
#
# Usage: scripts/deploy-gate-selftest.sh     (exit 0 = all pinned)

set -euo pipefail

gate="$(cd "$(dirname "$0")" && pwd)/deploy-gate.sh"
work="$(mktemp -d)"
server_pid=""
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export HOME="$work/home"; mkdir -p "$HOME"
export GOFLAGS=-mod=mod GOWORK=off
unset LLM_BRIDGE_SESSION_ID DEPLOY_GATE_OVERRIDE CLAUDE_CODE_SESSION_ID AI_AGENT

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
export REPO_STORE_URL="http://127.0.0.1:$port"

# make_repo <name> <module> [replace-target]... — a clone at $work/repos/<name>
# with a pushed main, whose go.mod replaces each target with ../<target>.
make_repo() {
  local name="$1" module="$2"; shift 2
  local bare="$work/origins/$name.git" tree="$work/repos/$name"
  git init -q --bare -b main "$bare"
  git init -q -b main "$tree"
  { echo "module $module"; echo; echo "go 1.21"; for target in "$@"; do echo "replace example.com/$target => ../$target"; done; } >"$tree/go.mod"
  if [ "$module" = "github.com/kayushkin/healthcheck" ]; then mkdir -p "$tree/scripts"; cp "$gate" "$tree/scripts/deploy-gate.sh"; fi
  git -C "$tree" add -A; git -C "$tree" commit -qm init
  git -C "$tree" remote add origin "$bare"
  git -C "$tree" push -q -u origin main
  git -C "$tree" remote set-head origin main
}

start_repo_store() {
  python3 - "$port" >"$work/repo-store.log" 2>&1 <<'PY' &
import json,sys,urllib.parse
from http.server import BaseHTTPRequestHandler,HTTPServer
repos=[]; deployments=[]
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,code,body):
        data=json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); q=urllib.parse.parse_qs(u.query)
        if u.path=="/health": return self.send(200,{"ok":True})
        if u.path=="/by-path":
            for r in repos:
                if r["path"]==q.get("path",[""])[0]: return self.send(200,r)
            return self.send(404,{"error":"not found"})
        if u.path.startswith("/repos/by-name/"):
            for r in repos:
                if r["name"]==u.path.rsplit("/",1)[1]: return self.send(200,r)
            return self.send(404,{"error":"not found"})
        if u.path=="/deployments":
            rid=int(q["repo_id"][0]); return self.send(200,[d for d in deployments if d["repo_id"]==rid][::-1][:1])
        if u.path=="/repos": return self.send(200,repos)
        self.send(404,{"error":"no route"})
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
        if self.path=="/repos":
            r={"id":len(repos)+1,"name":body["name"],"path":body["path"]}; repos.append(r); return self.send(201,r)
        if self.path.startswith("/repos/") and self.path.endswith("/deployments"):
            d=dict(body,repo_id=int(self.path.split("/")[2]),created_at=0); deployments.append(d); return self.send(201,d)
        self.send(404,{"error":"no route"})
HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
  server_pid=$!
  for _ in $(seq 1 50); do curl -sf "$REPO_STORE_URL/health" >/dev/null 2>&1 && return 0; sleep 0.1; done
  echo "stand-in repo-store did not start"; cat "$work/repo-store.log"; exit 1
}

registered() { curl -sf "$REPO_STORE_URL/by-path?path=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")" >/dev/null; }

make_repo healthcheck github.com/kayushkin/healthcheck
make_repo dependency example.com/dependency
make_repo repo-store github.com/kayushkin/repo-store dependency
make_repo some-store example.com/some-store dependency other-dependency
make_repo other-dependency example.com/other-dependency

# --- install, with no repo-store --------------------------------------------
export DEPLOY_GATE_INSTALL_PATH="$work/home/bin/deploy-gate"
if (cd "$work/repos/healthcheck" && "$gate" install) >"$work/out" 2>&1 && [ -x "$DEPLOY_GATE_INSTALL_PATH" ]; then
  pass "install works from a clean, pushed healthcheck clone with no repo-store"
else fail "install from a clean healthcheck clone: $(cat "$work/out")"; fi
echo "# dirty" >>"$work/repos/healthcheck/go.mod"
if (cd "$work/repos/healthcheck" && "$gate" install) >"$work/out" 2>&1; then fail "install from a dirty clone was allowed"
else pass "install refuses a dirty healthcheck clone"; fi
git -C "$work/repos/healthcheck" checkout -q go.mod
if (cd "$work/repos/dependency" && "$gate" install) >"$work/out" 2>&1; then fail "install from a non-healthcheck repo was allowed"
else pass "install refuses a tree that is not healthcheck"; fi

# --- repo-store down ---------------------------------------------------------
if (cd "$work/repos/some-store" && "$gate" check) >"$work/out" 2>&1; then fail "check passed some-store with repo-store down"
elif grep -q "repo-store at .* does not answer" "$work/out"; then pass "with repo-store down, another repo is refused and the reason names repo-store"
else fail "with repo-store down, the refusal does not name repo-store: $(cat "$work/out")"; fi

if (cd "$work/repos/repo-store" && "$gate" check) >"$work/out" 2>&1; then pass "with repo-store down, repo-store's own clean tree passes check"
else fail "repo-store's own tree was refused with repo-store down: $(cat "$work/out")"; fi

echo "// dirty" >>"$work/repos/dependency/go.mod"
if (cd "$work/repos/repo-store" && "$gate" check) >"$work/out" 2>&1; then fail "repo-store passed with a dirty sibling while bootstrapping"
else pass "bootstrapping repo-store still refuses a dirty sibling"; fi
git -C "$work/repos/dependency" checkout -q go.mod

# --- repo-store comes up; record registers it and its siblings ----------------
start_repo_store
if (cd "$work/repos/repo-store" && "$gate" record) >"$work/out" 2>&1 \
   && registered "$work/repos/repo-store" && registered "$work/repos/dependency"; then
  pass "record registers repo-store and its sibling once repo-store answers"
else fail "record after bootstrap: $(cat "$work/out")"; fi
if grep -q "OVERRIDE\|recorded without a passing check" "$work/out"; then fail "bootstrap record was written as an override: $(cat "$work/out")"
else pass "bootstrap record is clean, not an override"; fi

# --- an unregistered sibling, then register ----------------------------------
if (cd "$work/repos/some-store" && "$gate" check) >"$work/out" 2>&1; then fail "some-store passed with an unregistered sibling"
elif grep -q "other-dependency, which is not registered with repo-store: .*run deploy-gate register" "$work/out"; then pass "an unregistered sibling is refused, and the reason says to run register"
else fail "unregistered sibling refusal: $(cat "$work/out")"; fi

if (cd "$work/repos/some-store" && "$gate" register) >"$work/out" 2>&1 \
   && registered "$work/repos/some-store" && registered "$work/repos/other-dependency"; then
  pass "register registers the tree and its unregistered sibling"
else fail "register: $(cat "$work/out")"; fi
if (cd "$work/repos/some-store" && "$gate" check) >"$work/out" 2>&1; then pass "after register, some-store passes check"
else fail "after register: $(cat "$work/out")"; fi

# --- a second clone ----------------------------------------------------------
git clone -q "$work/origins/dependency.git" "$work/elsewhere/dependency"
make_repo user-of-copy example.com/user-of-copy
sed -i 's#^go 1.21#go 1.21\nreplace example.com/dependency => ../../elsewhere/dependency#' "$work/repos/user-of-copy/go.mod"
git -C "$work/repos/user-of-copy" commit -qam "use the copy"; git -C "$work/repos/user-of-copy" push -q
if (cd "$work/repos/user-of-copy" && "$gate" register) >"$work/out" 2>&1; then fail "register accepted a second clone"
elif grep -q "repo-store has dependency at" "$work/out"; then pass "register refuses a second clone of a registered repo"
else fail "second clone register: $(cat "$work/out")"; fi
if (cd "$work/repos/user-of-copy" && "$gate" check) >"$work/out" 2>&1; then fail "check passed a build that reads a second clone"
elif grep -q "is a second clone: repo-store has dependency at" "$work/out"; then pass "check refuses a build that reads a second clone"
else fail "second clone check: $(cat "$work/out")"; fi

# --- the report to the session that started a detached deploy -----------------
# A stand-in bridge answers /health and records each /sessions/<id>/send body.
bridge_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
echo "LLMBRIDGE_SERVICE_TOKEN=test-token" >"$work/bridge-tokens.env"
start_bridge() {
  python3 - "$bridge_port" "$work/bridge-received" >"$work/bridge.log" 2>&1 <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler,HTTPServer
port,received=int(sys.argv[1]),sys.argv[2]
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path=="/health" else 404); self.end_headers()
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get("Content-Length",0)))
        if self.headers.get("X-LLM-Bridge-Service-Token")!="test-token" or not self.path.endswith("/send"):
            self.send_response(401); self.end_headers(); return
        with open(received,"ab") as f: f.write(self.path.encode()+b"\n"+body+b"\n")
        self.send_response(200); self.end_headers()
    def log_message(self,*args): pass
HTTPServer(("127.0.0.1",port),Handler).serve_forever()
PY
  bridge_pid=$!
}
run_detached_with_report() {
  (cd "$work/repos/some-store" && DEPLOY_DETACHED=1 LLM_BRIDGE_SESSION_ID=br_test \
    LLM_BRIDGE_URL="http://127.0.0.1:$bridge_port" LLM_BRIDGE_TOKEN_FILE="$work/bridge-tokens.env" \
    DEPLOY_GATE_BRIDGE_HEALTH_WAIT_SECONDS="$1" "$gate" run-detached true)
}

# The bridge comes up 4 seconds after the deploy ends: the report waits for it.
(sleep 4; start_bridge; wait) &
late_bridge_starter=$!
if run_detached_with_report 30 >"$work/out" 2>&1 \
   && grep -q "answered /health after" "$work/out" && grep -q "told session br_test" "$work/out" \
   && grep -q "/sessions/br_test/send" "$work/bridge-received"; then
  pass "the report waits for a bridge that is still starting, then reaches the session"
else fail "late bridge report: $(cat "$work/out")"; fi
pkill -P "$late_bridge_starter" 2>/dev/null || true; kill "$late_bridge_starter" 2>/dev/null || true
wait "$late_bridge_starter" 2>/dev/null || true

# No bridge ever answers: the run fails and says the bridge is down.
if run_detached_with_report 3 >"$work/out" 2>&1; then fail "a deploy whose report reached no bridge exited 0"
elif grep -q "/health did not answer within 3s, so the bridge is down; session br_test is NOT told" "$work/out"; then
  pass "with the bridge down, the report gives up after the wait and says why"
else fail "bridge-down report: $(cat "$work/out")"; fi

# --- two detached deploys that share one log path -----------------------------
# A stand-in sudo records where systemd-run would send the unit's output and
# starts nothing. The first run then "writes" to its file; the second detach
# must not empty it.
mkdir -p "$work/fake-bin"
cat >"$work/fake-bin/sudo" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in --property=StandardOutput=append:*) echo "${argument#--property=StandardOutput=append:}" >>"$DETACH_TARGETS" ;; esac
done
SH
chmod +x "$work/fake-bin/sudo"
detach_once() {
  (cd "$work/repos/some-store" && PATH="$work/fake-bin:$PATH" DETACH_TARGETS="$work/detach-targets" \
    "$gate" detach "$work/home/.cache/shared-deploy.log" -- true)
}
: >"$work/detach-targets"
detach_once >"$work/out" 2>&1 || fail "first detach: $(cat "$work/out")"
first_log="$(sed -n 1p "$work/detach-targets")"
echo "first run still building" >>"$first_log"
detach_once >"$work/out" 2>&1 || fail "second detach: $(cat "$work/out")"
second_log="$(sed -n 2p "$work/detach-targets")"
if [ -n "$first_log" ] && [ -n "$second_log" ] && [ "$first_log" != "$second_log" ] \
   && grep -q "first run still building" "$first_log" \
   && [ "$(readlink "$work/home/.cache/shared-deploy.log")" = "$second_log" ]; then
  pass "a second detached deploy writes its own log, leaves the first one's alone, and the shared path points at the newest"
else fail "shared detach log: first=$first_log second=$second_log link=$(readlink "$work/home/.cache/shared-deploy.log" || true)"; fi

echo
if [ "$failures" -eq 0 ]; then echo "all pinned"; else echo "$failures failure(s)"; exit 1; fi
