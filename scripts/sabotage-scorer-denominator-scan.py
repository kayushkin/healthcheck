#!/usr/bin/env python3
"""Find sabotage scorers that run a package no mutation of theirs can reach.

A sabotage scorer names two things: the FILES it breaks on purpose (its targets)
and the PACKAGES whose tests it runs to see whether anything went red. If a
package is in the second list and no target lives inside it, every test in that
package is in the scorer's denominator and can never be in its numerator. The
score is quietly divided by tests the instrument cannot move.

Measured first in scheduler: sabotage-kanban-dispatcher.py ran
./internal/kanbanclient/ while sabotaging only cmd/kanban-dispatcher/main.go, so
both of that package's tests sat permanently in the cross-table's silent column.
Card 1495e79d asked how many other scorers on this box carry the same gap. This
script is that question, asked once and re-askable.

    python3 scripts/sabotage-scorer-denominator-scan.py [--self-test] [--verbose]

Exit 0 when no scorer has an uncovered package, 1 when one does. It reports; it
changes nothing.

## The answer, taken 2026-08-09

**24 scorer files, 38 blob versions, across 16 repositories. TWO files carry the
gap, both in scheduler, and only one of them still carries it at its newest
revision.**

  - `scripts/sabotage-kanban-dispatcher.py` — `./internal/kanbanclient/` in
    PACKAGES, never a target. This is the one card 1495e79d was filed for; fixed
    on `test/kanbanclient-has-a-sabotage-scorer`, where the client got a scorer
    of its own. Three older blob versions on other branches still carry it.
  - `scripts/sabotage-kanban-curator.py` @98d40527 — `./internal/kanbanvocab/` in
    PACKAGES, never a target. **Nobody knew about this one.** It is on three
    branches dated 2026-08-08 21:56–21:59, and a later blob dropped the package
    from the list. So the identical gap was opened and closed within one day, on
    parallel branches, by passes that could not see each other — and the closing
    was never recorded as closing anything.

The rest of the fleet is clean: inber-party, logstack, multichat and tool-store
each run several packages and every one of them holds a target. Eight scorer
versions declare no PACKAGES at all — a repo-root-relative generation that runs
one test file — and the gap cannot exist for them.

**Two of 24 is the number, and the interesting half is that one of the two found
itself.** A gap this scan exists to name was already being fixed by hand, silently,
by people who thought they were tidying a list.

## It reads refs, not the working tree

`grep -rn .` reads whichever branch a repo has checked out, and ten of this box's
repos are parked off trunk (see fleet-scan-ref-preamble.sh, which documents what
that cost). Most sabotage scorers on this box live only on unmerged test/ and
fix/ branches, so a working-tree scan would miss almost all of them. This walks
every local and remote ref with `git ls-tree` and dedupes by blob hash, then
reports which refs carry each version.

## How a target is recognised, and where that can be wrong

Scorers declare targets in at least two shapes:

    TARGET  = REPO / "cmd/kanban-dispatcher/main.go"     # one literal
    HELPER  = REPO / "internal" / "matrix" / "truncate.go"   # one segment each

so the scan reconstructs `/` expressions into a path rather than looking for a
variable called TARGET. A first version matched string literals containing both
a slash and `.go`, and reported multichat and tool-store as having NO targets at
all — they build their paths segment by segment, and no single segment has a
slash in it. That was the scan's defect, not theirs, and it pointed the finger at
two innocent repos. Hence the `--self-test`, which carries that exact shape.

⚠️ **The scan's own blind spot, stated rather than left to be discovered.** It
recognises paths that are literal in the source. A scorer that computes a target
at runtime — from a glob, an argv, a loop over a directory — reads to this scan
as a scorer with fewer targets than it has, which makes a gap look real when it
is not. Every scorer on this box today is literal; the day one is not, this
prints a false positive and the fix is to read that scorer by hand, not to widen
the pattern until the number looks right.
"""

import argparse
import ast
import os
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.expanduser("~/repos")


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


def scorer_blobs(repo):
    """{(path, blob sha): {refs carrying it}} for every sabotage case file.

    sabotage.py itself is the shared engine, not a scorer — it declares no
    targets and no packages, and counting it would put a permanent zero-target
    row in every report.
    """
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
            if base.endswith(".py") and "sabotage" in base and base != "sabotage.py":
                blobs.setdefault((path, sha), set()).add(ref)
    return blobs


def _normalise(raw):
    return raw.strip().lstrip("./").rstrip("/")


def _path_from_division(node):
    """Reconstruct "a/b/c.go" from a `REPO / "a" / "b" / "c.go"` expression.

    Returns None for any `/` expression that is not a chain of string literals
    rooted at a bare name. Division on numbers reaches here too and must not be
    mistaken for a path.
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
    """(targets, packages) — the files a scorer breaks and the packages it runs."""
    tree = ast.parse(source)
    docstrings = _docstring_nodes(tree)

    packages = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            if any(isinstance(t, ast.Name) and t.id == "PACKAGES" for t in node.targets):
                for element in ast.walk(node.value):
                    if isinstance(element, ast.Constant) and isinstance(element.value, str):
                        packages.add(_normalise(element.value))

    targets = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            joined = _path_from_division(node)
            if joined and joined.endswith(".go"):
                targets.add(_normalise(joined))
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            value = node.value
            if (id(node) not in docstrings and value.endswith(".go")
                    and "/" in value and "\n" not in value):
                targets.add(_normalise(value))
    return targets, packages


def uncovered_packages(targets, packages):
    """Packages holding no target — tests no mutation of this scorer can redden."""
    return sorted(
        package for package in packages
        if not any(target == package or target.startswith(package + "/")
                   for target in targets)
    )


def scan(root, verbose=False):
    rows = []
    for repo in repositories(root):
        name = os.path.basename(repo)
        for (path, sha), refs in sorted(scorer_blobs(repo).items()):
            source = _git(repo, "cat-file", "-p", sha)
            try:
                targets, packages = analyse(source)
            except SyntaxError as exc:
                rows.append((name, path, sha, sorted(refs), set(), set(), None, str(exc)))
                continue
            rows.append((name, path, sha, sorted(refs), targets, packages,
                         uncovered_packages(targets, packages), None))
    return rows


def report(rows, verbose=False):
    files = {(r[0], r[1]) for r in rows}
    repos = {r[0] for r in rows}
    print("%d scorer files, %d blob versions, across %d repositories"
          % (len(files), len(rows), len(repos)))

    unparsed = [r for r in rows if r[7]]
    for row in unparsed:
        print("  ⚠️  could not parse %s %s: %s" % (row[0], row[1], row[7]))

    # A scorer with no PACKAGES list cannot have this gap: it does not name a
    # package to run, so there is no denominator to divide wrongly. Saying "read
    # it by hand" about those buries the ones that DO need reading — measured
    # 2026-08-09, eight of the eight targetless scorers on this box declare no
    # PACKAGES at all and none of them was worth the hand read the scan demanded.
    needs_reading = [r for r in rows if not r[7] and not r[4] and r[5]]
    exempt = [r for r in rows if not r[7] and not r[4] and not r[5]]
    for row in needs_reading:
        print("  ⚠️  %s %s @%s declares packages but no target this scan can see — "
              "read it by hand; the scan only recognises literal paths"
              % (row[0], row[1], row[2][:8]))
    if exempt:
        print("  %d scorer versions declare no PACKAGES and so cannot carry this gap"
              % len(exempt))

    gaps = [r for r in rows if r[6]]
    print("\n================ packages no mutation can reach ================")
    if not gaps:
        print("  none — every package a scorer runs holds at least one of its targets")
    for repo, path, sha, refs, targets, packages, uncovered, _ in gaps:
        print("\n  %s  %s  @%s" % (repo, path, sha[:8]))
        print("    refs      : %s" % ", ".join(refs))
        print("    targets   : %s" % ", ".join(sorted(targets)))
        print("    packages  : %s" % ", ".join(sorted(packages)))
        print("    UNCOVERED : %s" % ", ".join(uncovered))

    if verbose:
        print("\n================ every scorer read ================")
        for repo, path, sha, refs, targets, packages, uncovered, err in rows:
            print("  %-24s %-46s @%s  targets=%d packages=%d uncovered=%d"
                  % (repo, path, sha[:8], len(targets), len(packages),
                     len(uncovered or [])))

    gap_files = {(r[0], r[1]) for r in gaps}
    print("\n%d of %d scorer files carry an uncovered package (%d of %d blob versions)"
          % (len(gap_files), len(files), len(gaps), len(rows)))
    return 1 if (gaps or unparsed or needs_reading) else 0


SELF_TEST_WITH_GAP = '''\
"""A scorer whose PACKAGES names a package none of its targets live in.

This docstring mentions internal/decoy/decoy.go, which the scan must NOT count
as a target — a path named in prose is not a path anybody sabotages.
"""
from sabotage import REPO, score

TARGET = REPO / "cmd/thing/main.go"
PACKAGES = ["./cmd/thing/", "./internal/shared/"]
'''

SELF_TEST_SEGMENTED = '''\
"""A scorer that builds its target one path segment at a time."""
from sabotage import REPO, score

HELPER = REPO / "internal" / "shared" / "helper.go"
PACKAGES = ["./internal/shared/"]
'''


def self_test():
    """Require the scan to report the gap it exists to find, and to stay quiet
    on the shape that once produced a false positive.

    The second case is the one that matters. An earlier version of this scan
    matched only string literals containing a slash, so a target written
    segment-by-segment was invisible and its repo was reported as having no
    targets at all — a clean gap report about a scorer with no gap. A self-test
    that only checked the positive would have passed while doing that.
    """
    failures = []

    targets, packages = analyse(SELF_TEST_WITH_GAP)
    uncovered = uncovered_packages(targets, packages)
    if targets != {"cmd/thing/main.go"}:
        failures.append("single-literal target not read: got %s" % sorted(targets))
    if uncovered != ["internal/shared"]:
        failures.append("the planted gap was not reported: got %s" % uncovered)

    targets, packages = analyse(SELF_TEST_SEGMENTED)
    uncovered = uncovered_packages(targets, packages)
    if targets != {"internal/shared/helper.go"}:
        failures.append("segment-built target not reconstructed: got %s" % sorted(targets))
    if uncovered:
        failures.append("false positive on a scorer with no gap: %s" % uncovered)

    # And the walk: a linked worktree must not be counted as a repository.
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "real-repo", ".git"))
        os.makedirs(os.path.join(tmp, "plain-dir"))
        with open(os.path.join(tmp, "linked-worktree-git"), "w"):
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
                        help="check the scan reports a planted gap and no false one")
    parser.add_argument("--verbose", action="store_true",
                        help="list every scorer read, not just the ones with a gap")
    parser.add_argument("--root", default=REPO_ROOT)
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    return report(scan(args.root), verbose=args.verbose)


if __name__ == "__main__":
    sys.exit(main())
