#!/usr/bin/env python3
"""Recount a TALLY row against the table beneath it, mechanically.

The 334th pass judged all eleven TALLY rows by hand and found two rotted counts.  Its
own closing note said the recount never leaves the document, so the comparison the eye
was doing -- a stated count against the number of body rows below it -- is a number the
instrument can read.  This scores it.

## The three verdicts, and why the third has to be loud

    MATCH            a reading of the claim equals the table's body-row count
    MISMATCH         the claim is TOTAL-QUANTIFIED, so the table's rows are beyond
                     doubt its population, and no reading of it equals that count
    NOT-COMPARABLE   everything else, with a named reason

`NOT-COMPARABLE` is a verdict, not a quiet pass.  The corpus already contains a claim
whose recount is legitimate and whose numbers still disagree with the table -- inber
`harness-control-matrix.md:64` reports `0 COVERED / 30 PARTIAL / 9 ABSENT` over a table
whose verdict column now reads 29/10, with the line beneath it explaining why -- and a
scorer that cried MISMATCH there would be crying wolf on a document that had already
answered the question.

## The asymmetry, stated because it is a floor and not an accident

A reading may establish MATCH on weak evidence: any candidate count in the block, or the
sum of the claim line's separated run, equalling the body-row count is enough.  MISMATCH
needs strong evidence: an explicit total quantifier (`all N`, `exactly N`, `every N`,
`both N`) binding a plural count.  The two directions cost different things.  A false
MATCH loses one rotted count -- which is what the sweep lost anyway before this scorer
existed, since nothing recounted these at all.  A false MISMATCH sends a reader back to
a document that was right, and a check this cheap survives only as long as it is
trusted.  So the weak road may reach MATCH and may never reach MISMATCH.

## Floors this scorer does not clear, stated rather than regexed away

1. **A count of one is never a governing count.**  `every one of the 98 failures`,
   `over one transcript`, `the only one kanban-store reads is id` -- English writes
   `one` idiomatically far more often than it writes it as a tally, and a one-row table
   is not a table anybody tallies.  Excluding it costs no real row in the corpus and
   removes three false candidates.
2. **A count above `PLAUSIBLE_CEILING` is not a table's cardinality.**  It is a port, a
   year, a version or a token count.  `8160/8170/8175` is the corpus instance.
3. **A count whose population is a subset of the table cannot be recounted from the row
   count**, and this scorer does not detect that -- it declines instead.  `~/CLAUDE.md:67`
   ("Five ... are named in `~/AGENTS.md`") counts five of eleven rows, and both its
   rotted and its repaired text score NOT-COMPARABLE.  See `results.md`: the card that
   commissioned this scorer predicted MISMATCH there, and MISMATCH would have been a
   right answer by a broken road before the repair and a wrong one after it.
"""
import re

WORD_NUMBERS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20,
}

# Above this a number is a port, a year, a version or a token count, not the number of
# rows in a table.  The largest genuine tally in the corpus is 39.
PLAUSIBLE_CEILING = 200

_NUMBER = r"(?:\d+|" + "|".join(WORD_NUMBERS) + r")"

# A count and the word it governs.  The trailing word may be a noun (`six things`) or a
# verb (`five are computed`); requiring one is what drops a bare figure in a ratio.
# `[`*_"]*` is allowed on BOTH sides of the gap: kanban-store's governing count is
# written `**seven** noteboard endpoints`, so a pattern that tolerates emphasis only in
# front of the noun sees no count at all and reports the row NO-GOVERNING-COUNT.
# The optional `\([^)]*\)` is the 319th pass's rule arriving again: a sweep must collect
# the shape its own repairs produce.  The 334th's repair to `~/CLAUDE.md:67` rewrote
# `Four are named` as `Five (auth-store, skill-store, kanban-store, event-store,
# quote-store) are named` -- and the parenthetical between the count and the word it
# governs made the repaired line invisible to a pattern that allowed only emphasis
# there.  Without this the repair would have been the last look anyone took at the row.
COUNT_AND_WORD = re.compile(
    r"(?<![\w./:-])(" + _NUMBER + r")[`*_\"]*\s*(?:\([^)]*\))?\s+[`*_\"]*([A-Za-z][\w-]*)",
    re.I)

# A total quantifier binds the count to the whole population, which is the only evidence
# strong enough to let this scorer say MISMATCH.
TOTAL_QUANTIFIER = re.compile(
    r"\b(all|every|exactly|both)\s+[`*_]*(" + _NUMBER + r")\b", re.I)

TABLE_SEPARATOR_RULE = re.compile(r"^\s*\|[\s|:-]+\|\s*$")
TABLE_ROW = re.compile(r"^\s*\|")

# The separators an enumerated tally uses between its parts, taken from the collector.
TALLY_SEPARATOR = re.compile(r"[·•]|\s/\s|,\s|\band\b|\bplus\b", re.I)


def as_number(token):
    token = token.lower()
    if token.isdigit():
        return int(token)
    return WORD_NUMBERS[token]


def candidate_counts(text):
    """Every plausible governing count in `text`, in order, with the word it governs."""
    found = []
    for match in COUNT_AND_WORD.finditer(text):
        value = as_number(match.group(1))
        if value <= 1 or value > PLAUSIBLE_CEILING:
            continue
        found.append((value, match.group(2)))
    return found


def summed_run(claim_line):
    """The sum of an enumerated tally on the claim line, or None.

    `0 COVERED · 30 PARTIAL · 9 ABSENT` states a population in parts, so the number to
    compare is the total.  Requires at least two parts and a separator between them --
    the collector's own two conditions for calling a line a tally at all.  Zero is a
    legitimate part of a sum even though it is never a governing count on its own, so
    this reads the line again rather than reusing `candidate_counts`.
    """
    parts = []
    for match in COUNT_AND_WORD.finditer(claim_line):
        value = as_number(match.group(1))
        if value > PLAUSIBLE_CEILING:
            continue
        parts.append(value)
    if len(parts) < 2 or not TALLY_SEPARATOR.search(claim_line):
        return None
    return sum(parts)


def total_quantified(text):
    """The counts bound by a total quantifier. `every one of` is an idiom, not a tally."""
    bound = []
    for match in TOTAL_QUANTIFIER.finditer(text):
        value = as_number(match.group(2))
        if value <= 1 or value > PLAUSIBLE_CEILING:
            continue
        bound.append((match.group(1).lower(), value))
    return bound


def table_beneath(lines, block_end):
    """The body rows of the first table under the block ending at 1-based `block_end`.

    Header and `|---|` rule excluded: they are not rows of the population.
    """
    probe = block_end
    while probe < len(lines) and not lines[probe].strip():
        probe += 1
    table = []
    while probe < len(lines) and TABLE_ROW.match(lines[probe]):
        table.append(lines[probe])
        probe += 1
    if not table:
        return None
    return [row for row in table[1:] if not TABLE_SEPARATOR_RULE.match(row)]


LIST_ITEM = re.compile(r"^(\s*)(?:[-*+]|\d+[.)])\s+")

# A count stated inside a list item, e.g. `- **Manga Page Tests** (4 tests)`.  This is
# how a list declares its own subtotals.
DECLARED_PART = re.compile(r"\((\d+|" + "|".join(WORD_NUMBERS) + r")\s+[A-Za-z][\w-]*\)", re.I)


def list_start_after(lines, claim_index, block_end):
    """0-based index of the list the claim introduces, or None.

    The collector's block boundary cannot be used here the way it is for a table.
    `markdown_block` grows a block downward through non-blank lines, so when a claim is
    a heading with a list under it the block swallows the list's FIRST item -- measured:
    `kayushkin.com/MANGA_BUG_FIX_SUMMARY.md:34` came back as three items over a
    four-item list, and the swallowed item's own `(4 tests)` was read as a claim.  So
    the list is located from the claim line forward: blank lines and the block's own
    continuing prose may sit between, and the first top-level list item after them
    starts the population.
    """
    probe = claim_index + 1
    while probe < len(lines):
        if not lines[probe].strip():
            probe += 1
            continue
        if LIST_ITEM.match(lines[probe]):
            return probe
        if probe < block_end:
            probe += 1          # still the claim's own paragraph
            continue
        return None
    return None


def list_items_from(lines, start):
    """The top-level items of the list beginning at 0-based `start`.

    Nested items and continuation lines belong to their parent and are not counted.
    Returns `(count, declared_total)`, where `declared_total` is the sum of the counts
    the items state about themselves, or None when fewer than two of them state one.
    """
    indent = len(LIST_ITEM.match(lines[start]).group(1))
    items, declared = 0, []
    probe = start
    while probe < len(lines):
        line = lines[probe]
        if not line.strip():
            probe += 1
            continue
        match = LIST_ITEM.match(line)
        if match and len(match.group(1)) == indent:
            items += 1
            part = DECLARED_PART.search(line)
            if part:
                declared.append(as_number(part.group(1)))
        elif line.startswith(" ") or (match and len(match.group(1)) > indent):
            pass
        else:
            break
        probe += 1
    return items, (sum(declared) if len(declared) >= 2 else None)


def population_beneath(lines, claim_index, block_end):
    """The countable population the claim introduces.

    Returns `(kind, count, declared_total, population_start)` or None.  A table wins
    when both are present: the TALLY bucket was defined positionally on tables, and
    widening to lists must not move a row that was already scored.

    A markdown list is the same positional property as a table with a different mark --
    `exactly six things:` above six bullets is as cheap to recount as the same sentence
    above six table rows.  Measured on this box, with the claim's block required to be a
    paragraph: 11 rows sit above a table and 10 more above a list, so counting lists
    nearly doubles the population.  A single bullet is not a population and does not
    count.
    """
    body = table_beneath(lines, block_end)
    if body is not None:
        return ("table rows", len(body), None, None)
    start = list_start_after(lines, claim_index, block_end)
    if start is None:
        return None
    items, declared = list_items_from(lines, start)
    if items < 2:
        return None
    return ("list items", items, declared, start)


def score(block, claim_line, body_row_count, declared_total=None):
    """Score one tally.  Returns a dict; `verdict` is MATCH / MISMATCH / NOT-COMPARABLE.

    `declared_total` is the total the population's own items declare about themselves --
    a list whose items read `(4 tests)`, `(3 tests)`, `(4 tests)`, `(2 tests)` declares
    13 whatever its item count is.  A claim may legitimately count either, so matching
    one is enough for MATCH; a claim matching NEITHER while the two disagree with each
    other is a document contradicting itself, and gets a reason of its own.
    """
    candidates = candidate_counts(block)
    total = summed_run(claim_line)
    bound = total_quantified(block)

    readings = []
    for value, word in candidates:
        readings.append({"value": value, "reading": "count of `%s`" % word})
    if total is not None:
        readings.append({"value": total, "reading": "sum of the claim line's parts"})

    base = {"readings": readings, "body_rows": body_row_count,
            "declared_total": declared_total, "quantified": bound}

    if not readings:
        return {"verdict": "NOT-COMPARABLE", "reason": "NO-GOVERNING-COUNT",
                "detail": "no count in the block is a plausible population size", **base}

    agreeing = [r for r in readings if r["value"] == body_row_count]
    if agreeing:
        return {"verdict": "MATCH", "reason": agreeing[0]["reading"],
                "detail": "%d == the population's %d" % (body_row_count, body_row_count),
                **base}

    if declared_total is not None:
        agreeing = [r for r in readings if r["value"] == declared_total]
        if agreeing:
            return {"verdict": "MATCH",
                    "reason": agreeing[0]["reading"] + ", against the declared total",
                    "detail": "%d == the total the %d items declare about themselves"
                              % (declared_total, body_row_count), **base}

    if bound:
        word, value = bound[0]
        return {"verdict": "MISMATCH", "reason": "TOTAL-QUANTIFIED-DISAGREEMENT",
                "detail": "`%s %d` binds the whole population, and it has %d entries"
                          % (word, value, body_row_count), **base}

    if declared_total is not None and declared_total != body_row_count:
        return {"verdict": "NOT-COMPARABLE", "reason": "CLAIM-DISAGREES-WITH-DECLARED-PARTS",
                "detail": "the claim states %s, the population has %d entries, and those "
                          "entries declare %d between them -- three numbers, no two alike"
                          % ("/".join(str(r["value"]) for r in readings),
                             body_row_count, declared_total), **base}

    return {"verdict": "NOT-COMPARABLE", "reason": "UNQUANTIFIED-DISAGREEMENT",
            "detail": "no reading equals the population's %d, and nothing in the claim "
                      "says the population is what it counts" % body_row_count, **base}
