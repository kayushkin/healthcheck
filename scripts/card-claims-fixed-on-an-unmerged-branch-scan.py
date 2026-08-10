#!/usr/bin/env python3
"""Find open noteboard cards quoting code that an unmerged branch has already deleted.

Why this exists
---------------
The hundred-and-ninth nightly pass filed card 8f879d6f saying
llm-bridge-copilotcli "has no identity_test.go at all" and that
`const harness = msg.HarnessClaudeCode` "is still there, live". Both were true of
`main` and false of the repository: branch fix/copilotcli-identity-is-copilot-cli
had added identity_test.go and flipped that constant two days earlier, and it is
a clean fast-forward. The pass measured the working tree, which was on main.

That is not a mistake about copilotcli. It is what happens whenever the fleet's
habit -- commit to a fix/ branch, push, never merge -- meets a card written by
reading the checkout. The fix is invisible to `ls`, to `grep -rn`, and to every
instrument that reads the working tree, so the card reports the defect as live
and the next pass re-derives a fix that already exists.

The predicate, and why it is this one
-------------------------------------
First attempt matched (repo, filename) pairs: cards naming a file that some
unmerged branch touches. It returned 449 rows over 151 cards and was useless.
Fleet-wide sweep branches like fix/truncation-never-splits-a-rune touch
discover.go in nine repos, so every card that mentions discover.go matched a
branch that had nothing to do with it. A filename is not a claim.

So match on the CLAIM instead. A card that says a defect is live usually quotes
the defective line. If that exact literal is present on the default branch and
ABSENT on some unmerged branch of the same repo, then that branch has already
removed the thing the card is about. That is close to the definition of the
population, and it is one `git grep -F` per (literal, ref).

Direction matters and only one direction is evidence:

    on default, gone on a branch     the branch removed it -- CANDIDATE
    on default, on every branch      nothing has fixed it -- the card stands
    absent from default              the card quotes something already gone,
                                     or quotes another repo -- not this scan's
                                     question

A hit is still a CANDIDATE. The branch may have deleted the line while doing
something else, and "the literal is gone" is not "the card is resolved". The
judgement is a read of that branch's diff. This scan exists to shrink the
population you have to read.

Reproduce:

    python3 ~/repos/healthcheck/scripts/card-claims-fixed-on-an-unmerged-branch-scan.py
    python3 ~/repos/healthcheck/scripts/card-claims-fixed-on-an-unmerged-branch-scan.py --verbose
"""

import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

REPOS = Path.home() / "repos"
NOTEBOARD = "http://localhost:8191/api/items"

# Raise this and re-check: the worker query is documented to come back FULL, and
# a truncated list makes every count below an undercount that reads as a census.
LIMIT = 1000

# A literal shorter than this matches too much to mean anything; one longer than
# this is usually a wrapped prose sentence that never appears verbatim in source.
MIN_LITERAL, MAX_LITERAL = 16, 160

# Inline `code spans`. A card's claim is almost always quoted this way -- the
# motivating one is a bare "`const harness = msg.HarnessClaudeCode`" with no verb
# in the sentence at all, which is why this does not filter on present-tense
# phrasing: a filter tuned on the shape of a claim misses the claim written in a
# different shape.
CODE_SPAN = re.compile(r"`([^`\n]{%d,%d})`" % (MIN_LITERAL, MAX_LITERAL))

# A literal must look like code, not like a sentence in backticks.
CODEISH = re.compile(r"[=(){}\[\];]|:=|->|\.\w")


def git(repo, *args, check=False):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        return None
    return r.stdout


def whitespace_insensitive_pattern(literal):
    """A regex matching the literal with any run of whitespace where it has one.

    Exact matching is wrong for Go, and the failure is silent and one-directional.
    gofmt aligns the `=` of every entry in a const block on one column, so adding
    a single longer name to that block re-spaces every OTHER line in it. Measured:
    card 30a5aa6d quotes `maxDispatchPerTick = 3` and says the ceiling is
    UNCHANGED; two scheduler branches still declare it as 3, but as
    `maxDispatchPerTick     = 3`, so an -F match called it deleted on both. The
    scan would have reported a card as already-fixed on the strength of a
    whitespace column.

    It only ever fabricates hits -- realignment cannot hide a real deletion -- so
    it inflates exactly the number the scan exists to report.
    """
    return r"\s+".join(re.escape(tok) for tok in literal.split())


def files_with_literal(repo, ref, literal):
    """The set of paths containing the literal at ref, ignoring whitespace runs.

    Paths, not a yes/no. A tree-wide "is it still anywhere in here" is defeated by
    the fix's own scorer: fix/copilotcli-identity-is-copilot-cli deletes
    `const harness = msg.HarnessClaudeCode` from translate.go and adds
    scripts/sabotage-identity.py, which quotes that exact line as the defect it
    injects. So the literal is still present at the branch tip, and the known-
    positive control did not fire -- the scan reported 6 rows and had no way to
    say that 6 was an undercount. Comparing the FILE SETS asks the question that
    was meant: did some file that carried this line stop carrying it.

    -E with an escaped pattern, not -F: the literal is escaped token by token in
    whitespace_insensitive_pattern, so card text full of regex metacharacters
    (parentheses, brackets, dots) is still matched literally.
    """
    r = subprocess.run(["git", "-C", str(repo), "grep", "-E", "-l",
                        whitespace_insensitive_pattern(literal), ref],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return set()
    # `git grep -l <ref>` prefixes every path with "<ref>:".
    return {ln.split(":", 1)[1] for ln in r.stdout.splitlines() if ":" in ln}


def default_branch(repo):
    ref = (git(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD") or "").strip()
    if ref.startswith("origin/"):
        return ref[len("origin/"):]
    for cand in ("main", "master"):
        if subprocess.run(["git", "-C", str(repo), "show-ref", "--verify", "--quiet",
                           f"refs/heads/{cand}"]).returncode == 0:
            return cand
    return ""


def unmerged_branches(repo, default):
    out = git(repo, "branch", "--no-merged", default, "--format=%(refname:short)") or ""
    return [b.strip() for b in out.split("\n") if b.strip()]


def merge_base(repo, default, branch):
    out = git(repo, "merge-base", default, branch) or ""
    return out.strip()


def branch_removed(repo, default, branch, literal, base_cache, default_files):
    """Files where the branch removed the literal AND the default still has it.

    The intersection with default_files is not a refinement, it is the question.
    A branch can have deleted a line that the default branch has since deleted
    too, independently, after the fork -- and then there is nothing left to fix
    and nothing to tell anyone. Measured: card 4e7aba91 is about unbounded
    `bufio.NewScanner` loops, and feat/session-bundle-resolver dropped that call
    from internal/harness/process.go. So did main, which reads
    `ndjson.ReadLine(reader, ndjson.MaxLineBytes)` today. Reported as the scan's
    only NEW row and it was already fixed everywhere.

    The whole-repo "is it on default at all" gate cannot catch this: bufio.NewScanner
    survives in other files of the same repo, so the gate passes and the per-file
    comparison then answers a question about the merge base alone.

    `git branch --no-merged` says a branch is not contained in the default -- it
    does NOT say the branch is up to date with it. A branch that forked before a
    line was written does not contain that line either, and comparing the branch
    tip against the default tip alone cannot tell the two apart. Measured: the
    first cut of this scan reported inber's fix/close-time-commit-failure-silent
    as having removed a dozen file:line citations it had simply never seen,
    because they were added to main after the fork.

    So ask the merge base. Present at the fork point and absent at the tip is a
    deletion the branch performed. Absent at the fork point is a line the branch
    never had, which is evidence of nothing.
    """
    key = (str(repo), branch)
    if key not in base_cache:
        base_cache[key] = merge_base(repo, default, branch)
    base = base_cache[key]
    if not base:
        return set()
    removed = files_with_literal(repo, base, literal) - files_with_literal(repo, branch, literal)
    return removed & default_files


def main():
    verbose = "--verbose" in sys.argv

    # A linked worktree also has a .git entry -- a FILE, not a directory. Counting
    # one as a repo indexes the parent's branches under the worktree's invented
    # name (~/repos holds several, e.g. inber-wt-skipdata), so every branch in
    # inber would be reported again against a repository that does not exist.
    repos, worktrees = {}, []
    for d in sorted(REPOS.iterdir()):
        g = d / ".git"
        if g.is_dir():
            repos[d.name] = d
        elif g.is_file():
            worktrees.append(d.name)

    todos = json.load(urllib.request.urlopen(
        f"{NOTEBOARD}?type=todo&status=open&limit={LIMIT}"))
    if len(todos) >= LIMIT:
        sys.exit(f"FATAL: noteboard returned {len(todos)} == limit; raise LIMIT or this is a "
                 f"truncated list reporting itself as a census")

    # The standing signpost is an APPEND LOG of every nightly pass's write-up, so
    # it quotes most of the fleet's code and matches everything. It is not a card
    # describing a defect. Dropped by tag, and the drop is printed rather than
    # assumed -- a silent exclusion reads as "nothing matched".
    aggregates = [t for t in todos if "signpost" in (t.get("tags") or [])]
    todos = [t for t in todos if t not in aggregates]

    meta = {}   # repo -> (default, [unmerged branches])
    def repo_meta(name):
        if name not in meta:
            d = default_branch(repos[name])
            meta[name] = (d, unmerged_branches(repos[name], d) if d else [])
        return meta[name]

    rows, cards_with_literals, greps, base_cache = [], 0, 0, {}

    # Progress to stderr, so `> out.txt` still captures a clean report while a
    # human watching the terminal can see it is alive. This run is tens of
    # thousands of `git grep` invocations and takes tens of minutes; the first
    # version printed nothing until the end, which is indistinguishable from a
    # hang and cost the pass that wrote it two needless restarts.
    def progress(n, total):
        if n % 25 == 0 or n == total:
            print(f"  ...{n}/{total} cards, {len(rows)} rows, {greps} greps",
                  file=sys.stderr, flush=True)

    for n, t in enumerate(todos, 1):
        progress(n, len(todos))
        text = (t.get("title") or "") + "\n" + (t.get("body") or "")
        named = [r for r in repos if re.search(rf"\b{re.escape(r)}\b", text)]
        # Prefer the longest repo name matched: "llm-bridge-copilotcli" contains
        # "llm-bridge", and crediting the card to the shorter one greps the wrong
        # repository. Keep every name that is not a substring of a longer match.
        named = [r for r in named if not any(r != o and r in o for o in named)]
        literals = {m for m in CODE_SPAN.findall(text) if CODEISH.search(m)}
        if not named or not literals:
            continue
        cards_with_literals += 1
        for rname in named:
            default, branches = repo_meta(rname)
            if not default or not branches:
                continue
            for lit in literals:
                greps += 1
                default_files = files_with_literal(repos[rname], default, lit)
                if not default_files:
                    continue  # not this repo's line, or already gone everywhere
                gone_on, where = [], set()
                for br in branches:
                    greps += 2
                    removed = branch_removed(repos[rname], default, br, lit, base_cache,
                                             default_files)
                    if removed:
                        gone_on.append(br)
                        where |= removed
                if gone_on:
                    # Does the card already know about the branch that fixed it?
                    # Several do -- 8f884dc1 names `feat/session-list-sse-replay`
                    # and its commit in its own body, so it is a true positive of
                    # the predicate and no news at all. The population worth
                    # reading is the cards that do NOT name their branch: that is
                    # the copilotcli signature, where the fix exists and the card
                    # describes the defect as live.
                    knows = [b for b in gone_on if b in text]
                    rows.append(dict(card=t["id"], title=t["title"], repo=rname,
                                     card_knows=knows, default=default, literal=lit, gone_on=gone_on,
                                     files=sorted(where), of=len(branches)))

    # Known-positive control. This scan was built FROM the copilotcli case, so if
    # it cannot report that case it is not measuring what it claims to and every
    # empty row below is meaningless rather than reassuring. Checked directly
    # against git rather than against `rows`, so it still fires if the card is
    # closed, retitled or reworded -- a control that depends on the data under
    # test is the hundred-and-fifth pass's blind-spot trap.
    control = "unavailable (llm-bridge-copilotcli not present)"
    if "llm-bridge-copilotcli" in repos:
        cr = repos["llm-bridge-copilotcli"]
        cbr = "fix/copilotcli-identity-is-copilot-cli"
        clit = "const harness = msg.HarnessClaudeCode"
        if subprocess.run(["git", "-C", str(cr), "rev-parse", "--verify", "--quiet", cbr],
                          capture_output=True).returncode != 0:
            control = f"unavailable (branch {cbr} is gone)"
        else:
            cdef = default_branch(cr)
            removed = branch_removed(cr, cdef, cbr, clit, base_cache,
                                     files_with_literal(cr, cdef, clit))
            control = (f"FIRED (removed from {', '.join(sorted(removed))})" if removed
                       else "DID NOT FIRE -- the scan cannot see its own motivating case")

    print(f"known-positive control                {control}")
    print(f"open todos scanned                    {len(todos)}")
    print(f"  aggregate cards dropped by tag      {len(aggregates)} "
          f"({', '.join(t['id'][:8] for t in aggregates) or 'none'})")
    print(f"linked worktrees skipped              {len(worktrees)}")
    print(f"cards quoting a code literal          {cards_with_literals}")
    print(f"git grep invocations                  {greps}")
    print(f"candidate rows                        {len(rows)}")
    print(f"distinct cards implicated             {len({r['card'] for r in rows})}\n")

    # Rank by what is actually news: rows whose card does not name the branch.
    unknown = [r for r in rows if not r["card_knows"]]
    print(f"  of those, card already names the branch  "
          f"{len(rows) - len(unknown)} row(s) -- no news")
    print(f"  card does NOT name the branch            {len(unknown)} row(s) "
          f"over {len({r['card'] for r in unknown})} card(s)  <- the population\n")

    by_card = {}
    for r in rows:
        by_card.setdefault(r["card"], []).append(r)

    for card, rs in sorted(by_card.items(), key=lambda kv: (any(x["card_knows"] for x in kv[1]),
                                                            -len(kv[1]))):
        print(f"{card[:8]}  {rs[0]['title'][:98]}")
        for r in rs:
            # Per ROW, never per card. A card with one known row and one unknown
            # row was printed KNOWN, which hid the row that was actually news.
            flag = "KNOWN" if r["card_knows"] else "  NEW"
            print(f"  [{flag}] {r['repo']}: on {r['default']}, GONE on "
                  f"{len(r['gone_on'])}/{r['of']} unmerged branch(es)")
            print(f"      literal: {r['literal']}")
            print(f"      removed from: {', '.join(r['files'])}")
            print(f"      branches: {', '.join(r['gone_on'][:6])}"
                  f"{' …' if len(r['gone_on']) > 6 else ''}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
