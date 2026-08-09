#!/usr/bin/env python3
"""Find sabotage scorers whose exit status cannot report what they measured.

A scorer that prints "the suite is not running" and exits 0 is worse than no
scorer, because a guard or a script running it reads success. The 54th pass
measured that defect; this asks how much of it is left, fleet-wide, and it asks
the question in terms of the PROCESS STATUS rather than any one code shape.

## Sound by either route

    the entry returns a status AND __main__ wraps it in sys.exit(...)
    or the entry reaches a sys.exit() with a status of its own

Both routes are in use here, so checking only one misjudges half the fleet.

## The three ways it goes wrong

    entry called bare                     -> exits 0 whatever it finds
    module body with no status exit       -> exits 0 whatever it finds
    sys.exit() of a REPORT rather than
      a status                            -> exits 1 whatever it finds

**The third is a trap, and it is why this is not a grep.** `sys.exit` of a
non-int prints it and exits 1. So wrapping a bare caller whose engine still
returns a list does not fix the scorer — it converts an always-0 instrument
into an always-1 one, which looks more like working than the defect it
replaced.

## The answer, taken 2026-08-09

Card `bc14404c` named THREE bare callers and prescribed one line each,
`score(...)` -> `sys.exit(score(...))`. Both halves of that card were wrong:

**The prescribed fix would have broken all three.** Every one sits on a ref
whose engine returns `results`, not a status, so each would have landed in the
always-1 row. That is not three coincidences — a bare caller and a report-
returning engine are one defect seen from two ends. scheduler's `338ec17`
extraction returned the results list, and the callers written against it were
written bare to match.

**The population is seven scorer files, not three.** The card looked for a bare
`score(...)` against the shared engine. Roughly half the scorers on this box
never import that engine — they carry their own `main()`, or run straight-line
with no `__main__` guard at all — and four always-exit-0 scorers were sitting in
that blind spot, in three repositories the card never named:

    multichat             scripts/sabotage-truncation.py     FIXED 1a4a9b2
    scheduler             scripts/sabotage-cmd-ask.py        needs the engine first
    scheduler             scripts/sabotage-kanban-curator.py needs the engine first
    scheduler @curator-and-dispatcher, its own main()        found here
    llm-bridge-server     scripts/sabotage-truncation.py     found here
    tool-store            scripts/sabotage-truncation.py     found here
    llm-bridge-copilotcli scripts/sabotage-identity.py       found here

The two `scheduler` scorers on `test/first-tests-for-ask` cannot be fixed by a
caller edit alone: that ref carries a stale engine, and replacing it is card
`334bbcde`'s work.

## It reads refs, not the working tree

Ten of this box's repositories are parked off trunk, and most sabotage scorers
live only on unmerged test/ and fix/ branches, so a working-tree scan would miss
almost all of them. This walks every local and remote ref, and — the part that
matters — resolves each scorer's ENGINE FROM ITS OWN REF. Resolving it from the
working tree pairs a scorer with a `sabotage.py` its branch does not contain,
which hides the always-1 row precisely where it lives. The `--self-test` plants
a repo whose engine differs between two refs to hold that.

## Where this can be wrong, stated rather than left to be discovered

  - It reads `sys.exit` and `exit` called by those names. A scorer that aliases
    them, or ends via an exception handler, reads as having no status exit.
  - An abort is not a status: `sys.exit("REFUSING: ...")` fires for reasons
    unrelated to the score, so string, f-string and `"..." % (...)` arguments
    are excluded. Counting them credited four always-exit-0 scorers as sound.
  - It judges reachability not at all. A status exit that no run can reach reads
    as sound here. Nothing on this box has that shape today.

    python3 scripts/sabotage-scorer-exit-status-scan.py [--self-test] [--verbose]

Exit 0 when every (ref, scorer) pair is sound, 1 when any is broken or unknown.
It reports; it changes nothing.
"""

import argparse
import ast
import os
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.expanduser("~/repos")
ENGINE_BASENAME = "sabotage.py"

OK = "OK"
BARE_CALLER = "BROKEN: bare caller, exits 0 whatever it finds"
EXIT_OF_REPORT = "BROKEN: sys.exit() of a report, exits 1 whatever it finds"
NO_CALLER = "UNKNOWN: __main__ recognised but its entry call was not"
NO_ENGINE = "UNKNOWN: entry point not defined on this ref"
MODULE_ENTRY = "<module>"
NO_STATUS_EXIT = "BROKEN: module body never exits with a status, exits 0 whatever it finds"


def repositories(root):
    """Directories under root that are real git repositories.

    `.git` must be a DIRECTORY. A linked worktree's `.git` is a file pointing at
    the parent's admin dir, and counting those inflates the repo count with
    checkouts of repositories already in the list.
    """
    found = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if os.path.isdir(os.path.join(path, ".git")):
            found.append(path)
    return found


def _git(repo, *args):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("REFUSING: git %s failed in %s\n%s" % (" ".join(args), repo, proc.stderr))
    return proc.stdout


def _blob(repo, ref, path):
    proc = subprocess.run(["git", "-C", repo, "cat-file", "-p", "%s:%s" % (ref, path)],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return proc.stdout


def scorers_by_ref(repo):
    """[(ref, path)] for every sabotage case file on every ref.

    sabotage.py itself is the shared engine, not a scorer; it has no caller and
    counting it would put a permanent UNKNOWN row in every report.
    """
    found = []
    refs = _git(repo, "for-each-ref", "--format=%(refname:short)",
                "refs/heads", "refs/remotes").split()
    for ref in refs:
        for line in _git(repo, "ls-tree", "-r", "--name-only", ref).splitlines():
            base = os.path.basename(line)
            if base.endswith(".py") and "sabotage" in base and base != ENGINE_BASENAME:
                found.append((ref, line))
    return found


def entry_call(source):
    """(function name, 'bare' | 'sys.exit') for what __main__ invokes, or None.

    Not every scorer on this box uses the shared engine. Roughly half carry
    their own `main()`, and asking only about `score(...)` reports those as
    UNKNOWN — which is where four always-exit-0 scorers were hiding when this
    scan first ran. The question is what the entry point is and whether its
    status reaches the interpreter, not what that entry point is called.
    """
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if not (isinstance(node, ast.If) and _is_main_guard(node.test)):
            continue
        for statement in ast.walk(node):
            if isinstance(statement, ast.Call) and _is_sys_exit(statement.func):
                for argument in statement.args:
                    if isinstance(argument, ast.Call) and isinstance(argument.func, ast.Name):
                        return argument.func.id, "sys.exit"
                return None, "sys.exit"
            if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call):
                called = statement.value.func
                if isinstance(called, ast.Name):
                    return called.id, "bare"
    # No __main__ guard: the module body IS the entry. Ten scorers on this box
    # are written this way — straight-line scripts ending in
    # `sys.exit(0 if score == len(CASES) else 1)`. Requiring a guard reported
    # every one of them UNKNOWN, which is how a real always-exit-0 scorer would
    # hide next to them.
    return MODULE_ENTRY, "module"


def _is_main_guard(test):
    return (isinstance(test, ast.Compare) and isinstance(test.left, ast.Name)
            and test.left.id == "__name__")


def _is_sys_exit(func):
    if isinstance(func, ast.Attribute) and func.attr == "exit":
        return isinstance(func.value, ast.Name) and func.value.id == "sys"
    return isinstance(func, ast.Name) and func.id == "exit"


def _own_returns(function):
    """Return statements belonging to this function, not to one nested in it."""
    found = []

    def walk(node):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                continue
            if isinstance(child, ast.Return):
                found.append(child)
            walk(child)

    walk(function)
    return [node.value for node in found if node.value is not None]


def _returns_status(function, functions, seen):
    """Whether every return of this function is an int-valued expression.

    ⚠️ An entry may DELEGATE its status. The engine carrying `--crosstable`
    mode returns `crosstable(...)` early and `1 if problems else 0` at the end,
    and crosstable returns a status of its own. A first version of this scan
    judged only the syntax of each return expression, called that engine a
    report, and accused about eighty sound pairs across the fleet — so a return
    whose value is a call to a function defined in the same module is resolved
    by reading THAT function's returns.
    """
    if function.name in seen:
        return True          # recursion proves nothing either way; the other arms decide
    seen = seen | {function.name}
    returned = _own_returns(function)
    if not returned:
        return False
    return all(_is_int_valued(value, functions, seen) for value in returned)


def _is_int_valued(node, functions, seen):
    if isinstance(node, ast.Constant):
        return isinstance(node.value, int) and not isinstance(node.value, bool)
    if isinstance(node, ast.IfExp):
        return (_is_int_valued(node.body, functions, seen)
                and _is_int_valued(node.orelse, functions, seen))
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        delegate = functions.get(node.func.id)
        if delegate is not None:
            return _returns_status(delegate, functions, seen)
    return False


def performs_status_exit(function, functions, seen=frozenset()):
    """Whether this function (or one it calls in-module) exits with a status.

    A scorer with its own main() usually never returns anything — it ends with
    `sys.exit(0 if ok else 1)`. That is sound, and judging it by its return
    value alone calls it broken.

    An abort message is not a status. `sys.exit("REFUSING: ...")` exits 1 for a
    reason unrelated to what the suite scored, so a scorer whose ONLY exits are
    aborts still reports success on every normal run. Counting those as status
    exits credited four always-exit-0 scorers as sound on this box.
    """
    if function.name in seen:
        return False
    seen = seen | {function.name}
    for node in ast.walk(function):
        if isinstance(node, ast.Call) and _is_sys_exit(node.func):
            if node.args and not _is_message(node.args[0]):
                return True
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            delegate = functions.get(node.func.id)
            if delegate is not None and performs_status_exit(delegate, functions, seen):
                return True
    return False


def _is_message(node):
    """A human-readable abort string: a literal, an f-string, or '...' % (...)."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return True
    if isinstance(node, ast.JoinedStr):
        return True
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod):
        return _is_message(node.left)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return _is_message(node.left) or _is_message(node.right)
    return False


def classify(caller, entry_returns, entry_exits):
    """Whether this scorer's process status can report what it measured.

    Sound by either route: the entry's status is returned and the caller hands
    it to sys.exit, or the entry calls sys.exit with a status itself.
    """
    if entry_exits:
        return OK
    if caller == "module":
        # A straight-line script has no return value to wrap; its status comes
        # only from a sys.exit it reaches, so without one it always exits 0.
        return NO_STATUS_EXIT
    if entry_returns is None:
        return NO_ENGINE
    if caller is None:
        return NO_CALLER
    if caller == "bare":
        return BARE_CALLER
    return OK if entry_returns == "status" else EXIT_OF_REPORT


def _top_level_status_exit(source):
    """Whether the module body itself exits with a status, skipping its defs."""
    found = []

    def walk(node):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef,
                                  ast.ClassDef, ast.Lambda)):
                continue
            if (isinstance(child, ast.Call) and _is_sys_exit(child.func)
                    and child.args and not _is_message(child.args[0])):
                found.append(child)
            walk(child)

    walk(ast.parse(source))
    return bool(found)


def _functions(source):
    return {node.name: node for node in ast.walk(ast.parse(source))
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}


def resolve_entry(repo, ref, scorer_path, scorer_source, entry_name):
    """(what the entry returns, whether it exits with a status), from ITS OWN ref.

    A scorer may define its entry inline; those using the shared engine import
    score() from a sibling scripts/sabotage.py. Reading that sibling from the
    working tree instead of from `ref` would pair a scorer with an engine its
    branch does not contain — the resolution error that hides the sys.exit-of-a-
    report pairing, because the affected scorers live only on unmerged branches.
    """
    if entry_name is None:
        return None, False
    if entry_name is MODULE_ENTRY:
        # Only the module's OWN top-level statements decide. A `sys.exit(2)`
        # inside a helper is a usage error, not a score, and descending into
        # helpers would credit it as one.
        return "report", _top_level_status_exit(scorer_source)
    local = _functions(scorer_source)
    if entry_name in local:
        returns = "status" if _returns_status(local[entry_name], local, set()) else "report"
        return returns, performs_status_exit(local[entry_name], local)
    sibling = os.path.join(os.path.dirname(scorer_path), ENGINE_BASENAME)
    source = _blob(repo, ref, sibling)
    if source is None:
        return None, False
    shared = _functions(source)
    if entry_name not in shared:
        return None, False
    returns = "status" if _returns_status(shared[entry_name], shared, set()) else "report"
    return returns, performs_status_exit(shared[entry_name], shared)


def scan(root, verbose=False):
    rows = []
    for repo in repositories(root):
        for ref, path in scorers_by_ref(repo):
            source = _blob(repo, ref, path)
            if source is None:
                continue
            try:
                entry_name, caller = entry_call(source)
                returns, exits = resolve_entry(repo, ref, path, source, entry_name)
            except SyntaxError as error:
                sys.exit("REFUSING: %s:%s does not parse (%s). A scan that skips "
                         "unparseable files reports a clean fleet it did not read."
                         % (ref, path, error))
            rows.append({
                "repo": os.path.basename(repo),
                "ref": ref,
                "path": path,
                "entry": entry_name,
                "caller": caller,
                "returns": returns,
                "exits": exits,
                "verdict": classify(caller, returns, exits),
            })
    return rows


def report(rows, verbose):
    broken = [r for r in rows if r["verdict"] != OK]
    files = {(r["repo"], r["path"]) for r in rows}
    print("%d (ref, scorer) pairs — %d distinct scorer files across %d repositories"
          % (len(rows), len(files), len({r["repo"] for r in rows})))
    for row in sorted(rows, key=lambda r: (r["repo"], r["path"], r["ref"])):
        if row["verdict"] == OK and not verbose:
            continue
        print("  %-18s %-46s %s" % (row["repo"], row["path"], row["ref"]))
        print("      entry=%s() caller=%s returns=%s status-exit=%s -> %s"
              % (row["entry"], row["caller"], row["returns"], row["exits"],
                 row["verdict"]))
    print("\n================ verdict ================")
    print("%d of %d pairs are sound" % (len(rows) - len(broken), len(rows)))
    if not broken:
        print("  every scorer's exit status can report what it measured")
    return 1 if broken else 0


ENGINE_STATUS = '''
import sys
def score(target, packages, cases):
    problems = []
    return 1 if problems else 0
'''

ENGINE_REPORT = '''
import sys
def score(target, packages, cases):
    results = []
    return results
'''

# score() delegating its status to a helper, and a nested def whose return must
# NOT be attributed to score. Both shapes are live in scheduler's newest engine.
ENGINE_DELEGATING = '''
import sys
def crosstable(target, packages, cases):
    problems = []
    return 1 if problems else 0
def score(target, packages, cases):
    def restore():
        return "not score's return value"
    if "--crosstable" in sys.argv:
        return crosstable(target, packages, cases)
    problems = []
    return 1 if problems else 0
'''

CALLER_BARE = '''
import sys
from sabotage import score
TARGET, PACKAGES, CASES = 1, 2, 3
if __name__ == "__main__":
    score(TARGET, PACKAGES, CASES)
'''

CALLER_EXIT = '''
import sys
from sabotage import score
TARGET, PACKAGES, CASES = 1, 2, 3
if __name__ == "__main__":
    sys.exit(score(TARGET, PACKAGES, CASES))
'''


# Half the scorers on this box carry their own main() instead of importing the
# shared engine. Judging those by return value alone calls the sound one broken
# and — the direction that actually happened — leaves the broken one UNKNOWN.
SELF_CONTAINED_SOUND = '''
import sys
def main():
    ok = False
    if not ok:
        sys.exit("REFUSING: the tree is dirty")
    sys.exit(0 if ok else 1)
if __name__ == "__main__":
    main()
'''

SELF_CONTAINED_ALWAYS_ZERO = '''
import sys
def main():
    problems = ["something went unpinned"]
    for p in problems:
        print("  warning " + p)
    if not problems:
        sys.exit("REFUSING: nothing to do")
if __name__ == "__main__":
    main()
'''


def self_test():
    """Plant all four pairings and require the scan to separate them.

    A self-test that only proves the scan can find a broken pair would pass
    while the scan flagged everything, so the OK pairing is checked in the
    negative direction with equal weight.

    It also plants a repo whose engine DIFFERS between two refs. Without that
    case every planted repo has one ref, `main` and `HEAD` agree, and resolving
    the engine from the working tree passes the whole self-test — which is the
    one resolution error that would hide row 3 of the table above on this very
    box, where the affected scorers live only on unmerged branches.
    """
    expected = {
        ("bare", "status"): BARE_CALLER,
        ("bare", "report"): BARE_CALLER,
        ("exit", "report"): EXIT_OF_REPORT,
        ("exit", "status"): OK,
        # An engine that delegates its status is sound; calling it broken is the
        # false-positive direction, and it cost this scan eighty accusations.
        ("exit", "delegating"): OK,
        ("bare", "delegating"): BARE_CALLER,
    }
    engines = {"status": ENGINE_STATUS, "report": ENGINE_REPORT,
               "delegating": ENGINE_DELEGATING}
    callers = {"bare": CALLER_BARE, "exit": CALLER_EXIT}

    with tempfile.TemporaryDirectory() as root:
        for (caller_kind, engine_kind), _ in expected.items():
            name = "repo-%s-%s" % (caller_kind, engine_kind)
            repo = os.path.join(root, name)
            os.makedirs(os.path.join(repo, "scripts"))
            with open(os.path.join(repo, "scripts", ENGINE_BASENAME), "w") as handle:
                handle.write(engines[engine_kind])
            with open(os.path.join(repo, "scripts", "sabotage-planted.py"), "w") as handle:
                handle.write(callers[caller_kind])
            for command in (["init", "-q", "-b", "main"], ["add", "-A"],
                            ["-c", "user.email=t@t", "-c", "user.name=t",
                             "commit", "-qm", "planted"]):
                subprocess.run(["git", "-C", repo, *command], check=True,
                               capture_output=True)

        rows = scan(root)
        failures = []
        for (caller_kind, engine_kind), want in expected.items():
            name = "repo-%s-%s" % (caller_kind, engine_kind)
            matching = [r for r in rows if r["repo"] == name]
            if len(matching) != 1:
                failures.append("%s: expected 1 pair, got %d" % (name, len(matching)))
                continue
            got = matching[0]["verdict"]
            if got != want:
                failures.append("%s: expected %r, got %r" % (name, want, got))

        # Self-contained scorers: one sound, one always-exit-0. The always-0 one
        # must be BROKEN and not UNKNOWN — four real scorers on this box sat in
        # the UNKNOWN bucket carrying exactly this shape.
        for name, body, want in (("repo-selfcontained-sound", SELF_CONTAINED_SOUND, OK),
                                 ("repo-selfcontained-zero", SELF_CONTAINED_ALWAYS_ZERO,
                                  BARE_CALLER)):
            repo = os.path.join(root, name)
            os.makedirs(os.path.join(repo, "scripts"))
            with open(os.path.join(repo, "scripts", "sabotage-planted.py"), "w") as handle:
                handle.write(body)
            for command in (["init", "-q", "-b", "main"], ["add", "-A"],
                            ["-c", "user.email=t@t", "-c", "user.name=t",
                             "commit", "-qm", "planted"]):
                subprocess.run(["git", "-C", repo, *command], check=True, capture_output=True)
            rows = [r for r in scan(root) if r["repo"] == name]
            if len(rows) != 1 or rows[0]["verdict"] != want:
                failures.append("%s: expected %r, got %r"
                                % (name, want, [r["verdict"] for r in rows]))

        # Guard-less straight-line scripts, both directions. The sound one ends
        # in a status exit at module level; the broken one only ever exits 0,
        # and a helper's `sys.exit(2)` usage error must not rescue it.
        for name, body, want in (
            ("repo-module-sound", '''
import sys
def usage():
    sys.exit(2)
score, CASES = 1, [1]
print("scored")
sys.exit(0 if score == len(CASES) else 1)
''', OK),
            ("repo-module-zero", '''
import sys
def usage():
    sys.exit(2)
score, CASES = 0, [1]
print("scored")
''', NO_STATUS_EXIT),
        ):
            repo = os.path.join(root, name)
            os.makedirs(os.path.join(repo, "scripts"))
            with open(os.path.join(repo, "scripts", "sabotage-planted.py"), "w") as handle:
                handle.write(body)
            for command in (["init", "-q", "-b", "main"], ["add", "-A"],
                            ["-c", "user.email=t@t", "-c", "user.name=t",
                             "commit", "-qm", "planted"]):
                subprocess.run(["git", "-C", repo, *command], check=True, capture_output=True)
            rows = [r for r in scan(root) if r["repo"] == name]
            if len(rows) != 1 or rows[0]["verdict"] != want:
                failures.append("%s: expected %r, got %r"
                                % (name, want, [r["verdict"] for r in rows]))

        # An abort message is not a status. A scorer whose only sys.exit calls
        # are '...' % formatted refusals still exits 0 on every normal run.
        aborts_only = os.path.join(root, "repo-aborts-only")
        os.makedirs(os.path.join(aborts_only, "scripts"))
        with open(os.path.join(aborts_only, "scripts", "sabotage-planted.py"), "w") as handle:
            handle.write('''
import sys
def main():
    target = "x"
    if target:
        sys.exit("REFUSING: %s has uncommitted changes" % target)
    print("scored")
if __name__ == "__main__":
    main()
''')
        for command in (["init", "-q", "-b", "main"], ["add", "-A"],
                        ["-c", "user.email=t@t", "-c", "user.name=t",
                         "commit", "-qm", "planted"]):
            subprocess.run(["git", "-C", aborts_only, *command], check=True, capture_output=True)
        abort_rows = [r for r in scan(root) if r["repo"] == "repo-aborts-only"]
        if len(abort_rows) != 1 or abort_rows[0]["verdict"] != BARE_CALLER:
            failures.append("repo-aborts-only: expected %r, got %r — a formatted "
                            "abort message was credited as a status exit"
                            % (BARE_CALLER, [r["verdict"] for r in abort_rows]))

        # The engine must come from the SCORER'S ref, not from whatever the repo
        # happens to have checked out. Planted as a repo whose main carries a
        # status engine and whose branch carries a report engine, both with the
        # same wrapped caller: resolving against the working tree calls the
        # branch OK and hides the one defect this scan exists to find.
        drift = os.path.join(root, "repo-drift")
        os.makedirs(os.path.join(drift, "scripts"))
        engine_at = os.path.join(drift, "scripts", ENGINE_BASENAME)
        with open(engine_at, "w") as handle:
            handle.write(ENGINE_STATUS)
        with open(os.path.join(drift, "scripts", "sabotage-planted.py"), "w") as handle:
            handle.write(CALLER_EXIT)
        for command in (["init", "-q", "-b", "main"], ["add", "-A"],
                        ["-c", "user.email=t@t", "-c", "user.name=t",
                         "commit", "-qm", "status engine on main"],
                        ["checkout", "-q", "-b", "stale"]):
            subprocess.run(["git", "-C", drift, *command], check=True, capture_output=True)
        with open(engine_at, "w") as handle:
            handle.write(ENGINE_REPORT)
        for command in (["add", "-A"],
                        ["-c", "user.email=t@t", "-c", "user.name=t",
                         "commit", "-qm", "report engine on stale"],
                        ["checkout", "-q", "main"]):
            subprocess.run(["git", "-C", drift, *command], check=True, capture_output=True)
        drift_rows = {r["ref"]: r["verdict"] for r in scan(root) if r["repo"] == "repo-drift"}
        if drift_rows.get("main") != OK:
            failures.append("repo-drift main: expected %r, got %r"
                            % (OK, drift_rows.get("main")))
        if drift_rows.get("stale") != EXIT_OF_REPORT:
            failures.append("repo-drift stale: expected %r, got %r — the engine was "
                            "read from the working tree, not from the scorer's ref"
                            % (EXIT_OF_REPORT, drift_rows.get("stale")))

        # The scan must also refuse to invent a pair where the engine is absent.
        orphan = os.path.join(root, "repo-orphan")
        os.makedirs(os.path.join(orphan, "scripts"))
        with open(os.path.join(orphan, "scripts", "sabotage-planted.py"), "w") as handle:
            handle.write(CALLER_EXIT)
        for command in (["init", "-q", "-b", "main"], ["add", "-A"],
                        ["-c", "user.email=t@t", "-c", "user.name=t",
                         "commit", "-qm", "planted"]):
            subprocess.run(["git", "-C", orphan, *command], check=True, capture_output=True)
        orphan_rows = [r for r in scan(root) if r["repo"] == "repo-orphan"]
        if len(orphan_rows) != 1 or orphan_rows[0]["verdict"] != NO_ENGINE:
            failures.append("repo-orphan: expected %r, got %r"
                            % (NO_ENGINE, [r["verdict"] for r in orphan_rows]))

    for failure in failures:
        print("  FAIL " + failure)
    if failures:
        print("self-test FAILED")
        return 1
    print("self-test passed: %d caller/engine pairings separated; delegated status "
          "credited; self-contained main() judged in both directions; a formatted "
          "abort not mistaken for a status; engine read from the scorer's own ref; "
          "absent entry point not invented" % len(expected))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--self-test", action="store_true",
                        help="plant all four pairings and check the scan separates them")
    parser.add_argument("--verbose", action="store_true",
                        help="print sound pairs too, not only broken ones")
    parser.add_argument("--root", default=REPO_ROOT)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return report(scan(args.root, args.verbose), args.verbose)


if __name__ == "__main__":
    sys.exit(main())
