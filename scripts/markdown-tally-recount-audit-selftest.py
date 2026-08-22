#!/usr/bin/env python3
"""Show `markdown-tally-recount-audit.py` reporting each of its outcomes, on demand.

The scorer inside `markdown_tally_recount/` has its own controls, and they are good ones
-- eight two-directional pairs plus three pinned known-rot rows. They prove the *scoring
function*. They cannot prove the *guard*: that a MISMATCH in a real document, read out of
a real `git` repository by the real collector, reaches this program's exit code. A
self-test proves the function; only a probe proves the mode.

That distinction is not academic here. Every failure this guard can have looks like
success from the outside:

  * `git` missing -> every `git show` fails -> the collector treats each failure as a
    file with no claims in it -> an empty corpus -> **a clean fleet**.
  * a collector that reaches no repositories at all -> zero rows -> **a clean fleet**.
  * a classifier that screens everything out -> zero scored blocks -> **a clean fleet**.

So each arm below drives the whole program and asserts on its exit code, and the arms
that matter are the ones that must NOT be zero. `--list-arms` names them; an unrecognised
flag is refused with exit 2 rather than run anyway.

Every arm builds its own repository under a temporary root and points the guard at it
with `MARKDOWN_TALLY_REPOS_ROOT`, so nothing here reads or writes the real `~/repos`.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "markdown-tally-recount-audit.py")
PACKAGE = os.path.join(HERE, "markdown_tally_recount")

# The one line only a completed recount prints. Used to tell "refused before
# recounting" from "recounted and found nothing".
RECOUNT_SUMMARY = "claim blocks above a countable population"

# A paragraph claiming a total, above a table with a different number of rows. `All four`
# is TOTAL-QUANTIFIED, so the scorer is entitled to call the table its population -- this
# is the one shape that yields MISMATCH rather than NOT-COMPARABLE.
ROTTED_DOCUMENT = """# Role families

All four role families are computed on read, never stored.

| family | meaning |
|---|---|
| backend | server work |
| frontend | browser work |
| data | pipelines |
| infra | the box |
| research | reading |
"""

# The same document with the sentence corrected to the table it sits above.
REPAIRED_DOCUMENT = ROTTED_DOCUMENT.replace("All four role families",
                                            "All five role families")

NO_CLAIMS_DOCUMENT = """# Notes

This document states no quantity at all and introduces no population.
"""


def build_repository(root, name, documents):
    """Create `<root>/<name>` as a git repository on `main` holding `documents`."""
    path = os.path.join(root, name)
    os.makedirs(path)
    run = lambda *args: subprocess.run(["git", "-C", path, *args], check=True,
                                       capture_output=True, text=True)
    run("init", "-q", "-b", "main")
    run("config", "user.email", "selftest@localhost")
    run("config", "user.name", "selftest")
    for filename, text in documents.items():
        with open(os.path.join(path, filename), "w") as handle:
            handle.write(text)
        run("add", filename)
    run("commit", "-q", "-m", "selftest fixture")
    return path


def run_guard(repos_root, extra_arguments=(), environment=None):
    """Run the guard against `repos_root` and return (exit_code, output)."""
    env = dict(os.environ)
    env["MARKDOWN_TALLY_REPOS_ROOT"] = repos_root
    env.update(environment or {})
    finished = subprocess.run([sys.executable, GUARD, *extra_arguments],
                              capture_output=True, text=True, errors="replace", env=env,
                              timeout=900)
    return finished.returncode, (finished.stdout or "") + (finished.stderr or "")


# --- the arms ----------------------------------------------------------------------
#
# Each returns (ok, detail). `--skip-controls` is passed wherever the arm is about the
# recount rather than about the controls: the scorer's own controls take about four
# seconds and re-running them in every arm would say nothing new. The two arms that are
# about the controls do not pass it.


def arm_rot_is_found(root):
    """A document whose total contradicts its own table must exit 1."""
    build_repository(root, "rotted", {"CONTRACT.md": ROTTED_DOCUMENT})
    code, output = run_guard(root, ["--skip-controls"])
    if code != 1:
        return False, "expected exit 1 on a rotted document, got %d\n%s" % (code, output)
    if "MISMATCH" not in output:
        return False, "exit 1 but no MISMATCH in the report:\n%s" % output
    if "CONTRACT.md" not in output:
        return False, "the finding does not name the document:\n%s" % output
    return True, "exit 1, MISMATCH named against rotted/CONTRACT.md"


def arm_repaired_document_is_clean(root):
    """The same document with the count corrected must exit 0.

    Without this arm the one above is satisfied by a guard that always exits 1, which is
    a guard that has found nothing and is merely broken in the loud direction.
    """
    build_repository(root, "repaired", {"CONTRACT.md": REPAIRED_DOCUMENT})
    code, output = run_guard(root, ["--skip-controls"])
    if code != 0:
        return False, "expected exit 0 on the repaired document, got %d\n%s" % (code, output)
    if "MISMATCH" in output.replace("0 MISMATCH", ""):
        return False, "clean run still reports a MISMATCH:\n%s" % output
    return True, "exit 0, and the repaired count is scored MATCH"


def arm_the_finding_survives_json(root):
    """`--json` must carry the same verdict; a formatter is not allowed to lose it."""
    build_repository(root, "rotted", {"CONTRACT.md": ROTTED_DOCUMENT})
    code, output = run_guard(root, ["--skip-controls", "--json"])
    if code != 1:
        return False, "expected exit 1 with --json, got %d" % code
    body = output[output.index("["):output.rindex("]") + 1]
    verdicts = [row["verdict"] for row in json.loads(body)]
    if "MISMATCH" not in verdicts:
        return False, "no MISMATCH row in the JSON: %s" % verdicts
    return True, "exit 1 and the MISMATCH row is in the JSON"


def arm_missing_git_refuses(root):
    """No `git` on PATH must exit 2 -- never 0.

    This is the arm the guard was written around. A missing toolchain makes every
    `git show` fail, and the collector cannot tell that from a file with nothing in it,
    so the honest-looking outcome is a clean fleet. Driven by emptying PATH and pointing
    the mise shim directory at somewhere that does not exist, which is the pair of
    conditions `ensure_git_on_path` checks.
    """
    build_repository(root, "rotted", {"CONTRACT.md": ROTTED_DOCUMENT})
    code, output = run_guard(root, ["--skip-controls"],
                             environment={"PATH": os.path.join(root, "no-such-bin"),
                                          "HOME": os.path.join(root, "no-such-home")})
    if code == 0:
        return False, "a missing toolchain reported a CLEAN FLEET (exit 0):\n%s" % output
    if code != 2:
        return False, "expected exit 2 without git, got %d\n%s" % (code, output)
    if "not on PATH" not in output:
        return False, "exit 2 but the reason is not stated:\n%s" % output
    return True, "exit 2, and the report says the toolchain is missing"


def arm_empty_fleet_refuses(root):
    """A root with no repositories in it must exit 2, not report a clean fleet."""
    os.makedirs(os.path.join(root, "not-a-repo"))
    code, output = run_guard(root, ["--skip-controls"])
    if code == 0:
        return False, "an empty collection reported a CLEAN FLEET (exit 0):\n%s" % output
    if code != 2:
        return False, "expected exit 2 on an empty collection, got %d\n%s" % (code, output)
    return True, "exit 2 on a collection that reached nothing"


def arm_nothing_scorable_refuses(root):
    """Rows collected but no claim block above a population must exit 2, not 0.

    A classifier that screened every row away and a fleet whose documents are all clean
    produce the same empty table of verdicts. Only the row count tells them apart.
    """
    build_repository(root, "quiet", {"NOTES.md": NO_CLAIMS_DOCUMENT})
    code, output = run_guard(root, ["--skip-controls"])
    if code != 2:
        return False, "expected exit 2 when nothing is scorable, got %d\n%s" % (code, output)
    return True, "exit 2 when the corpus yields no scorable block"


def arm_unsound_controls_stop_the_run(root):
    """If the scorer's controls fail, the guard must exit 1 and recount nothing.

    Driven by giving the guard a package whose control program exits non-zero. A guard
    that recounts anyway is reporting verdicts from an instrument just shown to be
    broken.
    """
    build_repository(root, "rotted", {"CONTRACT.md": ROTTED_DOCUMENT})
    broken = os.path.join(root, "broken-package")
    # The WHOLE package, `fixtures/` included. Copying only the top-level files leaves
    # the pins dying on a missing fixture, which fails the guard for the right reason by
    # the wrong road -- the arm is about a control that reports a defect, not about one
    # that cannot start.
    shutil.copytree(PACKAGE, broken)
    with open(os.path.join(broken, "control_score_tallies.py"), "w") as handle:
        handle.write("import sys\nprint('a control that fails')\nsys.exit(1)\n")

    copied_guard = os.path.join(root, "markdown-tally-recount-audit.py")
    with open(GUARD) as handle:
        body = handle.read()
    with open(copied_guard, "w") as handle:
        handle.write(body.replace('"markdown_tally_recount")', '"broken-package")'))

    env = dict(os.environ)
    env["MARKDOWN_TALLY_REPOS_ROOT"] = root
    finished = subprocess.run([sys.executable, copied_guard], capture_output=True,
                              text=True, errors="replace", env=env, timeout=900)
    output = (finished.stdout or "") + (finished.stderr or "")
    if finished.returncode != 1:
        return False, "expected exit 1 on unsound controls, got %d\n%s" % (
            finished.returncode, output)
    # Assert on evidence that a RECOUNT happened, not on the word MISMATCH appearing
    # somewhere: the pins print their own expected verdicts, MISMATCH among them, so
    # searching the whole output for that word marks a correct refusal as a failure.
    # Only a recount prints its summary line.
    if RECOUNT_SUMMARY in output:
        return False, "the guard recounted anyway after its controls failed:\n%s" % output
    return True, "exit 1, and nothing was recounted"


def arm_controls_run_by_default(root):
    """The real controls must actually run when not skipped, and pass."""
    build_repository(root, "repaired", {"CONTRACT.md": REPAIRED_DOCUMENT})
    code, output = run_guard(root)
    if code != 0:
        return False, "expected exit 0 with controls run, got %d\n%s" % (code, output)
    for label in ("controls", "pins"):
        if ("%s    ok" % label) not in output.replace("  ", "  "):
            if "%s " % label not in output or "FAILED" in output:
                return False, "the %s arm did not report ok:\n%s" % (label, output)
    return True, "controls and pins both ran and passed"


def arm_unrecognised_flag_is_refused(root):
    """An argument the guard does not know must be refused, not ignored."""
    code, output = run_guard(root, ["--recount-everything-twice"])
    if code != 2:
        return False, "expected exit 2 on an unknown flag, got %d\n%s" % (code, output)
    return True, "exit 2 on an unrecognised flag"


ARMS = [
    ("rot-is-found", arm_rot_is_found),
    ("repaired-document-is-clean", arm_repaired_document_is_clean),
    ("finding-survives-json", arm_the_finding_survives_json),
    ("missing-git-refuses", arm_missing_git_refuses),
    ("empty-fleet-refuses", arm_empty_fleet_refuses),
    ("nothing-scorable-refuses", arm_nothing_scorable_refuses),
    ("unsound-controls-stop-the-run", arm_unsound_controls_stop_the_run),
    ("controls-run-by-default", arm_controls_run_by_default),
    ("unrecognised-flag-is-refused", arm_unrecognised_flag_is_refused),
]


def main(argv):
    parser = argparse.ArgumentParser(
        description="Drive markdown-tally-recount-audit.py through each outcome it can "
                    "report and assert on its exit code.")
    parser.add_argument("--list-arms", action="store_true", help="name the arms and stop")
    parser.add_argument("--arm", action="append", default=None,
                        help="run only this arm; repeatable")
    args = parser.parse_args(argv[1:])

    if args.list_arms:
        for name, function in ARMS:
            print("%-32s %s" % (name, (function.__doc__ or "").strip().split("\n")[0]))
        return 0

    chosen = [(name, function) for name, function in ARMS
              if args.arm is None or name in args.arm]
    if not chosen:
        print("no arm matched %s" % args.arm, file=sys.stderr)
        return 2

    failures = []
    for name, function in chosen:
        with tempfile.TemporaryDirectory(prefix="tally-selftest-") as root:
            try:
                ok, detail = function(root)
            except Exception as error:  # an arm that dies is an arm that did not answer
                ok, detail = False, "raised %s: %s" % (type(error).__name__, error)
        print("%-6s %-32s %s" % ("ok" if ok else "FAILED", name, detail.split("\n")[0]))
        if not ok:
            failures.append((name, detail))

    print()
    if failures:
        for name, detail in failures:
            print("--- %s" % name)
            print(detail)
        print("%d of %d arms FAILED" % (len(failures), len(chosen)))
        return 1
    print("%d of %d arms behaved" % (len(chosen), len(chosen)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
