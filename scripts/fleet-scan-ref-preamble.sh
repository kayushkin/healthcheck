#!/usr/bin/env bash
#
# fleet-scan-ref-preamble.sh — tell a fleet-wide scan which ref it is actually
# reading, before it reports a number as if it had read trunk.
#
# WHAT WENT WRONG, which is what this exists to stop happening again
#
# The fleet unicode byte-cut sweep derives its population the obvious way:
#
#     grep -rnE '<regex>' --include=*.go .
#
# run from each repo in ~/repos. Three cards (768f26a7, b2063ba9, 26f59f59)
# document that command, and all three describe their output as a fleet count —
# as if it were what the fleet ships.
#
# It is not. `grep -rn .` reads whatever branch the repo has checked out.
# Measured 2026-08-09 over 76 repos with a main or master: TEN are parked off
# trunk, and FIVE of those are parked on `fix/truncation-never-splits-a-rune`,
# which is that same sweep's own fix branch. In those five the scan reads the
# repair, and the defect still shipping on trunk is invisible to it. Concretely:
#
#     main:internal/format/format.go:103     content = v[:50] + "..."
#     fix/truncation…:internal/format/…      content = textutil.TruncateAtRuneBoundary(v, 50) + "..."
#
# logstack's `main` still carries the byte cut. The grep, run from the parked
# tree, reports clean. Nine sites on trunk are invisible to the three documented
# scans this way, all nine in repos parked on the fix branch.
#
# THE PART WORTH CARRYING, because it is why nobody noticed for eighty passes
#
# The aggregate hides it. Counting production Go blobs with HEAD-as-trunk gives
# 820; counting real trunk gives 819. Both yield the same 1.60x branch-blindness
# factor, because the two errors — 42 blobs read that trunk does not ship, 41
# blobs on trunk never read — very nearly cancel. A headline that survives a
# method defect is not evidence the method is sound. Check composition, not the
# total.
#
# WHY THIS IS NOT A RED/GREEN NIGHTLY GUARD
#
# Deliberately. A parked branch is not a fault: those ten branches are unmerged
# work, and the decision about merging them is held open on purpose in noteboard
# card bab768a3. A nightly check that went red because the user has work in
# progress would cry wolf every night about a state they chose — and a guard
# people learn to ignore is worse than no guard, because the dashboard still
# claims something is being watched.
#
# So this is not scheduled and has no red state of its own. It is an instrument
# a scan calls so the scan can declare its own blind spot. The bug was never the
# working tree; it was an instrument that did not say which ref it read.
#
# ⚠️ DO NOT "FIX" THE PARKED REPOS BY CHECKING THEM OUT ONTO MAIN. That destroys
# somebody's working state to flatter a measurement.
#
# MODES
#
#   (default)          Print the parked table — every repo whose working tree
#                      shows something other than trunk. This is the preamble:
#                      put it at the top of a fleet scan's output.
#   --json             The same, machine-readable, for a scan written in python.
#   --scan-delta RE    Run the caller's own extended regex twice per repo — once
#                      as `grep -rnE RE .` and once as `git grep -nE RE <trunk>`
#                      — and print the sites on trunk the working-tree form
#                      cannot reach. This is the question a caller actually has:
#                      not "are repos parked" but "does that change MY answer".
#   --self-test        Prove the instrument reports before trusting a clean run.
#
#   --include GLOB     Pathspec for --scan-delta. Default '*.go'.
#
# Exit codes follow the house rule: 0 = ran clean, 1 = ran and found sites the
# caller's scan cannot reach, 2 = could not run and checked nothing.

set -uo pipefail

REPOS_DIR="${REPOS_DIR:-$HOME/repos}"

MODE=table
REGEX=""
INCLUDE='*.go'

while [ $# -gt 0 ]; do
  case "$1" in
    --json)        MODE=json ;;
    --self-test)   MODE=selftest ;;
    --scan-delta)  MODE=delta; REGEX="${2:-}"; shift
                   [ -n "$REGEX" ] || { echo "FAIL: --scan-delta needs a regex" >&2; exit 2; } ;;
    --include)     INCLUDE="${2:-}"; shift
                   [ -n "$INCLUDE" ] || { echo "FAIL: --include needs a glob" >&2; exit 2; } ;;
    -h|--help)     sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "FAIL: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 on PATH" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "FAIL: no git on PATH" >&2; exit 2; }
[ -d "$REPOS_DIR" ] || { echo "FAIL: no repo directory at $REPOS_DIR" >&2; exit 2; }

MODE="$MODE" REGEX="$REGEX" INCLUDE="$INCLUDE" REPOS_DIR="$REPOS_DIR" python3 - <<'PY'
import json, os, shlex, subprocess, sys, tempfile

mode = os.environ["MODE"]
regex = os.environ["REGEX"]
include = os.environ["INCLUDE"]
repos_dir = os.environ["REPOS_DIR"]


def git(repo, *args):
    result = subprocess.run(["git", "-C", repo, *args],
                            capture_output=True, text=True, errors="replace")
    return result.stdout if result.returncode == 0 else ""


def repositories(root):
    """Every real git repository under root, newest-blind and registry-blind.

    Enumerated from the filesystem rather than from repo-store (:8306), and that
    is a measured choice, not laziness. repo-store is the canonical registry of
    repo IDENTITY — languages, frameworks, build tags — and it is the right join
    target for those. It is not a census: checked 2026-08-09 it holds 75 rows
    against 78 real repositories, missing chat-core, event-store, producer,
    renodmv-cli and repodetect, and carrying two rows (memory, sessions) for
    directories that are not repositories at all. A fleet scan enumerated from
    it would silently skip five repos — which is this script's own bug wearing a
    different hat, so it is the one enumeration this file must not use.

    Linked worktrees are excluded: `~/repos/scheduler-wt-ask` and its siblings
    are checkouts OF scheduler, not repositories beside it, and counting them
    would double-count scheduler's blobs and report a worktree's branch as a
    parked repo.
    """
    found = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        dot_git = os.path.join(path, ".git")
        if not os.path.isdir(path) or not os.path.exists(dot_git):
            continue
        # A linked worktree's .git is a FILE pointing into the parent's gitdir.
        if not os.path.isdir(dot_git):
            continue
        found.append((name, path))
    return found


def trunk_of(repo):
    for candidate in ("main", "master"):
        if git(repo, "rev-parse", "--verify", "--quiet", candidate).strip():
            return candidate
    return None


def survey(root):
    """Per repo: the branch the working tree shows, and the branch it ships."""
    rows = []
    for name, path in repositories(root):
        head = git(path, "symbolic-ref", "--quiet", "--short", "HEAD").strip()
        trunk = trunk_of(path)
        rows.append({
            "repo": name,
            "path": path,
            "head": head or "(detached HEAD)",
            "trunk": trunk,
            "parked": bool(trunk) and head != trunk,
            "no_trunk": trunk is None,
        })
    return rows


def matches(lines):
    """(path, text) for every hit, so a site is compared by content not line number.

    Line numbers move between refs for reasons that have nothing to do with the
    defect — an import added above it is enough — so comparing them would report
    every shifted line as a difference.
    """
    hits = set()
    for line in lines:
        path, _, rest = line.partition(":")
        if path.startswith("./"):
            path = path[2:]
        _, _, text = rest.partition(":")
        if text.strip():
            hits.add((path, text.strip()))
    return hits


def scan_delta(root, pattern, pathspec):
    """Sites on trunk that the caller's working-tree grep structurally cannot reach."""
    findings = []
    for row in survey(root):
        if not row["parked"]:
            continue
        path, trunk = row["path"], row["trunk"]
        working = matches(subprocess.run(
            ["grep", "-rnE", pattern, "--include=" + pathspec, "."],
            cwd=path, capture_output=True, text=True, errors="replace"
        ).stdout.splitlines())
        at_trunk_raw = git(path, "grep", "-nE", pattern, trunk, "--", pathspec).splitlines()
        at_trunk = matches(
            [l[len(trunk) + 1:] for l in at_trunk_raw if l.startswith(trunk + ":")])
        for hit_path, text in sorted(at_trunk - working):
            findings.append({"repo": row["repo"], "head": row["head"], "trunk": trunk,
                             "path": hit_path, "line": text})
    return findings


def self_test():
    """Prove the delta mode reports, by building a repo it MUST report on.

    The 79th nightly pass's rule, learned from a `gofmt -l` run that returned
    nothing because it was pointed at the wrong tree: a clean result from an
    instrument nobody has seen fire is not evidence. So manufacture the exact
    shape — a repo parked on a branch that repairs a line trunk still carries —
    and require a hit.
    """
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repos", "canary")
        os.makedirs(repo)
        run = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True)
        run("init", "-q", "-b", "main")
        run("config", "user.email", "selftest@localhost")
        run("config", "user.name", "self test")
        with open(os.path.join(repo, "cut.go"), "w") as fh:
            fh.write('package canary\n\nfunc clip(s string) string { return s[:50] + "..." }\n')
        run("add", "-A"); run("commit", "-qm", "trunk carries the byte cut")
        run("checkout", "-qb", "fix/repaired")
        with open(os.path.join(repo, "cut.go"), "w") as fh:
            fh.write('package canary\n\nfunc clip(s string) string { return safe(s, 50) + "..." }\n')
        run("add", "-A"); run("commit", "-qm", "the branch repairs it")

        found = scan_delta(os.path.join(tmp, "repos"),
                           r'[a-zA-Z_][a-zA-Z0-9_.()]*\[:[0-9]+\]', "*.go")
        if len(found) == 1 and found[0]["path"] == "cut.go":
            print("ok: self-test — the parked canary's trunk-only byte cut was reported")
            return 0
        print("FAIL: self-test — the instrument did not report a site it was built to find")
        print(f"      expected 1 hit on cut.go, got {len(found)}: {found}")
        return 2


if mode == "selftest":
    sys.exit(self_test())

rows = survey(repos_dir)
parked = [r for r in rows if r["parked"]]
no_trunk = [r for r in rows if r["no_trunk"]]

if mode == "json":
    json.dump({"repos_examined": len(rows), "parked": parked, "without_trunk": no_trunk},
              sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.exit(0)

if mode == "delta":
    findings = scan_delta(repos_dir, regex, include)
    # shlex.quote, never repr: repr() escapes a backslash as `\\`, so a regex
    # copy-pasted out of this output would be a DIFFERENT regex from the one
    # that produced the finding. An instrument about instruments lying about
    # what they read does not get to print a command that does not run.
    shown_regex, shown_include = shlex.quote(regex), shlex.quote(include)
    print(f"# ref preamble — {len(rows)} repositories, {len(parked)} parked off trunk")
    print(f"# scan: grep -rnE {shown_regex} --include={shown_include}")
    if not findings:
        print("# no site on trunk is hidden from this scan by a parked working tree.")
        sys.exit(0)
    print(f"\n{len(findings)} site(s) on trunk this scan CANNOT REACH, because the repo is parked:\n")
    for f in findings:
        print(f"  {f['repo']}/{f['path']}")
        print(f"      trunk={f['trunk']}  working tree parked on {f['head']}")
        print(f"      {f['line'][:110]}")
    print("\nRe-run naming the ref, per repo:")
    print(f"    git -C <repo> grep -nE {shown_regex} <trunk> -- {shown_include}")
    sys.exit(1)

print(f"# ref preamble — this scan reads the WORKING TREE of {len(rows)} repositories.")
if not parked:
    print("# every repository is on trunk; the working tree and trunk agree.")
    sys.exit(0)
print(f"# {len(parked)} of them are parked off trunk, so the scan reads a branch, not what ships.\n")
width = max(len(r["repo"]) for r in parked)
for r in parked:
    print(f"  {r['repo']:<{width}}  trunk={r['trunk']:<7} working tree on  {r['head']}")
if no_trunk:
    print(f"\n  no main/master at all ({len(no_trunk)}): "
          + ", ".join(r["repo"] for r in no_trunk))
print("\nA count taken over these working trees is not a count of what the fleet ships.")
print("Name the ref instead:  git -C <repo> grep -nE '<regex>' <trunk> -- '*.go'")
PY
