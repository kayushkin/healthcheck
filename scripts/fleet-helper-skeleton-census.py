#!/usr/bin/env python3
"""Second axis for card 2b5f73a5: a copy whose NAMES drifted is still a copy.

The exact-body census matches a helper only if a sibling copied it verbatim. A
repo that pasted the helper and renamed the parameter, or moved the cap from 200
to 100, carries the identical defect and matches nothing. This pass blinds the
signature to identifiers and integer literals so drifted copies still cluster,
and reports only clusters that span more than one repository.
"""

import os
import re
import importlib.util
import sys

# Sibling script, and its name has a hyphen, so it cannot be imported by name.
_SIBLING = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "fleet-helper-copy-census.py")
_spec = importlib.util.spec_from_file_location("fleet_helper_copy_census", _SIBLING)
_census = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_census)

COMMENT_PATTERN = _census.COMMENT_PATTERN
fleet_repositories = _census.fleet_repositories
functions_in = _census.functions_in
git = _census.git
go_files_at = _census.go_files_at
trunk_of = _census.trunk_of

GO_KEYWORDS = {
    "break", "case", "chan", "const", "continue", "default", "defer", "else",
    "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
    "map", "package", "range", "return", "select", "struct", "switch", "type",
    "var", "string", "int", "byte", "rune", "bool", "len", "cap", "append",
    "copy", "make", "new", "nil", "true", "false",
}

TOKEN_PATTERN = re.compile(r"[A-Za-z_]\w*|\d+|\S")


def skeleton_of(function_text):
    """Control-flow skeleton: identifiers and integer literals blinded."""
    stripped = COMMENT_PATTERN.sub(" ", function_text)
    out = []
    for token in TOKEN_PATTERN.findall(stripped):
        if token.isdigit():
            out.append("N")
        elif token[0].isalpha() or token[0] == "_":
            out.append(token if token in GO_KEYWORDS else "ID")
        else:
            out.append(token)
    return "".join(out)


def performs_byte_cut(text):
    """A cut of the shape `expr[:expr]`.

    This is a CANDIDATE filter and it deliberately does not try to tell a string
    cut from a slice cut. A slice reset (`a.calls = a.calls[:0]`) and a fixed-size
    array cut are both matched here and are both harmless; the `usage.go:Reset`
    cluster is exactly that and reads like a live find until you open it. Judging
    string-or-slice is the reader's job, per the parent sweep's rule that a
    candidate count is not a defect count.
    """
    return bool(re.search(r"\w\[:\s*\w", text))


def main():
    clusters = {}
    for name, path in fleet_repositories():
        trunk = trunk_of(path)
        if not trunk:
            continue
        for file_path in go_files_at(path, trunk):
            source = git(path, "show", f"{trunk}:{file_path}")
            if "[:" not in source:
                continue
            for helper_name, text in functions_in(source):
                if not performs_byte_cut(text):
                    continue
                # Only small helpers: a 200-line function sharing a skeleton
                # with another is a coincidence, not a copied helper.
                if text.count("\n") > 12:
                    continue
                clusters.setdefault(skeleton_of(text), []).append(
                    (name, trunk, file_path, helper_name))

    cross_repo = {sig: members for sig, members in clusters.items()
                  if len({m[0] for m in members}) > 1}

    print(f"byte-cut helpers of <=12 lines at trunk: "
          f"{sum(len(v) for v in clusters.values())}")
    print(f"distinct skeletons:                      {len(clusters)}")
    print(f"skeletons carried by >1 repository:      {len(cross_repo)}\n")

    for sig, members in sorted(cross_repo.items(), key=lambda kv: -len(kv[1])):
        repos = sorted({m[0] for m in members})
        print(f"== {len(members)} site(s) across {len(repos)} repos: {', '.join(repos)}")
        for repo, trunk, file_path, helper_name in sorted(members):
            print(f"     {repo:24s} {trunk}:{file_path}:{helper_name}")
        print()


if __name__ == "__main__":
    main()
