#!/usr/bin/env python3
"""Collect quantity-stating claims in tracked markdown, as they exist on each repo's `main`.

This is card `c1c1462b`'s job.  The 290th swept test files and the 291st swept non-test
source; both filter the corpus by a *source* suffix, so neither could see a `.md` file
at all.  Markdown has no comment syntax, so there is nothing for a comment-prefix table
to match and the file never entered either corpus.

The seven shape regexes are the 291st's, unchanged and deliberately so — porting them
is what makes this corpus's numbers comparable with the other two.  The **eighth** shape,
`tally`, is the 334th's and is markdown-only by construction: it takes a count stated
immediately above the table it counts.  It is additive — no row the seven found changes
shape — so the comparison with the other two corpora still holds if the tally rows are
set aside.

Two things had to be written rather than ported:

  * **The block extractor.**  A source claim's context is the contiguous run of comment
    lines around it.  A markdown claim's context is its *paragraph*, its *list item*, or
    its *table row* — three different shapes, and picking the wrong one either truncates
    the claim's subject or swallows the whole section.  `markdown_block` below dispatches
    on which of the three the hit line is.

  * **The tally shape, and the position that makes it precise.**  See `TALLY_PAIR` below:
    the counting shape alone matches 498 lines of tracked markdown here and 7 once it is
    required to sit above a table.  Every hit now also carries `above_table`, which is
    what `classify.py` buckets on.

  * **Fenced code is excluded, and counted while being excluded.**  A number inside a
    ``` fence is sample output or a command, not a maintained claim about the system.
    Leaving it in would flood the corpus with counts nobody asserts.  The count of what
    the fence filter removed is printed, so the exclusion is a measurement rather than a
    silent narrowing.

Re-taken against `main` rather than the working tree, for the 289th's reason: every repo
here is liable to be checked out on another agent's branch.
"""

import json
import os
import re
import subprocess
import sys
from collections import Counter

# Where a run leaves its collected corpus when the caller names no path. The guard
# always names one, so this default is for a hand run of this module alone.
PACKAGE_DATA_DIRECTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")

# Overridable so the guard's selftest can point the whole collection at a synthetic tree
# it built. Without it there is no way to show this collector -- and the guard around it
# -- reporting a MISMATCH on a real document read out of a real `git` repository, and a
# guard that has never been seen going red is a guard nobody can trust going green.
REPOS_ROOT = os.environ.get("MARKDOWN_TALLY_REPOS_ROOT") or os.path.expanduser("~/repos")

# The user's own two files live outside every repo and are named by the card that
# commissioned this corpus. They are skipped when the root is overridden: a selftest
# scoring the real `~/CLAUDE.md` would have its verdicts move whenever that file is
# edited, which is a fixture derived from something the test does not control.
HOME_DOCUMENTS = () if os.environ.get("MARKDOWN_TALLY_REPOS_ROOT") \
    else ("~/CLAUDE.md", "~/AGENTS.md")

VENDORED = {"happy", "claude-squad"}

MARKDOWN_SUFFIXES = (".md", ".markdown")

# Checked in but not authored here: build output, vendored trees, dependency licences.
EXCLUDED_PATH_PARTS = (
    "node_modules/", "/dist/", "dist/", "/build/", "vendor/",
    "/testdata/", "third_party/", "/generated/", "LICENSE",
)

WORD_NUMBER = r"(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"

# The 291st's seven shapes, ported verbatim.
QUANTITY_CLAIMS = [
    ("N of M", re.compile(r"\b\d+\s+of\s+(?:the\s+)?\d+\b", re.I)),
    ("word-N of M", re.compile(r"\b" + WORD_NUMBER + r"\s+of\s+(?:the\s+)?(?:\d+|" + WORD_NUMBER + r")\b", re.I)),
    ("N/M", re.compile(r"\b\d+\s*/\s*\d+\b")),
    ("all N", re.compile(r"\ball\s+(?:\d+|" + WORD_NUMBER + r")\s+\w+", re.I)),
    ("only N", re.compile(r"\bonly\s+(?:\d+|" + WORD_NUMBER + r")\b", re.I)),
    ("every N", re.compile(r"\bevery\s+(?:\d+|" + WORD_NUMBER + r")\s+\w+", re.I)),
    ("N repos/files/callers", re.compile(
        r"\b\d+\s+(?:repos|repositories|files|callers|call sites|harnesses|"
        r"services|packages|tests|cases|copies|places|sites)\b", re.I)),
]

# The 334th pass's eighth shape.  A **tally** is a count stated immediately above the
# table it counts, and it is the cheapest row in the corpus: its population sits in the
# same document, so the recount needs no repo checkout and no judging budget.  The seven
# shapes above could not see one — `0 COVERED · 30 PARTIAL · 9 ABSENT` carries no `of`,
# no `all`, no `only`, and none of the fixed nouns — which is why both known instances
# (inber `590c8c7`, kanban-store `29d9a17`) were found by hand rather than by this sweep.
#
# The line shape alone is far too loose: a run of count-and-label pairs matches 498 lines
# of tracked markdown on this box, most of them prose that happens to count twice in one
# sentence.  The position is what makes it precise — the same shape, restricted to a block
# sitting immediately above a table, matches 7.  So both conditions are required, and the
# positional one is the load-bearing half.
TALLY_PAIR = re.compile(r"\b(?:\d+|" + WORD_NUMBER + r")\s+[`*_]*[A-Za-z][\w-]*", re.I)
TALLY_SEPARATOR = re.compile(r"[·•]|\s/\s|,\s|\band\b|\bplus\b", re.I)

FENCE = re.compile(r"^\s*(```|~~~)")
TABLE_ROW = re.compile(r"^\s*\|")
LIST_ITEM = re.compile(r"^(\s*)(?:[-*+]|\d+[.)])\s+")
HEADING = re.compile(r"^\s*#{1,6}\s")


def git(path, *arguments):
    return subprocess.run(["git", "-C", path, *arguments],
                          capture_output=True, text=True, errors="replace")


def repositories():
    for name in sorted(os.listdir(REPOS_ROOT)):
        if "-wt-" in name or name in VENDORED:
            continue
        path = os.path.join(REPOS_ROOT, name)
        if os.path.isdir(os.path.join(path, ".git")):
            yield name, path


def in_corpus(relative):
    if not relative.endswith(MARKDOWN_SUFFIXES):
        return False
    if any(part in relative for part in EXCLUDED_PATH_PARTS):
        return False
    return True


def fenced_lines(lines):
    """Indices (0-based) that sit inside a ``` or ~~~ fence, fence markers included."""
    inside = set()
    open_marker = None
    for index, line in enumerate(lines):
        match = FENCE.match(line)
        if match:
            if open_marker is None:
                open_marker = match.group(1)
                inside.add(index)
            elif line.strip().startswith(open_marker):
                inside.add(index)
                open_marker = None
            else:
                inside.add(index)
        elif open_marker is not None:
            inside.add(index)
    return inside


def markdown_block(lines, index):
    """The paragraph, list item or table the claim at 0-based `index` belongs to.

    Three shapes, because markdown has three and they nest differently:

      * a table row takes the whole contiguous run of `|` rows, so the header that
        names what the column counts travels with the number;
      * a list item takes itself plus its indented continuations, and stops at the
        next item at the same or shallower indent, so sibling bullets stay separate;
      * anything else takes its blank-line-delimited paragraph.
    """
    def blank(number):
        return not lines[number].strip()

    if TABLE_ROW.match(lines[index]):
        start = index
        while start > 0 and TABLE_ROW.match(lines[start - 1]):
            start -= 1
        end = index
        while end + 1 < len(lines) and TABLE_ROW.match(lines[end + 1]):
            end += 1
        return start, end, "table-row"

    list_match = LIST_ITEM.match(lines[index])
    start = index
    if not list_match:
        # Walk back to the item this line continues, if it continues one.
        probe = index - 1
        while probe >= 0 and not blank(probe) and not TABLE_ROW.match(lines[probe]):
            probe_match = LIST_ITEM.match(lines[probe])
            if probe_match:
                list_match = probe_match
                start = probe
                break
            if HEADING.match(lines[probe]):
                break
            probe -= 1

    if list_match:
        indent = len(list_match.group(1))
        end = index
        while end + 1 < len(lines):
            following = lines[end + 1]
            if not following.strip():
                # A blank line inside a list item is allowed only if an indented
                # continuation follows it; otherwise the item has ended.
                after = end + 2
                if after < len(lines) and lines[after].strip() and \
                        len(lines[after]) - len(lines[after].lstrip()) > indent:
                    end = after
                    continue
                break
            following_match = LIST_ITEM.match(following)
            if following_match and len(following_match.group(1)) <= indent:
                break
            if HEADING.match(following) or TABLE_ROW.match(following):
                break
            end += 1
        return start, end, "list-item"

    start = index
    while start > 0 and not blank(start - 1) and not HEADING.match(lines[start - 1]) \
            and not TABLE_ROW.match(lines[start - 1]):
        start -= 1
    end = index
    while end + 1 < len(lines) and not blank(end + 1) and not HEADING.match(lines[end + 1]) \
            and not TABLE_ROW.match(lines[end + 1]):
        end += 1
    return start, end, "paragraph"


def block_above_table(lines, block_end):
    """Does the block ending at 0-based `block_end` sit immediately above a table?

    Blank lines between the block and the table are skipped, because markdown requires
    at least one there.  Authored here rather than in `classify.py` so the tally shape
    and the TALLY bucket cannot drift apart: `classify` imports this function.
    """
    probe = block_end + 1
    while probe < len(lines) and not lines[probe].strip():
        probe += 1
    return probe < len(lines) and bool(TABLE_ROW.match(lines[probe]))


def nearest_heading(lines, index):
    """The closest heading above `index` — a markdown claim's subject often lives there."""
    for probe in range(index, -1, -1):
        if HEADING.match(lines[probe]):
            return lines[probe].strip()
    return None


def blame_author_times(path, relative):
    blame = git(path, "blame", "--line-porcelain", "main", "--", relative).stdout
    authored = {}
    current = None
    for blame_line in blame.split("\n"):
        if re.match(r"^[0-9a-f]{40} \d+ (\d+)", blame_line):
            current = int(blame_line.split()[2])
        elif blame_line.startswith("author-time ") and current is not None:
            authored[current] = int(blame_line.split()[1])
        elif blame_line.startswith("\t"):
            current = None
    return authored


def scan(lines, source_label):
    """Hits in one document. Returns (hits, prose_lines_scanned, fenced_hits_dropped)."""
    inside_fence = fenced_lines(lines)
    hits = []
    prose_lines = 0
    fenced_dropped = 0
    tallied_blocks = set()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        matched = None
        for label, pattern in QUANTITY_CLAIMS:
            if pattern.search(stripped):
                matched = label
                break
        if index in inside_fence:
            if matched:
                fenced_dropped += 1
            continue
        prose_lines += 1
        if matched:
            start, end, shape = markdown_block(lines, index)
        else:
            # The tally shape, which the seven above cannot see.  Both conditions are
            # required: the counting shape AND the position above a table.  Only the
            # first qualifying line of a block yields a hit — a tally is a property of
            # the block, and the paragraph's later lines are its continuation, not a
            # second tally.
            if len(TALLY_PAIR.findall(stripped)) < 2 or not TALLY_SEPARATOR.search(stripped):
                continue
            if TABLE_ROW.match(line):
                continue
            start, end, shape = markdown_block(lines, index)
            if start in tallied_blocks or not block_above_table(lines, end):
                continue
            matched = "tally"
        if matched == "tally":
            tallied_blocks.add(start)
        hits.append({
            "line": index + 1,
            "shape": matched,
            "block_shape": shape,
            "text": stripped,
            "block_start": start + 1,
            "block_end": end + 1,
            "block": "\n".join(lines[start:end + 1]),
            "heading": nearest_heading(lines, index),
            "above_table": block_above_table(lines, end),
        })
    return hits, prose_lines, fenced_dropped


def main(out=os.path.join(PACKAGE_DATA_DIRECTORY, "rows_markdown_on_main.json")):
    """Collect the corpus and write it to `out`.

    The path is a parameter because the 334th pass needed to measure what its new tally
    shape collects **without** overwriting the corpus the 293rd/294th/295th/333rd judged
    against — a re-collection also picks up whatever landed on each repo's `main` since,
    so clobbering it would move judged rows for two reasons at once and neither would be
    separable from the other.
    """
    rows = []
    prose_lines_scanned = 0
    fenced_hits_dropped = 0
    files_scanned = 0
    repos_without_main = []

    for name, path in repositories():
        if git(path, "rev-parse", "--verify", "main").returncode != 0:
            repos_without_main.append(name)
            continue
        listing = git(path, "ls-tree", "-r", "--name-only", "-z", "main").stdout.split("\0")
        for relative in listing:
            if not in_corpus(relative):
                continue
            blob = git(path, "show", "main:" + relative)
            if blob.returncode != 0:
                continue
            files_scanned += 1
            lines = blob.stdout.split("\n")
            hits, prose_lines, fenced = scan(lines, relative)
            prose_lines_scanned += prose_lines
            fenced_hits_dropped += fenced
            if not hits:
                continue
            authored = blame_author_times(path, relative)
            for hit in hits:
                rows.append(dict(hit, repo=name, file=relative,
                                 authored=authored.get(hit["line"])))

    # The user's own two files: real files on disk, not in any repo, and named by the card.
    for personal in HOME_DOCUMENTS:
        expanded = os.path.expanduser(personal)
        if not os.path.exists(expanded):
            continue
        files_scanned += 1
        with open(expanded, errors="replace") as handle:
            lines = handle.read().split("\n")
        hits, prose_lines, fenced = scan(lines, personal)
        prose_lines_scanned += prose_lines
        fenced_hits_dropped += fenced
        for hit in hits:
            rows.append(dict(hit, repo="(home)", file=personal, authored=None))

    with open(out, "w") as handle:
        json.dump(rows, handle, indent=1)

    print("markdown files scanned on main:  %d" % files_scanned)
    print("prose lines scanned:             %d" % prose_lines_scanned)
    print("hits dropped inside code fences: %d" % fenced_hits_dropped)
    print("rows:                            %d" % len(rows))
    print("repos with no main branch: %s" % (", ".join(repos_without_main) or "none"))
    for key in ("shape", "block_shape"):
        print("by %s: %s" % (key, dict(Counter(row[key] for row in rows).most_common())))
    print("top repos:")
    for name, count in Counter(row["repo"] for row in rows).most_common(20):
        print("  %-26s %4d" % (name, count))


if __name__ == "__main__":
    main(*sys.argv[1:2])
