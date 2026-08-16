#!/usr/bin/env python3
"""Sibling-repo census for the fleet unicode byte-cut sweep (card 2b5f73a5).

Population is the FUNCTION, not the line. For every helper the sweep has already
repaired on `fix/truncation-never-splits-a-rune`, find every other repository
carrying a copy of that helper — repaired, unrepaired, or absent — reading each
repository at its named trunk ref rather than at whatever its working tree
happens to be parked on.
"""

import json
import os
import re
import subprocess
import sys

REPOS_ROOT = os.path.expanduser("~/repos")
FIX_BRANCH = "fix/truncation-never-splits-a-rune"
EXCLUDED_REPOS = {"claude-squad", "happy"}


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", repo] + list(args),
        capture_output=True, text=True)
    return result.stdout


def fleet_repositories():
    """Every real repository under ~/repos: no linked worktrees, no vendored trees.

    EXTRA_ROOTS exists for the positive control: a clean cross-repo column and a
    matcher that structurally cannot report one print the same result, so the
    scan is pointed at a planted carrier before its empty column is believed.
    """
    roots = [REPOS_ROOT] + [r for r in os.environ.get("EXTRA_ROOTS", "").split(":") if r]
    found = []
    for root in roots:
        for name in sorted(os.listdir(root)):
            if "-wt-" in name or name in EXCLUDED_REPOS:
                continue
            path = os.path.join(root, name)
            # A linked worktree's .git is a FILE, not a directory. Counting one
            # double-counts its parent's blobs and reports its branch as a parked repo.
            if not os.path.isdir(os.path.join(path, ".git")):
                continue
            found.append((name, path))
    return found


def trunk_of(repo):
    for candidate in ("main", "master"):
        if git(repo, "rev-parse", "--verify", "--quiet", candidate).strip():
            return candidate
    return None


def go_files_at(repo, ref):
    listing = git(repo, "ls-tree", "-r", "--name-only", ref)
    return [p for p in listing.splitlines()
            if p.endswith(".go") and not p.endswith("_test.go")]


COMMENT_PATTERN = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
FUNC_HEADER_PATTERN = re.compile(r"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*\(", re.M)


def functions_in(source):
    """Every top-level function in a Go source file, as (name, body_text)."""
    out = []
    for match in FUNC_HEADER_PATTERN.finditer(source):
        start = match.start()
        brace = source.find("{", match.end() - 1)
        if brace == -1:
            continue
        depth, index = 0, brace
        while index < len(source):
            char = source[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        if depth != 0:
            continue
        out.append((match.group(1), source[start:index + 1]))
    return out


def signature_of(function_text):
    """Normalise a function so a copy still matches after a RENAME.

    The copilotcli repair renamed `truncate` to `truncateAtRuneBoundary`, so
    matching on the name would report the repaired sibling as absent. Comments
    and whitespace go too: two independently formatted copies of one helper are
    the same helper.
    """
    stripped = COMMENT_PATTERN.sub(" ", function_text)
    stripped = FUNC_HEADER_PATTERN.sub("func NAME(", stripped, count=1)
    return re.sub(r"\s+", "", stripped)


def repaired_helpers():
    """Helpers the sweep actually repaired, keyed by their PRE-fix signature."""
    before, after = {}, {}
    for name, path in fleet_repositories():
        if not git(path, "branch", "--list", FIX_BRANCH).strip():
            continue
        trunk = trunk_of(path)
        if not trunk:
            continue
        base = git(path, "merge-base", trunk, FIX_BRANCH).strip()
        if not base:
            continue
        changed = [p for p in git(path, "diff", "--name-only", base, FIX_BRANCH).splitlines()
                   if p.endswith(".go") and not p.endswith("_test.go")]
        for file_path in changed:
            old = {n: t for n, t in functions_in(git(path, "show", f"{base}:{file_path}"))}
            new = {n: t for n, t in functions_in(git(path, "show", f"{FIX_BRANCH}:{file_path}"))}
            old_signatures = {signature_of(t) for t in old.values()}
            new_signatures = {signature_of(t) for t in new.values()}
            for helper_name, text in old.items():
                sig = signature_of(text)
                if sig in new_signatures:
                    continue  # untouched by the repair
                # Only keep helpers whose body actually performs a byte cut.
                if "[:" not in text:
                    continue
                before.setdefault(sig, []).append((name, file_path, helper_name, text))
            for helper_name, text in new.items():
                sig = signature_of(text)
                if sig not in old_signatures:
                    after.setdefault(sig, []).append((name, file_path, helper_name))
    return before, after


def main():
    before, after = repaired_helpers()
    sys.stderr.write(f"repaired helper bodies (pre-fix):  {len(before)}\n")
    sys.stderr.write(f"repaired helper bodies (post-fix): {len(after)}\n")

    # Walk the whole fleet at trunk and match every function against both sets.
    unrepaired_siblings, repaired_siblings = {}, {}
    for name, path in fleet_repositories():
        trunk = trunk_of(path)
        if not trunk:
            sys.stderr.write(f"  no trunk: {name}\n")
            continue
        for file_path in go_files_at(path, trunk):
            source = git(path, "show", f"{trunk}:{file_path}")
            if "[:" not in source and "RuneStart" not in source:
                continue
            for helper_name, text in functions_in(source):
                sig = signature_of(text)
                if sig in before:
                    unrepaired_siblings.setdefault(sig, []).append(
                        (name, trunk, file_path, helper_name))
                elif sig in after:
                    repaired_siblings.setdefault(sig, []).append(
                        (name, trunk, file_path, helper_name))

    json.dump({
        "before": {k: v for k, v in before.items()},
        "after": {k: v for k, v in after.items()},
        "unrepaired_at_trunk": unrepaired_siblings,
        "repaired_at_trunk": repaired_siblings,
    }, open(os.environ.get("CENSUS_JSON", "helper-copy-census.json"), "w"), indent=1)

    print("\n== Helpers the sweep repaired, and who ELSE carries the same body at trunk ==\n")
    for sig, origins in sorted(before.items(), key=lambda kv: kv[1][0][0]):
        owners = ", ".join(f"{r}/{f}:{h}" for r, f, h, _ in origins)
        carriers = unrepaired_siblings.get(sig, [])
        print(f"-- repaired in: {owners}")
        print(f"   {len(carriers)} repo(s) still carry this exact body at trunk:")
        for repo, trunk, file_path, helper_name in sorted(carriers):
            marker = "  <-- SAME REPO (repair unmerged)" if any(
                repo == o[0] for o in origins) else "  <-- OTHER REPO"
            print(f"       {repo:26s} {trunk}:{file_path}:{helper_name}{marker}")
        print()


if __name__ == "__main__":
    main()
