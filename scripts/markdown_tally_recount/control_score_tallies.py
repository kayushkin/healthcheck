#!/usr/bin/env python3
"""Controls for the tally scorer.  Exits non-zero on any failure.

Every control is two-directional: each pair differs in ONE thing and the two halves must
land on different verdicts.  A recounter that always answers MATCH and a corpus with no
rot print the same result, so the direction that has to be proved is the MISMATCH one --
and the pairs below prove it by planting the disagreement rather than by hoping the
corpus contains one.

Three of the pairs run the SAME fixture twice, differing only in the channel under test
(the total quantifier, the summed run, the row count).  That is what stops a green
verdict from being a channel that never ran.
"""
import io, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_tallies
from score_tallies import score, table_beneath

FAILURES = []


def fixture(block, table_rows, expect_rows=None):
    """A block and a table, as a document.  Returns (block, claim_line, body_rows).

    `expect_rows` is the number of body rows the reader is supposed to find.  It
    defaults to the number planted, and it is a rig guard rather than decoration: a
    fixture whose table the reader cannot see yields zero rows, and every verdict below
    it would then be about a document that is not there.  Pair 4 sabotages the row
    reader on purpose, so that one case passes the count it expects the sabotage to
    produce -- the guard still runs, against a different number.
    """
    lines = block.split("\n") + [""] + ["| head | head |", "|---|---|"] + table_rows
    body = table_beneath(lines, len(block.split("\n")))
    if body is None:
        raise SystemExit("rig broken: fixture has no table beneath its block")
    wanted = len(table_rows) if expect_rows is None else expect_rows
    if len(body) != wanted:
        raise SystemExit("rig broken: counted %d body rows, expected %d"
                         % (len(body), wanted))
    return block, block.split("\n")[0], len(body)


ROW = "| a | b |"


def check(name, got_verdict, got_reason, want_verdict, want_reason=None):
    ok = got_verdict == want_verdict and (want_reason is None or got_reason == want_reason)
    print("%-6s %-14s %-32s %s" % ("ok" if ok else "FAIL", got_verdict, got_reason, name))
    if not ok:
        FAILURES.append("%s: got %s/%s, wanted %s/%s"
                        % (name, got_verdict, got_reason, want_verdict, want_reason))
    return ok


def run(block, rows, expect_rows=None):
    return score(*fixture(block, rows, expect_rows))


print("--- pair 1: the mismatch direction, which is the one that matters ---")
r = run("All four widgets are listed below:", [ROW] * 5)
check("planted rot: `All four` over 5 rows", r["verdict"], r["reason"],
      "MISMATCH", "TOTAL-QUANTIFIED-DISAGREEMENT")
r = run("All five widgets are listed below:", [ROW] * 5)
check("same fixture, count corrected", r["verdict"], r["reason"], "MATCH")

print("\n--- pair 2: the total-quantifier channel, same disagreement twice ---")
# Identical rows and an identical disagreeing count.  Only the quantifier differs, so a
# MISMATCH that fired without reading the quantifier would light both halves.
r = run("Four widgets are listed below:", [ROW] * 5)
check("unquantified disagreement declines", r["verdict"], r["reason"],
      "NOT-COMPARABLE", "UNQUANTIFIED-DISAGREEMENT")
r = run("Exactly four widgets are listed below:", [ROW] * 5)
check("the same claim, total-quantified", r["verdict"], r["reason"],
      "MISMATCH", "TOTAL-QUANTIFIED-DISAGREEMENT")

print("\n--- pair 3: the summed-run channel ---")
ENUMERATED = "Tally: **0 COVERED · 30 PARTIAL · 9 ABSENT**."
r = run(ENUMERATED, [ROW] * 39)
check("an enumerated tally sums to its table", r["verdict"], r["reason"],
      "MATCH", "sum of the claim line's parts")
saved = score_tallies.summed_run
score_tallies.summed_run = lambda claim_line: None
try:
    r = run(ENUMERATED, [ROW] * 39)
    check("SABOTAGE sum channel removed -> the same row declines",
          r["verdict"], r["reason"], "NOT-COMPARABLE", "UNQUANTIFIED-DISAGREEMENT")
finally:
    score_tallies.summed_run = saved
r = run(ENUMERATED, [ROW] * 39)
check("sum channel restored", r["verdict"], r["reason"], "MATCH")

print("\n--- pair 4: the row count is read, not assumed ---")
r = run("All five widgets are listed below:", [ROW] * 5)
check("baseline", r["verdict"], r["reason"], "MATCH")
saved_table = score_tallies.TABLE_SEPARATOR_RULE
# Sabotage: stop recognising the `|---|` rule, so it is counted as a body row.  A scorer
# whose row count came from anywhere but the table would not move.
score_tallies.TABLE_SEPARATOR_RULE = score_tallies.re.compile(r"^(?!)")
try:
    r = run("All five widgets are listed below:", [ROW] * 5, expect_rows=6)
    check("SABOTAGE `|---|` counted as a row -> MISMATCH at 6",
          r["verdict"], r["reason"], "MISMATCH", "TOTAL-QUANTIFIED-DISAGREEMENT")
    if r["body_rows"] != 6:
        FAILURES.append("sabotage did not move the row count: still %d" % r["body_rows"])
finally:
    score_tallies.TABLE_SEPARATOR_RULE = saved_table

print("\n--- pair 5: NOT-COMPARABLE is a verdict, not a quiet pass ---")
r = run("Default host-port mappings, offset from the canonical 8160/8170/8175:", [ROW] * 3)
check("ports are not a cardinality", r["verdict"], r["reason"],
      "NOT-COMPARABLE", "NO-GOVERNING-COUNT")
if r["readings"]:
    FAILURES.append("NO-GOVERNING-COUNT row carried readings %s" % r["readings"])
r = run("Three host-port mappings, offset from the canonical 8160/8170/8175:", [ROW] * 3)
check("the same line with a real count", r["verdict"], r["reason"], "MATCH")

print("\n--- pair 6: `every one of` is an idiom, not a tally of one ---")
r = run("**Every one of the 98 failures is a transport failure. There are exactly four "
        "distinct reasons:**", [ROW] * 4)
check("`Every one of the 98` does not bind", r["verdict"], r["reason"], "MATCH")
r = run("**Every one of the 98 failures is a transport failure. There are exactly four "
        "distinct reasons:**", [ROW] * 5)
check("the same claim over 5 rows is rot", r["verdict"], r["reason"],
      "MISMATCH", "TOTAL-QUANTIFIED-DISAGREEMENT")

print("\n--- pair 7: a list is a population, and its FIRST item is not part of the claim ---")


def list_fixture(claim, items, expect_items=None, expect_declared=None):
    """A heading-shaped claim above a list, scored the way `run_widened.py` scores one."""
    lines = [claim] + items
    # The collector's block would swallow `items[0]`; the population must not.
    block_end = len(lines)
    population = score_tallies.population_beneath(lines, 0, block_end)
    if population is None:
        raise SystemExit("rig broken: fixture claim has no list beneath it")
    kind, count, declared, start = population
    if expect_items is not None and count != expect_items:
        raise SystemExit("rig broken: counted %d list items, expected %d"
                         % (count, expect_items))
    if expect_declared is not None and declared != expect_declared:
        raise SystemExit("rig broken: declared total %s, expected %s"
                         % (declared, expect_declared))
    block = "\n".join(lines[0:start])
    return score(block, claim, count, declared)


GROUPS = ["- **Alpha** (4 tests)", "- **Beta** (3 tests)",
          "- **Gamma** (4 tests)", "- **Delta** (2 tests)"]
r = list_fixture("#### `spec.ts` (13 tests)", GROUPS, expect_items=4, expect_declared=13)
check("a claim matching the items' declared total", r["verdict"], r["reason"],
      "MATCH", "count of `tests`, against the declared total")
r = list_fixture("#### `spec.ts` (16 tests)", GROUPS, expect_items=4, expect_declared=13)
check("the same list, claim inflated to 16", r["verdict"], r["reason"],
      "NOT-COMPARABLE", "CLAIM-DISAGREES-WITH-DECLARED-PARTS")
# The first item carries `(4 tests)`.  If the block still contained it, 4 would be a
# reading, and 4 is the item count -- so the inflated claim above would score MATCH.
r = list_fixture("#### `spec.ts` (16 tests)", GROUPS)
if any(x["value"] == 4 for x in r["readings"]):
    FAILURES.append("the population's first item leaked into the claim's readings: %s"
                    % [x["value"] for x in r["readings"]])
else:
    print("ok     the first list item is counted, not read as part of the claim")

print("\n--- pair 8: the declared-total channel, same fixture twice ---")
saved_parts = score_tallies.DECLARED_PART
score_tallies.DECLARED_PART = score_tallies.re.compile(r"^(?!)")
try:
    r = list_fixture("#### `spec.ts` (13 tests)", GROUPS, expect_items=4,
                     expect_declared=None)
    check("SABOTAGE declared totals removed -> the same row declines",
          r["verdict"], r["reason"], "NOT-COMPARABLE", "UNQUANTIFIED-DISAGREEMENT")
finally:
    score_tallies.DECLARED_PART = saved_parts
r = list_fixture("#### `spec.ts` (13 tests)", GROUPS, expect_items=4, expect_declared=13)
check("declared totals restored", r["verdict"], r["reason"], "MATCH")

print("\n--- rig guard: a fixture that located nothing would grade every row green ---")
probe = run("Six widgets:", [ROW] * 6)
if not probe["readings"]:
    FAILURES.append("rig broken: the control fixtures yield no readings at all")
else:
    print("ok     readings reach the scorer: %s" % [x["value"] for x in probe["readings"]])

print()
if FAILURES:
    print("%d CONTROL FAILURES" % len(FAILURES))
    for line in FAILURES:
        print("  " + line)
    raise SystemExit(1)
print("all controls pass, each direction shown separately")
