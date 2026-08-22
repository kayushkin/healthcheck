#!/usr/bin/env python3
"""Classify markdown quantity claims by whether they CAN rot.

Card `c1c1462b` step 2: classify EXTERNAL / INTERNAL / NOT-A-CLAIM first, because that
split is what keeps the judging budget off rows that cannot rot.  It held at about 3:1
on two disjoint corpora.

This corpus needed a fourth bucket the other two did not, and finding that out is a
result rather than a setup detail.  **DATED** — a claim inside a document that stamps
itself with the date it describes (`docs/papers/2026-08-harness-research.md`, a
`TASK_COMPLETION_REPORT.md`, a changelog entry).  Its numbers are a snapshot and were
never a promise about today, so scoring them stale would be scoring the genre, not a
defect.  On this corpus DATED is the single largest bucket, which is why it matters:
folded into EXTERNAL it would have tripled the apparent judging surface.

The 334th pass added a **fifth**: **TALLY** — a claim whose block sits immediately above
a markdown table, so the population it counts is the table underneath it.  It is the
cheapest bucket in the corpus and that is the whole reason it is one.  Every other bucket
is a statement about how expensive the row is to judge — an EXTERNAL row needs a repo
checked out and a command run — where a tally is settled by counting the rows below it,
in the same document, with nothing else open.  Both known repairs of this shape (inber
`590c8c7`, kanban-store `29d9a17`) were found by eye rather than by this sweep, and a
tally is also the most-read number in any document that has one.
"""

import json, os, re, subprocess, sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from collect_markdown_claims import PACKAGE_DATA_DIRECTORY, block_above_table

# A corpus collected before the tally shape existed carries no `above_table` field, and
# re-collecting to get one would move rows the 293rd/294th/295th/333rd have already
# judged.  So it is backfilled here from the same `main` the row was taken on, through
# the collector's own helper — the rule is authored once, in the collector, and this
# file imports it rather than restating it.
_documents = {}


def document(repo, path):
    key = (repo, path)
    if key not in _documents:
        if repo == "(home)":
            with open(os.path.expanduser(path), errors="replace") as handle:
                _documents[key] = handle.read().split("\n")
        else:
            shown = subprocess.run(
                ["git", "-C", os.path.expanduser("~/repos/" + repo), "show", "main:" + path],
                capture_output=True, text=True, errors="replace")
            _documents[key] = shown.stdout.split("\n") if shown.returncode == 0 else []
    return _documents[key]


def backfill_above_table(row):
    """Fill `above_table` on a row collected before the field existed."""
    if "above_table" in row:
        return
    lines = document(row["repo"], row["file"])
    row["above_table"] = bool(lines) and block_above_table(lines, row["block_end"] - 1)

# A document whose whole point is to record a moment.  Its numbers are stamped by the
# filename or the genre, so "stale" is not a defect in them.
# NOTE (295th pass): every alternative here sits under one `(?:^|/)` anchor, so an
# alternative without a leading `.*` only matches when it IS the whole path segment.
# `.*_REPORT\.md$` and friends carry that `.*`; CHANGELOG, RELEASE, BACKLOG, PLAN and
# NOTES did not, so `docs/ENGINE_REFACTOR_PLAN.md` — a file whose second line reads
# "_Drafted April 2026._" — was bucketed EXTERNAL and cost a judging slot.  The five
# now carry `.*` like their siblings.  Blast radius on this corpus was 1 row of 440;
# it is fixed because the instrument is reused, not because the miss was large.
DATED_PATH = re.compile(
    r"(?:^|/)(?:\d{4}-\d{2}-|papers/|comparisons/|.*CHANGELOG|.*RELEASE|"
    r".*_REPORT\.md$|.*_SUMMARY\.md$|.*-status\.md$|.*BACKLOG\.md$|"
    r".*PLAN\.md$|.*-audit\.md$|.*NOTES\.md$)", re.I)

# Reaches outside its own file: counts repos, services, tests, callers, ports, rows.
EXTERNAL_SUBJECT = re.compile(
    r"\b(repos?|repositor|servic|harness|bridge|packages?|modules?|files?|"
    r"callers?|call sites?|tests?|specs?|suites?|binar|deploy|endpoints?|routes?|"
    r"tables?|columns?|jobs?|guards?|agents?|skills?|tools?|ports?|commands?|"
    r"providers?|adapters?|handlers?|fields?|methods?|functions?|structs?|"
    r"branches?|commits?|migrations?|stores?)\b", re.I)

# Counts something the reader can see in the same document.
INTERNAL_SUBJECT = re.compile(
    r"\b(steps?|sections?|rules?|below|above|following|options?|examples?|"
    r"phases?|stages?|items? below|points?)\b", re.I)

# `only one of the ways a secret reaches the socket` is an idiom, not a count.  The
# collector's `only N` shape matched it (inber `docs/harness-control-matrix.md:152`) and
# carried it into EXTERNAL, where it cost a judging slot to reclassify — the second
# instance of this shape in the corpus.
#
# The screen has to be narrow, and the boundary is the word after `of the`.  A **plural
# noun** there makes it an idiom: "only one of the ways", "only one of the reasons".  A
# **number** there makes it a real claim: "only one of the two was still work" (the same
# document, line 210) says one out of two, and screening that away would lose a claim
# that can rot.  So the screen requires a word, and refuses a numeral or a number word.
NUMBER_WORD = (r"(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)")
IDIOM = re.compile(
    r"\bonly\s+one\s+of\s+the\s+(?!" + NUMBER_WORD + r"\b)[a-z]+s\b", re.I)

# The regex fired on something that is not a count of anything.
NOT_A_CLAIM = re.compile(
    r"(?:^|\s)(?:v?\d+\.\d+(?:\.\d+)?)|"          # version numbers
    r"\b\d{4}-\d{2}-\d{2}\b|"                      # ISO dates
    r"\b\d+\s*/\s*\d+\s*(?:px|em|rem|%|ms|s\b)|"   # css / durations
    r"\bhttp|\b\d+:\d+\b|"                          # urls, times, ports as N:M
    r"^\s*[-*+]?\s*`[^`]*`\s*$", re.I)             # a bare code span

def classify(row):
    text = row["text"]
    if IDIOM.search(text):
        return "NOT-A-CLAIM"
    if NOT_A_CLAIM.search(text) and not EXTERNAL_SUBJECT.search(text):
        return "NOT-A-CLAIM"
    if row.get("above_table"):
        return "TALLY"
    if DATED_PATH.search(row["file"]):
        return "DATED"
    if EXTERNAL_SUBJECT.search(text):
        return "EXTERNAL"
    if INTERNAL_SUBJECT.search(text):
        return "INTERNAL"
    return "NOT-A-CLAIM"

def main():
    """Bucket the stored corpus and report it.

    Guarded, because the two controls import this module for `DATED_PATH`, `IDIOM` and
    `classify` — and since the 334th pass added the `above_table` backfill, an import
    side effect would read every document in the corpus out of git and rewrite
    `rows_classified.json` just to answer a regex question.
    """
    rows = json.load(open(os.path.join(PACKAGE_DATA_DIRECTORY,
                                       "rows_markdown_on_main.json")))
    for row in rows:
        backfill_above_table(row)
        row["bucket"] = classify(row)

    json.dump(rows, open(os.path.join(PACKAGE_DATA_DIRECTORY, "rows_classified.json"), "w"),
              indent=1)

    counts = Counter(r["bucket"] for r in rows)
    total = len(rows)
    print("corpus: %d rows in %d files" % (total, len({(r["repo"], r["file"]) for r in rows})))
    for bucket, count in counts.most_common():
        print("  %-12s %4d  (%4.1f%%)" % (bucket, count, 100.0 * count / total))
    print()
    for bucket in ("TALLY", "EXTERNAL"):
        chosen = [r for r in rows if r["bucket"] == bucket]
        if bucket == "TALLY":
            print("TALLY — settled by the table underneath, in the same document — %d rows:"
                  % len(chosen))
            for row in chosen:
                print("  %-18s %-34s L%-5d %s" % (row["repo"], row["file"][:34],
                                                  row["line"], row["text"][:70]))
            print()
            continue
        print("EXTERNAL — the rot-prone surface — %d rows in %d files:" % (
            len(chosen), len({(r["repo"], r["file"]) for r in chosen})))
        for (repo, path), count in Counter(
                (r["repo"], r["file"]) for r in chosen).most_common(25):
            print("  %-22s %-42s %3d" % (repo, path, count))


if __name__ == "__main__":
    main()
