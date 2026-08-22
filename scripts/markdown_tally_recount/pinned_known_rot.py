#!/usr/bin/env python3
"""Score the two counts the 334th pass found rotted, against their PRE-REPAIR text.

Both documents are repaired on `main`, so scoring them there proves nothing about
whether this scorer can see rot.  The card that commissioned the scorer predicted both
would come back MISMATCH "with no human in the loop".  One does.  The other does not,
and that is this pass's correction rather than a defect -- see `results.md`.

Exits non-zero if either row scores anything other than the verdict pinned here.
"""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_tallies import score, table_beneath, population_beneath

# The pre-repair text of `~/CLAUDE.md` is a FIXTURE, not a document to re-read: the
# file on disk is repaired and reading it would score the repair rather than the rot.
# It travelled with this package out of `~/.nightly-293/` so a run does not depend on
# an unversioned pass directory still existing.
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

# job-store `436d29e` added the sentence, the five-row table and the route-table line in
# one commit, so the count was wrong the day it was written; `c64cbad` repaired it.
JOB_STORE_PRE_REPAIR = "c64cbad~1"

# `d6f34fc` is the 339th pass's repair of the manga test count.
MANGA_PRE_REPAIR = "d6f34fc~1"

# The repaired side is read at the named repair commit, not at the WORKING TREE as the
# pass-directory original did. The collector states the reason for the whole corpus --
# "re-taken against `main` rather than the working tree ... every repo here is liable to
# be checked out on another agent's branch" -- and it binds a pin harder than a corpus: a
# pin read off whatever branch kayushkin.com happens to be on is a dated claim about that
# checkout, and it fails for a reason that has nothing to do with the scorer. A named
# commit also keeps the post-repair half honest after any later edit to the document.
MANGA_REPAIRED = "d6f34fc"

CASES = [
    {
        "name": "job-store CONTRACT.md:501, pre-repair",
        "lines": lambda: subprocess.run(
            ["git", "-C", os.path.expanduser("~/repos/job-store"), "show",
             "%s:CONTRACT.md" % JOB_STORE_PRE_REPAIR],
            capture_output=True, text=True, errors="replace").stdout.split("\n"),
        "needle": "are computed on read, never stored",
        "expect_verdict": "MISMATCH",
        "expect_reason": "TOTAL-QUANTIFIED-DISAGREEMENT",
        "why": "`All four` binds the whole population and the table has five rows",
    },
    {
        "name": "~/CLAUDE.md:67, pre-repair",
        "lines": lambda: open(os.path.join(FIXTURES, "home-CLAUDE.md.before-repair"),
                              errors="replace").read().split("\n"),
        "needle": "are named in `~/AGENTS.md` as the backend",
        "expect_verdict": "NOT-COMPARABLE",
        "expect_reason": "UNQUANTIFIED-DISAGREEMENT",
        "why": "the claim counts a SUBSET of the table (four of eleven rows), so the "
               "body-row count is not its population -- MISMATCH here would be a right "
               "answer by a broken road, and would still fire on the repaired text",
    },
]


def paragraph_ending_at(lines, index):
    """The blank-line-delimited block containing `index`, and the line after its end."""
    start = index
    while start > 0 and lines[start - 1].strip():
        start -= 1
    end = index
    while end + 1 < len(lines) and lines[end + 1].strip():
        end += 1
    return "\n".join(lines[start:end + 1]), end + 1


def main():
    failures = []
    for case in CASES:
        lines = case["lines"]()
        hits = [i for i, line in enumerate(lines) if case["needle"] in line]
        if len(hits) != 1:
            failures.append("%s: needle matched %d lines, expected exactly 1 -- a "
                            "fixture that does not locate its claim scores nothing and "
                            "reads as a pass" % (case["name"], len(hits)))
            continue
        index = hits[0]
        block, block_end = paragraph_ending_at(lines, index)
        body = table_beneath(lines, block_end)
        if body is None:
            failures.append("%s: no table beneath the block" % case["name"])
            continue
        result = score(block, lines[index].strip(), len(body))
        ok = (result["verdict"] == case["expect_verdict"]
              and result["reason"] == case["expect_reason"])
        print("%-6s %-14s %-32s %s" % ("ok" if ok else "FAIL", result["verdict"],
                                       result["reason"], case["name"]))
        print("       %d body rows, readings %s"
              % (len(body), [r["value"] for r in result["readings"]]))
        print("       expected because: %s" % case["why"])
        if not ok:
            failures.append("%s: got %s/%s, expected %s/%s"
                            % (case["name"], result["verdict"], result["reason"],
                               case["expect_verdict"], case["expect_reason"]))
    # --- the row this pass found, scored both ways ---------------------------------
    #
    # `kayushkin.com/MANGA_BUG_FIX_SUMMARY.md:34` claimed 16 tests over a four-group
    # list whose groups declare 4+3+4+2 = 13, and the file on disk has 13.  It is the
    # first rot the scorer found that no human had already found, and it is caught by
    # the declared-total channel rather than by an item count -- the list has four
    # items and the claim was never about items.
    MANGA = "MANGA_BUG_FIX_SUMMARY.md"
    for ref, expect_verdict, expect_reason in (
            # A named commit, not `HEAD`: the repair below landed as `d6f34fc`, and a
            # pin that reads `HEAD` stops testing the rot the moment the rot is fixed.
            (MANGA_PRE_REPAIR, "NOT-COMPARABLE", "CLAIM-DISAGREES-WITH-DECLARED-PARTS"),
            (MANGA_REPAIRED, "MATCH", "count of `tests`, against the declared total")):
        lines = subprocess.run(
            ["git", "-C", os.path.expanduser("~/repos/kayushkin.com"), "show",
             "%s:%s" % (ref, MANGA)], capture_output=True, text=True,
            errors="replace").stdout.split("\n")
        hits = [i for i, line in enumerate(lines)
                if line.startswith("#### `e2e/manga-comprehensive.spec.ts`")]
        if len(hits) != 1:
            failures.append("manga %s: needle matched %d lines, expected 1"
                            % (ref, len(hits)))
            continue
        index = hits[0]
        population = population_beneath(lines, index, index + 1)
        if population is None:
            failures.append("manga %s: no population beneath the claim" % (ref))
            continue
        kind, count, declared, start = population
        result = score("\n".join(lines[index:start]), lines[index].strip(), count, declared)
        ok = (result["verdict"] == expect_verdict and result["reason"] == expect_reason)
        print("%-6s %-14s %-32s kayushkin.com %s @ %s"
              % ("ok" if ok else "FAIL", result["verdict"], result["reason"][:32],
                 MANGA, ref))
        print("       %d %s declaring %s; readings %s"
              % (count, kind, declared, [r["value"] for r in result["readings"]]))
        if not ok:
            failures.append("manga @ %s: got %s/%s, expected %s/%s"
                            % (ref, result["verdict"], result["reason"],
                               expect_verdict, expect_reason))

    if failures:
        print("\n%d FAILED" % len(failures))
        for line in failures:
            print("  " + line)
        raise SystemExit(1)
    print("\nevery known-rot row scored as pinned")


if __name__ == "__main__":
    main()
