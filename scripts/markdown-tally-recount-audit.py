#!/usr/bin/env python3
"""Recount every quantity claim in the fleet's markdown that sits above a countable population.

A maintained document says `four canonical role families` and then lists them. The
sentence and the list are two statements of the same number, written at the same moment
and maintained separately from then on. When a row is added to the list and the sentence
is not touched, the document keeps asserting the old count in prose while displaying the
new one underneath -- and nothing anywhere fails. That is the rot this guard recounts.

## Why this is a scheduled job and not a script somebody runs

The scorer and its controls were written by the 339th nightly pass into
`~/.nightly-339-tallyscore/` and answered `25 MATCH - 0 MISMATCH - 5 NOT-COMPARABLE` the
night they were written. Card `7071d32f` filed the gap that mattered more than the
answer: **nothing invoked it.** It ran when a pass remembered it existed, so rot
introduced the next day stayed invisible until someone happened to look. A check cheap
enough to run in twenty seconds and run once a year is not a cheap check; it is worth
nothing. The card's own words: *"A recount is worth automating because it is cheap enough
to run every time."*

The scorer's modules travelled with it into `markdown_tally_recount/` beside this file,
rather than being imported out of the pass directory. `~/.nightly-*` is under no version
control (card `4707e6f3`), so a guard reaching into it is a guard one `rm -rf` away from
either dying or -- worse -- quietly scoring an older copy.

## The verdicts, and why the two directions cost different things

    MATCH            some reading of the claim equals the population's size, or the
                     total the population's own entries declare about themselves
    MISMATCH         the claim is TOTAL-QUANTIFIED (`all N`, `exactly N`, `every N`,
                     `both N`), so the population beneath it is beyond doubt what it
                     counts, and no reading of it agrees
    NOT-COMPARABLE   everything else, with a named reason

**Only MISMATCH is a finding.** The asymmetry is the scorer's and is deliberate: a false
MATCH loses one rotted count, which is what was being lost anyway while nothing recounted
these at all; a false MISMATCH sends a reader back to a document that was right, and a
check this cheap survives only as long as it is trusted. `NOT-COMPARABLE` is reported
loudly but is not a failure -- it means the claim and the population are not the same
question, which is a normal thing for a document to do.

## Exit codes

Exit 0 = every claim block recounted and none mismatched. Exit 1 = at least one MISMATCH,
or the scorer's own controls and pins are not sound. Exit 2 = the recount could not be
carried out at all -- `git` is missing, a vendored module will not import, or the
collector came back with nothing. Kept apart from exit 1 so a caller cannot read "could
not run" as "ran and found nothing"; a probe that could not run is not a negative result.

The controls run FIRST, every time. A scorer that has not been shown capable of saying
MISMATCH and a fleet with no rot in it print exactly the same result.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

PACKAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "markdown_tally_recount")

# The collector shells out to `git` for every repo, and on this box `git` is on PATH for
# a login shell but a scheduler shell job inherits a barer one. mise's shim directory is
# where the toolchains live; `healthcheck/deploy.sh` and the nightly-shared control guard
# both prepend it for the same reason.
MISE_SHIM_DIRECTORY = os.path.expanduser("~/.local/share/mise/shims")

# Indirection so the selftest can take the toolchain away without touching PATH itself.
find_executable = shutil.which

# The controls and the pins are separate programs, not imports: each exits non-zero on
# its own failure, and running them as programs is what makes that exit code the answer
# rather than something this file re-derives.
CONTROL_PROGRAMS = (
    ("controls", "control_score_tallies.py",
     "eight two-directional control pairs over the scorer"),
    ("pins", "pinned_known_rot.py",
     "three known-rot rows, each scored against its pre-repair text"),
)

CONTROL_TIMEOUT_SECONDS = 300
COLLECT_TIMEOUT_SECONDS = 900


def ensure_git_on_path():
    """Put `git` on PATH, or say why the recount cannot be carried out.

    Measured on the nightly-shared control guard's first scheduled run: a scheduler shell
    job does not get mise's shims, and three of its four control sets died with
    `FileNotFoundError`. That read as three broken instruments and was one missing
    toolchain. Here the failure would be worse, because the collector treats a failed
    `git show` as "this file has no claims" -- so a missing `git` would collect an empty
    corpus and report a clean fleet. Refuse instead.
    """
    if find_executable("git"):
        return None
    if os.path.isdir(MISE_SHIM_DIRECTORY):
        os.environ["PATH"] = MISE_SHIM_DIRECTORY + os.pathsep + os.environ.get("PATH", "")
        if find_executable("git"):
            return None
    return ("`git` is not on PATH and mise's shim directory did not supply it. The "
            "collector reads every document out of each repo's `main` through `git "
            "show`, and a failed `show` is indistinguishable from a file with no claims "
            "in it -- so without the toolchain this guard would collect an empty corpus "
            "and report a clean fleet. Nothing was recounted.")


def run_control_program(filename):
    """Run one control program and return (ok, seconds, output)."""
    started = time.monotonic()
    try:
        finished = subprocess.run([sys.executable, os.path.join(PACKAGE, filename)],
                                  capture_output=True, text=True, errors="replace",
                                  cwd=PACKAGE, timeout=CONTROL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return False, time.monotonic() - started, "timed out"
    output = (finished.stdout or "") + (finished.stderr or "")
    return finished.returncode == 0, time.monotonic() - started, output


def scorer_is_sound():
    """Run the controls and the pins before believing anything the scorer says."""
    sound = True
    for label, filename, what in CONTROL_PROGRAMS:
        ok, seconds, output = run_control_program(filename)
        print("%-9s %-7s %5.1fs  %s" % (label, "ok" if ok else "FAILED", seconds, what))
        if not ok:
            sound = False
            for line in output.strip().split("\n")[-25:]:
                print("      " + line)
    return sound


def collect_corpus(destination):
    """Re-collect the corpus from scratch and return its rows.

    Re-collected rather than read from a stored file, which is the whole point of a
    scheduled recount: a stored corpus dates from the night it was taken, so scoring it
    every morning would keep answering a question about that night's fleet. Run as a
    subprocess because the collector prints a report of its own and its module-level
    state is not built to be re-entered.
    """
    program = ("import sys; sys.path.insert(0, %r); "
               "import collect_markdown_claims as c; c.main(%r)" % (PACKAGE, destination))
    finished = subprocess.run([sys.executable, "-c", program], capture_output=True,
                              text=True, errors="replace", cwd=PACKAGE,
                              timeout=COLLECT_TIMEOUT_SECONDS)
    if finished.returncode != 0:
        return None, (finished.stdout or "") + (finished.stderr or "")
    with open(destination) as handle:
        return json.load(handle), finished.stdout


def recount(rows):
    """Score every paragraph claim that sits above a table or a list.

    Ported from the 339th pass's `run_widened.py`, unchanged in what it decides. The
    block is cut off where the population starts: a list item pulled into the block by
    the collector's paragraph extractor is part of what is being counted, not part of
    the claim that counts it.
    """
    sys.path.insert(0, PACKAGE)
    from classify import classify
    from collect_markdown_claims import REPOS_ROOT
    from score_tallies import score, population_beneath

    documents = {}

    def document(repo, path):
        # Read from the same root the collector used, so a selftest pointing the whole
        # run at a synthetic tree does not collect there and then score `~/repos`.
        key = (repo, path)
        if key not in documents:
            if repo == "(home)":
                with open(os.path.expanduser(path), errors="replace") as handle:
                    documents[key] = handle.read().split("\n")
            else:
                shown = subprocess.run(
                    ["git", "-C", os.path.join(REPOS_ROOT, repo),
                     "show", "main:" + path],
                    capture_output=True, text=True, errors="replace")
                documents[key] = shown.stdout.split("\n")
        return documents[key]

    scored, screened_out = [], 0
    for row in rows:
        if row["block_shape"] != "paragraph":
            continue
        if classify(row) == "NOT-A-CLAIM":
            screened_out += 1
            continue
        lines = document(row["repo"], row["file"])
        population = population_beneath(lines, row["line"] - 1, row["block_end"])
        if population is None:
            continue
        kind, count, declared, population_start = population
        block_end = population_start if population_start is not None else row["block_end"]
        block = "\n".join(lines[row["block_start"] - 1:block_end])
        claim_line = lines[row["line"] - 1].strip() if row["line"] - 1 < len(lines) else ""
        result = score(block, claim_line, count, declared)
        scored.append({"repo": row["repo"], "file": row["file"], "line": row["line"],
                       "population": kind, "claim": claim_line, **result})

    order = {"MISMATCH": 0, "NOT-COMPARABLE": 1, "MATCH": 2}
    scored.sort(key=lambda r: (order[r["verdict"]], r["repo"], r["file"], r["line"]))
    return scored, screened_out


def report(scored, screened_out, collected):
    for row in scored:
        print("%-14s %-30s %s/%s:%d" % (row["verdict"], row["reason"][:30], row["repo"],
                                        row["file"], row["line"]))
        print("      %s" % row["claim"][:118])
        print("      %d %s; readings %s" % (row["body_rows"], row["population"],
                                            [r["value"] for r in row["readings"]]))
    counts = {verdict: sum(1 for r in scored if r["verdict"] == verdict)
              for verdict in ("MATCH", "MISMATCH", "NOT-COMPARABLE")}
    print("\n%d rows collected; %d claim blocks above a countable population "
          "(%d NOT-A-CLAIM screened out)" % (collected, len(scored), screened_out))
    print("  %d MATCH  %d MISMATCH  %d NOT-COMPARABLE"
          % (counts["MATCH"], counts["MISMATCH"], counts["NOT-COMPARABLE"]))


def main(argv):
    parser = argparse.ArgumentParser(
        description="Recount the fleet's markdown quantity claims against the "
                    "populations they introduce.")
    parser.add_argument("--skip-controls", action="store_true",
                        help="do not run the scorer's controls and pins first; the "
                             "report says so out loud")
    parser.add_argument("--json", action="store_true",
                        help="write the scored rows as JSON instead of a report")
    parser.add_argument("--corpus-out", default=None,
                        help="keep the freshly collected corpus at this path instead of "
                             "a temporary file")
    args = parser.parse_args(argv[1:])

    if args.skip_controls:
        print("controls NOT run: asked not to")
    elif not scorer_is_sound():
        print("\nthe scorer's own controls are not sound; nothing was recounted",
              file=sys.stderr)
        return 1

    missing_toolchain = ensure_git_on_path()
    if missing_toolchain:
        print(missing_toolchain, file=sys.stderr)
        return 2

    if not os.path.isdir(PACKAGE):
        print("scorer package %s does not exist" % PACKAGE, file=sys.stderr)
        return 2

    handle, temporary = tempfile.mkstemp(prefix="markdown-tally-corpus-", suffix=".json")
    os.close(handle)
    destination = args.corpus_out or temporary
    try:
        rows, collector_output = collect_corpus(destination)
        if rows is None:
            print("the collector failed; nothing was recounted", file=sys.stderr)
            print(collector_output, file=sys.stderr)
            return 2
        if not rows:
            # A collector that reached no repositories and a fleet whose markdown states
            # no quantities print the same empty result. Refuse rather than report clean.
            print("the collector returned no rows at all, which means it did not run "
                  "rather than that the fleet states no quantities", file=sys.stderr)
            return 2
        if not args.json:
            print()
            print(collector_output.rstrip())
            print()
        scored, screened_out = recount(rows)
    finally:
        os.unlink(temporary)

    if not scored:
        print("nothing was scored: %d rows collected and no claim block sits above a "
              "countable population, which is a collector or classifier failure rather "
              "than a clean fleet" % len(rows), file=sys.stderr)
        return 2

    if args.json:
        json.dump(scored, sys.stdout, indent=1)
        print()
    else:
        report(scored, screened_out, len(rows))

    mismatched = [r for r in scored if r["verdict"] == "MISMATCH"]
    if mismatched:
        print("\n%d document(s) state a total that the population beneath them "
              "contradicts:" % len(mismatched), file=sys.stderr)
        for row in mismatched:
            print("  %s/%s:%d  %s" % (row["repo"], row["file"], row["line"],
                                      row["claim"][:100]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
