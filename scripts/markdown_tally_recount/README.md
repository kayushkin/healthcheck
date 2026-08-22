# The markdown tally recount

A maintained document says `four canonical role families` and then lists them. The
sentence and the list state the same number twice, written in one moment and maintained
separately ever after. Add a row to the list without touching the sentence and the
document asserts the old count in prose while displaying the new one underneath. Nothing
fails, nothing warns, and the sentence is what a reader believes.

This package recounts those claims. `../markdown-tally-recount-audit.py` is the entry
point and the only thing meant to be run on a schedule.

## Where it came from, and why it moved

The scorer, its controls and its pins were written by the **339th nightly pass** into
`~/.nightly-339-tallyscore/`, over a corpus collected by the **293rd** into
`~/.nightly-293/`. Card `7071d32f` filed the gap that outlived the answer: **nothing
invoked it.** It ran when a pass remembered it existed.

The card offered three ways out — a scheduler job, a step in another pass's `run.sh`, or
moving it into a repo with a home and an owner — and a later append settled that the
first and third are not exclusive: the six `repo-*` guards are scheduler shell jobs whose
scripts live in this repo. That is what this is.

`~/.nightly-*` is under no version control (card `4707e6f3`), so the modules travelled
here rather than being imported across. A guard reaching into a pass directory is one
`rm -rf` away from dying, or worse, from quietly scoring a stale copy.

| file | what it is | origin |
|---|---|---|
| `collect_markdown_claims.py` | collects quantity-stating claims from tracked markdown, read off each repo's `main` | `~/.nightly-293/` |
| `classify.py` | buckets a row; the guard uses it only to screen `NOT-A-CLAIM` | `~/.nightly-293/` |
| `score_tallies.py` | the scorer: a claim, its population, a verdict | `~/.nightly-339-tallyscore/` |
| `control_score_tallies.py` | eight two-directional control pairs over the scorer | `~/.nightly-339-tallyscore/` |
| `pinned_known_rot.py` | three known-rot rows, each scored against its pre-repair text | `~/.nightly-339-tallyscore/` |
| `fixtures/home-CLAUDE.md.before-repair` | the pre-repair text one pin scores | `~/.nightly-293/CLAUDE.md.before` |

## What changed in the move, and why

Three things, all of them because a scheduled run is not a hand run:

1. **`REPOS_ROOT` honours `MARKDOWN_TALLY_REPOS_ROOT`.** Without it there is no way to
   drive the guard over a repository built for the purpose, and therefore no way to see
   it report a MISMATCH. A guard nobody has watched go red is a guard nobody can trust
   going green.
2. **The pins' repaired side reads a named commit, not the working tree.** The original
   read `~/repos/kayushkin.com/MANGA_BUG_FIX_SUMMARY.md` off disk. The collector states
   the rule for the corpus — *re-taken against `main` rather than the working tree ...
   every repo here is liable to be checked out on another agent's branch* — and it binds
   a pin harder than a corpus. A pin read off whatever branch a repo happens to be on
   fails for reasons that have nothing to do with the scorer.
3. **Data paths point beside the package**, not back at `~/.nightly-293/`.

Nothing about what the scorer *decides* changed. The controls and the pins pass unaltered.

## Running it

    ../markdown-tally-recount-audit.py              # controls, then a fresh recount
    ../markdown-tally-recount-audit.py --json       # the scored rows, machine-readable
    ../markdown-tally-recount-audit-selftest.py     # 9 arms over the guard's own modes

The corpus is **re-collected on every run**. A stored corpus dates from the night it was
taken, so scoring one every morning would keep answering a question about that night.

## The verdicts

    MATCH            some reading of the claim equals the population's size, or the
                     total the population's own entries declare about themselves
    MISMATCH         the claim is TOTAL-QUANTIFIED (`all N`, `exactly N`, `every N`,
                     `both N`), so the population beneath it is beyond doubt what it
                     counts, and no reading of it agrees
    NOT-COMPARABLE   everything else, with a named reason

**Only MISMATCH is a finding.** The asymmetry is the scorer's and is deliberate: a false
MATCH loses one rotted count, which is what was being lost anyway while nothing recounted
these at all; a false MISMATCH sends a reader back to a document that was right, and a
check this cheap survives only as long as it is trusted.

`NOT-COMPARABLE` is reported loudly and is not a failure. It means the claim and the
population are not the same question — a claim counting a *subset* of the table beneath
it is the common case, and calling that rot would be a right answer by a broken road.

## Exit codes

    0   every claim block recounted, none mismatched
    1   at least one MISMATCH, or the scorer's own controls are not sound
    2   the recount could not be carried out: no `git`, no package, an empty corpus,
        or nothing scorable

Exit 2 is kept apart from exit 1 so a caller cannot read *could not run* as *ran and
found nothing*. That separation is the whole design here, because **every way this guard
can fail looks like a clean fleet**: without `git`, every `git show` fails and the
collector cannot tell that from a file with no claims in it. The selftest's
`missing-git-refuses` arm exists for exactly that, and asserts on `exit != 0` before it
asserts on `exit == 2`.
