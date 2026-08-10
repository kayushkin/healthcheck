#!/usr/bin/env python3
"""Find functions in a sabotage scorer's own target files that no mutation names.

A sabotage scorer breaks one thing at a time in a file it calls a TARGET, then
runs the suite to see whether anything went red. Its score is a fraction whose
denominator is its own case list. A function inside a target file that no case
touches can never appear in any verdict: not CAUGHT, not UNNOTICED, not even
GUARD ONLY. The scorer is structurally silent about it, and a reader who sees
35/35 has no way to tell that silence from coverage.

This is the source-side twin of `sabotage.py --crosstable`. That mode asks which
TESTS no case reddens. This asks which FUNCTIONS no case breaks. Both questions
are invisible from the score, and they fail in the same flattering direction:
the fewer mechanisms a plan names, the easier full marks are.

    python3 scripts/sabotage-scorer-unmutated-function-scan.py [--self-test] [--verbose]

It reports; it changes nothing.

## Its exit status deliberately does NOT report the finding

Exit 0 when the scan measured everything it tried to, 1 only when it could not
measure — an unparseable scorer, or a target path it could not resolve. That is
the opposite of its two sibling scans, and the reason is the whole difficulty
here: **a silent region is only a defect if the plan claimed to cover the file,
and that claim lives in prose.** Sixty-four of the 74 target files measured on
this box have one, and most are correct. A scan that exited 1 on all of them
would be permanently red, and a permanently red check is one nobody reads — so
it would report its finding by making itself ignorable.

## Why this is a different question from a per-file gut score

Card 0c9ead3e was filed after miditab's per-file plan scored 8/8 CAUGHT while
aiming one mutation at each named mechanism in the same five files scored 4 of
43. A per-file gut asks whether a file is REACHABLE. It answers green whether
the suite watches one code path or nine. This scan asks the finer question
directly, and it asks it of the plan rather than of the suite, so it needs no
build and no test run.

## The answer, taken 2026-08-10

**27 scorer files, 39 blob versions, 74 target files, across 17 repositories.
64 of the 74 carry a silent region; 10 are named right through.** Two more
scorers (chat-core, miditab) target TypeScript and are out of this scan's reach.

Card 0c9ead3e asked whether other repos carry miditab's per-file gut. **None
does** — every plan on this box is already per-mechanism in shape, and the only
whole-file guts anywhere are in miditab's own `control-positive-per-file.json`,
which is labelled as that and exists to be one.

The plans split in two, and only one half can carry the defect:

  - **Scoped plans** — the `sabotage-truncation.py`, `sabotage-apostrophe.py` and
    `sabotage-identity.py` family, 13 repos. These score ONE mechanism at its
    several call sites, so they name 1–3 functions per file however large the
    file is: inber-party's truncation scorer names 1 of 117 functions in
    `internal/api/api.go` and 7 of 180 overall. **That is correct behaviour, not
    a gap**, and this scan reports it identically to a real one.
  - **Per-binary plans** — the scheduler family, which targets one
    `cmd/X/main.go` and claims it, so a silent region is a real hole. Measured:
    `cmd/ask` 5/6 named, kanbanclient 15/20, autoworker 18/25,
    kanban-classifier 21/34, `cmd/scheduler` 3/5, kanban-dispatcher 8/21,
    kanban-curator 3/10, and the outlier below.

**The one finding worth a card: `scheduler/scripts/sabotage-reminder-coordinator.py`
names 15 of 52 functions** in `cmd/reminder-coordinator/main.go` — 37 silent —
on the blob **34 scheduler branches carry**. `writeDigestNote` (37 body lines),
`OnDay` (45) and `renderDigest` are among them. It is both the lowest-covered
per-binary plan and by far the largest absolute region: 37 silent functions
against kanban-curator's 7, the next worst. This is the same file whose
`--crosstable` run found 9 of 33 tests unreddened, so both halves of that
scorer's instrument have a silent region, and the two were found by different
questions asked from opposite sides.

⚠️ **A scoped scorer is not under-covering, and this scan cannot tell the
difference, and neither does target count.** It looks like it should — scoped
plans hit several call sites, per-binary plans hit one file — but it separates
nothing: `sabotage-autoworker.py` names two targets and is per-binary, while
llm-bridge-claudecode, llm-bridge-codex and llm-bridge-jig each name exactly one
(`discover.go`) and are scoped. Read the scorer's docstring before believing a
row. The question "does this plan claim to cover this file?" is not one a static
scan can answer, and answering it wrongly in the permissive direction is how a
coverage number gets inflated.

⚠️ **Five scorers name a `_test.go` file as a target** — llm-bridge-tui
(`internal/ui/runecut_test.go`, 0 of 8), logstack
(`cmd/openclaw-logpush/main_test.go`, 0 of 6), llm-bridge
(`examples/sse-tail/main_test.go`, 0 of 7), downloadstack (`runecut_test.go`,
1 of 4) and llm-bridge-copilotcli (`identity_test.go`, 2 of 6). A test file's
"functions" are tests, and a plan naming few of them is the ordinary case, not a
hole — these scorers mutate a test to prove a reach-guard fires. They are
reported rather than filtered, because a scorer that can rewrite its own tests
is worth seeing.

## How a mutation is attributed to a function

Every needle a scorer applies must be a string literal somewhere in the scorer,
whatever shape the plan is packaged in — this box carries five (constructor
calls, tuple lists, `dict(defect=...)`, JSON plan files, and the scheduler
engine's `Case(name, [(find, replace)])`). Rather than teach the scan five
encodings and be blind to the sixth, it collects every non-docstring string
literal in the scorer and asks where each one lands.

A literal marks a function as named when it occurs **exactly once** across the
scorer's target files at that ref, and that one occurrence lies inside the
function. Uniqueness is not a threshold picked to make the number look right: it
is the engine's own rule. `sabotage.py:_apply_case` refuses a needle found in no
target and refuses one found in more than one, so a literal matching twice is
not a mutation anybody can run.

## The unit is the (scorer blob, ref) pair, not the scorer file

Card 69c04027 measured this for the cross-table and it holds here for the same
reason: the same scorer blob sits on branches whose target source differs, so
the set of functions it fails to name is a property of the pair. The scan walks
every ref, resolves the target file's own blob at that ref, and dedupes by the
answer rather than by the scorer name.

⚠️ **Three blind spots, stated rather than left to be discovered.**

1. **A computed needle is invisible.** A scorer that builds a find-string with an
   f-string or a loop reads to this scan as a scorer with fewer mutations than it
   has, which makes a silent region look real when it is not. Every scorer on
   this box today uses literals; the day one does not, read it by hand rather
   than widening the pattern until the number looks better.
2. **Go targets only.** Function spans are found with a Go `func` pattern.
   Non-Go targets are counted and reported as unparsed, never silently skipped.
3. **`main` is one function like any other.** In these cmd binaries it is often
   the largest, and a plan that deliberately leaves orchestration alone will
   show it here. That is a judgement per hit, which is why this prints names
   rather than only a count.
"""

import argparse
import ast
import os
import re
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.expanduser("~/repos")

# A Go function or method header. The name is the first identifier after any
# receiver, which is what makes `func (d *daemon) Run()` report as `Run`.
GO_FUNCTION_HEADER = re.compile(r"^func (?:\([^)]*\)\s*)?([A-Za-z_]\w*)", re.M)


def repositories(root):
    """Directories under root that are real git repositories.

    `.git` must be a DIRECTORY. A linked worktree's `.git` is a file pointing at
    the parent's admin dir, and counting those would read scheduler's refs five
    extra times — this box carries four scheduler worktrees.
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


def _git_optional(repo, *args):
    """Like _git, but None when the object does not exist at that ref.

    A target path that a scorer names but that ref does not carry is ordinary —
    scorers travel onto branches written before their target existed — so it
    must not abort the whole scan.
    """
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else None


def scorer_blobs(repo):
    """{(path, blob sha): {refs carrying it}} for every sabotage case file.

    `sabotage.py` is the shared engine, not a scorer: it declares no targets and
    carries no cases, so counting it would put a permanent zero-target row in
    every report. `sabotage-pairs.py` and `sabotage-sweep.py` plan and drive the
    fleet sweep rather than scoring a binary, and are excluded for the same
    reason — they name target paths in prose and would read as scorers with
    targets they never break.
    """
    excluded = {"sabotage.py", "sabotage-pairs.py", "sabotage-sweep.py"}
    # A `-scan.py` is a fleet scan, not a per-binary scorer: it breaks nothing
    # and its self-test fixtures are Go source held in string literals. Reading
    # one as a scorer makes its fixtures look like targets, which is how this
    # scan first reported healthcheck's own denominator scan as having a gap.
    blobs = {}
    refs = _git(repo, "for-each-ref", "--format=%(refname:short)",
                "refs/heads", "refs/remotes").split()
    for ref in refs:
        for line in _git(repo, "ls-tree", "-r", ref).splitlines():
            parts = line.split("\t")
            if len(parts) != 2:
                continue
            sha = parts[0].split()[2]
            path = parts[1]
            base = os.path.basename(path)
            if "node_modules" in path:
                continue
            if base.endswith("-scan.py"):
                continue
            if base.endswith(".py") and "sabotage" in base and base not in excluded:
                blobs.setdefault((path, sha), set()).add(ref)
    return blobs


def _normalise(raw):
    return raw.strip().lstrip("./").rstrip("/")


def _path_from_division(node):
    """Reconstruct "a/b/c.go" from a `REPO / "a" / "b" / "c.go"` expression.

    Returns None for any `/` expression that is not a chain of string literals
    rooted at a bare name. Division on numbers reaches here too and must not be
    mistaken for a path. Taken from sabotage-scorer-denominator-scan.py, where a
    first version that matched only literals containing a slash reported two
    innocent repos as having no targets at all.
    """
    segments = []
    while isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
        right = node.right
        if not (isinstance(right, ast.Constant) and isinstance(right.value, str)):
            return None
        segments.insert(0, right.value)
        node = node.left
    if not isinstance(node, ast.Name):
        return None
    return "/".join(s.strip("/") for s in segments)


def _docstring_nodes(tree):
    marked = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if ast.get_docstring(node, clean=False) is not None:
                marked.add(id(node.body[0].value))
    return marked


def analyse(source):
    """(candidate targets, needles) — paths a scorer might break, and its literals.

    A candidate is any non-docstring literal naming a `.go` file, plus the
    `REPO / "a" / "b.go"` division shape. Candidates are NOT filtered here on
    whether they look like a path: `scan` resolves each against the ref and
    keeps the ones that exist. Checking against the tree rather than against a
    pattern is what lets this see `TARGET = Path("audiobook.go")`, a
    repo-root-relative target with no slash in it, which an earlier version
    missed in nine scorers across seven repos — while still discarding
    `runtime/panic.go`, which llm-bridge-copilotcli's docstring mentions in
    prose and no repo carries.

    Needles are every non-docstring string literal. Most are not needles at all
    — they are labels, notes and package paths — but a literal that is not a
    needle simply fails to occur in a target file and marks nothing. Over-
    collecting is safe in the direction that matters: it can only make a
    function look MORE covered, so a silent region this scan reports is one no
    literal in the whole scorer lands in.
    """
    tree = ast.parse(source)
    docstrings = _docstring_nodes(tree)

    targets = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            joined = _path_from_division(node)
            if joined and joined.endswith(".go"):
                targets.add(_normalise(joined))
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            value = node.value
            if (id(node) not in docstrings and value.endswith(".go")
                    and "\n" not in value):
                targets.add(_normalise(value))

    needles = set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.Constant) and isinstance(node.value, str)
                and id(node) not in docstrings and node.value.strip()):
            needles.add(node.value)
    return targets, needles


def function_spans(source):
    """[(name, start, end)] byte offsets of each Go function in source.

    A span runs from its own `func` keyword to the next one, so anything between
    two functions — a var block, a comment — belongs to the function above it.
    That is the wrong home for a package-level declaration, and it is the safe
    direction: it can only mark a function as named, never as silent.
    """
    headers = [(m.start(), m.group(1)) for m in GO_FUNCTION_HEADER.finditer(source)]
    spans = []
    for index, (start, name) in enumerate(headers):
        end = headers[index + 1][0] if index + 1 < len(headers) else len(source)
        spans.append((name, start, end))
    return spans


def unnamed_functions(target_sources, needles):
    """{target: (all functions, the ones no needle lands in)}.

    A needle counts only when it occurs exactly once across ALL targets, which
    is the engine's rule in sabotage.py:_apply_case — a needle found nowhere is
    an ABORT, and one found twice is an ABORT, so neither is a mutation that can
    run.
    """
    combined = list(target_sources.items())
    named = {path: set() for path in target_sources}
    for needle in needles:
        holders = [(path, source.count(needle)) for path, source in combined]
        total = sum(count for _, count in holders)
        if total != 1:
            continue
        path = next(p for p, count in holders if count == 1)
        offset = target_sources[path].index(needle)
        for name, start, end in function_spans(target_sources[path]):
            if start <= offset < end:
                named[path].add(name)
                break

    result = {}
    for path, source in target_sources.items():
        every = [name for name, _, _ in function_spans(source)]
        result[path] = (every, [n for n in every if n not in named[path]])
    return result


def scan(root):
    """One row per (scorer blob, distinct answer). See the docstring on pairs."""
    rows = []
    for repo in repositories(root):
        repo_name = os.path.basename(repo)
        for (path, sha), refs in sorted(scorer_blobs(repo).items()):
            source = _git(repo, "cat-file", "-p", sha)
            try:
                targets, needles = analyse(source)
            except SyntaxError as exc:
                rows.append({"repo": repo_name, "path": path, "sha": sha,
                             "refs": sorted(refs), "error": str(exc)})
                continue

            # Group refs by the target content they resolve to, so a scorer
            # sitting on 34 branches with one source answer prints one row.
            by_answer = {}
            for ref in sorted(refs):
                # A candidate that the ref does not carry is not a target this
                # scorer breaks — it is a path named in prose, a self-test
                # fixture, or a file that branch predates. Dropping it is the
                # filter; see analyse().
                # Three conventions for what a target path is relative to, all
                # live on this box: the repository root (most scorers, which say
                # REPO = Path(__file__).parent.parent from scripts/); the
                # scorer's grandparent, which is the same directory for those
                # and differs for a scorer nested deeper; and the scorer's OWN
                # directory — llm-bridge's `SOURCE = "main.go"` in
                # examples/sse-tail/ is run from there. Trying only the root
                # made all three of that scorer's targets read as missing.
                here = os.path.dirname(path)
                bases = ["", os.path.dirname(here), here]
                sources = {}
                for target in sorted(targets):
                    for candidate in dict.fromkeys(
                            os.path.normpath(os.path.join(b, target)) for b in bases):
                        text = _git_optional(repo, "show", "%s:%s" % (ref, candidate))
                        if text is not None:
                            sources[candidate] = text
                            break
                unresolved = []
                key = tuple(sorted((t, hash(s)) for t, s in sources.items()))
                by_answer.setdefault(key, (sources, unresolved, []))[2].append(ref)

            for sources, unresolved, group in by_answer.values():
                rows.append({"repo": repo_name, "path": path, "sha": sha,
                             "refs": group, "error": None,
                             "targets": sorted(targets),
                             "named_go_candidate": bool(targets),
                             "result": unnamed_functions(sources, needles) if sources else {}})
    return rows


def report(rows, verbose=False):
    files = {(r["repo"], r["path"]) for r in rows}
    blobs = {(r["repo"], r["path"], r["sha"]) for r in rows}
    repos = {r["repo"] for r in rows}
    print("%d scorer files, %d blob versions, across %d repositories"
          % (len(files), len(blobs), len(repos)))

    unparsed = [r for r in rows if r.get("error")]
    for row in unparsed:
        print("  ⚠️  could not parse %s %s: %s" % (row["repo"], row["path"], row["error"]))

    # Two different silences, and collapsing them would hide the second.
    out_of_scope = [r for r in rows
                    if not r.get("error") and not r.get("result")
                    and not r.get("named_go_candidate")]
    unmeasurable = [r for r in rows
                    if not r.get("error") and not r.get("result")
                    and r.get("named_go_candidate")]
    if out_of_scope:
        print("  %d scorer versions name no Go file at all — a non-Go scorer this "
              "scan cannot read, not a clean result" % len(out_of_scope))
    for row in unmeasurable:
        print("  ⚠️  %s %s @%s names Go files that no ref carries (%s) — it builds its "
              "targets at runtime; read it by hand rather than widening the pattern"
              % (row["repo"], row["path"], row["sha"][:8], ", ".join(row["targets"][:3])))

    gaps = []
    for row in rows:
        for target, (every, unnamed) in (row.get("result") or {}).items():
            if unnamed:
                gaps.append((row, target, every, unnamed))
    gaps.sort(key=lambda g: -len(g[3]))

    print("\n============ functions in a target file that no mutation names ============")
    print("Read each scorer's docstring before calling a row a gap: a plan scoped to")
    print("one mechanism names few functions on purpose. See this file's own docstring.")
    if not gaps:
        print("  none — every function in every target file is named by some mutation")
    for row, target, every, unnamed in gaps:
        print("\n  %s  %s  @%s" % (row["repo"], row["path"], row["sha"][:8]))
        print("    refs     : %s%s"
              % (", ".join(row["refs"][:4]),
                 (" (+%d more)" % (len(row["refs"]) - 4)) if len(row["refs"]) > 4 else ""))
        print("    target   : %s" % target)
        print("    named    : %d of %d functions, %d silent"
              % (len(every) - len(unnamed), len(every), len(unnamed)))
        print("    silent   : %s" % ", ".join(unnamed))

    if verbose:
        print("\n================ every scorer read ================")
        for row in rows:
            if row.get("error"):
                continue
            for target, (every, unnamed) in (row.get("result") or {}).items():
                print("  %-16s %-46s @%s %-40s %2d/%2d named"
                      % (row["repo"], os.path.basename(row["path"]), row["sha"][:8],
                         target, len(every) - len(unnamed), len(every)))

    measured = sum(len(row.get("result") or {}) for row in rows)
    gap_files = {(g[0]["repo"], g[0]["path"]) for g in gaps}
    print("\n%d of %d scorer files leave a function unnamed, over %d of %d target files"
          % (len(gap_files), len(files), len(gaps), measured))

    # See the docstring: the exit status reports whether the scan could measure,
    # NOT whether it found a silent region. A silent region is only a defect if
    # the plan claimed to cover the file, which is a judgement this scan cannot
    # make, so encoding it here would be a claim the code cannot support.
    could_not_measure = unparsed + unmeasurable
    if could_not_measure:
        print("%d scorer versions could not be measured — see the ⚠️ lines above"
              % len(could_not_measure))
    return 1 if could_not_measure else 0


SELF_TEST_SCORER = '''\
"""A scorer with one target and two mutations.

This docstring names cmd/thing/silent.go, which the scan must NOT count as a
needle — a path in prose sabotages nothing.
"""
from sabotage import REPO, Case, score

TARGET = REPO / "cmd/thing/main.go"
PACKAGES = ["./cmd/thing/"]

CASES = [
    Case("the greeting is dropped", [("return greeting + name", "return name")]),
    Case("the count never increments", [("total = total + 1", "total = total")]),
    Case("this needle is in two functions", [("shared := true", "shared := false")]),
]

if __name__ == "__main__":
    raise SystemExit(score(TARGET, PACKAGES, CASES))
'''

SELF_TEST_TARGET = '''\
package main

func greet(greeting, name string) string {
	shared := true
	_ = shared
	return greeting + name
}

func tally(total int) int {
	shared := true
	_ = shared
	total = total + 1
	return total
}

func neverMutated(x int) int {
	return x * 2
}

func (d *daemon) Run() error {
	return nil
}
'''


def self_test():
    """Check the scan reports a planted silent function and no false one.

    The 101st nightly pass's rule: prove the instrument can say "yes" before
    believing it saying "no". A scan that reports nothing because it is broken
    and a scan that reports nothing because the fleet is clean print the same
    output, so both directions are asserted here.
    """
    failures = []

    targets, needles = analyse(SELF_TEST_SCORER)
    if targets != {"cmd/thing/main.go"}:
        failures.append("targets read as %s, want the one segmented path" % sorted(targets))
    if "cmd/thing/silent.go" in needles:
        failures.append("a path named only in the docstring was collected as a needle")

    result = unnamed_functions({"cmd/thing/main.go": SELF_TEST_TARGET}, needles)
    every, unnamed = result["cmd/thing/main.go"]

    if [n for n in every] != ["greet", "tally", "neverMutated", "Run"]:
        failures.append("function spans read as %s" % every)

    # Says "yes": the two functions a needle lands in are not reported silent.
    for named in ("greet", "tally"):
        if named in unnamed:
            failures.append("%s holds a unique needle but was reported silent" % named)

    # Says "no": the function no needle reaches is reported.
    if "neverMutated" not in unnamed:
        failures.append("neverMutated is named by no mutation and was not reported")

    # A method's name is the identifier after the receiver, not the receiver.
    if "Run" not in unnamed:
        failures.append("a method with no mutation was not reported")

    # The needle appearing in two functions is not a runnable mutation, so it
    # must mark neither of them — the engine would ABORT on it.
    solo = unnamed_functions({"cmd/thing/main.go": SELF_TEST_TARGET}, {"shared := true"})
    if solo["cmd/thing/main.go"][1] != ["greet", "tally", "neverMutated", "Run"]:
        failures.append("a needle matching twice marked a function anyway: %s"
                        % solo["cmd/thing/main.go"][1])

    # A scan over a clean plan must report nothing, or a green run means nothing.
    covered = unnamed_functions(
        {"cmd/thing/main.go": "package main\n\nfunc only() int {\n\treturn 41\n}\n"},
        {"return 41"})
    if covered["cmd/thing/main.go"][1]:
        failures.append("a fully covered target reported a silent function: %s"
                        % covered["cmd/thing/main.go"][1])

    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "real-repo", ".git"))
        with open(os.path.join(tmp, "linked-worktree.git-file"), "w"):
            pass
        os.makedirs(os.path.join(tmp, "linked-worktree"))
        with open(os.path.join(tmp, "linked-worktree", ".git"), "w") as handle:
            handle.write("gitdir: /elsewhere\n")
        found = [os.path.basename(p) for p in repositories(tmp)]
        if found != ["real-repo"]:
            failures.append("repository walk counted the wrong directories: %s" % found)

    for failure in failures:
        print("  ⚠️  " + failure)
    if failures:
        print("self-test FAILED")
        return 1
    print("self-test passed")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true",
                        help="check the scan reports a planted silent function and no false one")
    parser.add_argument("--verbose", action="store_true",
                        help="list every target read, not just the ones with a silent region")
    parser.add_argument("--root", default=REPO_ROOT)
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    return report(scan(args.root), verbose=args.verbose)


if __name__ == "__main__":
    sys.exit(main())
