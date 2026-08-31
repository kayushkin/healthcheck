#!/usr/bin/env python3
"""nightly-shared-control-set-audit — run every control set that guards a shared
instrument, and say which ones ran.

`~/.nightly-shared/` holds the instruments that outlive the pass that wrote them.
Several of them carry control sets: a self-test that drives the instrument over a
fixed case list, plus sabotage arms that break the instrument deliberately and must
redden at least one case. Until this script existed, **nothing invoked any of them**.
They ran when a nightly pass remembered they were there, which is the standing
complaint on noteboard cards `2890f2db`, `7071d32f` and `f47d1d1c`.

A cheap check nobody runs is not cheaper than an expensive one; it is worth nothing.

## What it checks, and why each half is load-bearing

1. **The clean arm of every control set.** A control set whose clean arm is red is an
   instrument nobody can trust, whichever way it answers.

2. **Every sabotage arm the control set will name.** A clean arm alone proves the
   instrument can say "yes". Only a sabotage proves it can say "no", and an
   instrument that cannot say "no" reports every tree as green — including the ones
   with the defect in them. A sabotage that leaves the control set green is a case
   list with a hole in it, and it fails this audit.

3. **Which control sets did not get their sabotage arms run, and why.** A control set
   that does not honour `--sabotage` cannot be asked what its arms are, so this script
   runs its clean arm only and *says so per control set*. An unrun arm and a passing
   arm read alike, and only one of them is a fact.

4. **Coverage of the instrument directory.** A module with no control set at all is
   reported by name. `KNOWN_UNCOVERED` below is the baseline that was true when this
   script was written; a module that is uncovered and *not* in that list is a new
   instrument that arrived without a control set, and it fails. So does a module in
   the list that has since gained one — the baseline is then a lie, and a lying
   baseline is exactly the silent rot this family of cards is about.

5. **Which of the root's files are control sets at all**, and this is decided by what
   a file *declares*, not by what it is called. A control set here declares the table
   of arms it can be asked to run — `SABOTAGES`, `ARMS`, `CASES`, `NEGATIVE_CONTROLS`
   or `CONTROL_ARMS` — and `discover` reads that off the ast without importing
   anything. Until 2026-08-31 it read the `_selftest` suffix instead, and card
   `da86b1ab` measured what that costs: a control set spelled otherwise is not
   recognised, so **none of its arms is ever run**, and it is then counted as a module
   needing a guard of its own. One spelling, two wrong answers, and the docstring above
   is the argument against the first of them — a cheap check nobody runs is worth
   nothing. Latent at 0 of 25 the day it was found, because every control set in the
   root is spelled `<module>_selftest.py`; it fires on the next promotion that is not.
   The suffix still answers the *other* question — which module a control set guards —
   because nothing structural does. `UNSUFFIXED_CONTROL_SETS` carries that answer where
   the name cannot, and a recognised control set with neither runs its arms and is
   reported as covering nothing, rather than being quietly attributed to a guess.

## ⛔ The exit code does not carry the verdict, and it differs per control set

Measured 2026-08-22 over the four control sets on this box, and it is the reason this
script is longer than a loop over `python3 <selftest>`. Each column is an exit status,
taken with the status captured into a variable on its own line — reading `$?` inside a
string that also holds a `$(...)` substitution gives you the substitution's status, and
that mis-measured this very table once:

    control set                            unrecognised  unknown   --list-     caught
                                               flag        arm    sabotages   sabotage
    ~/.nightly-348-buildtags/selftest.py    0 -> 2          2         0           0
    reach_control_selftest.py               0 -> 2          2         0           0
    collect_reach_claims_selftest.py          2            1         0           1
    unbuilt_test_scope_selftest.py          0 -> 2        0 -> 2    0 -> 0        0

**Two of the four exit 0 when a sabotage is caught**, so a runner that reads only the
exit code cannot tell a caught sabotage from a hole in the case list — it would call
both green. `reach_control_selftest.py` carries a sabotage arm named
`read-only-the-exit-code` warning against exactly this, so the mistake is a known one.
This script therefore reads a sabotage verdict as **caught** when the arm exits
non-zero *or* prints a `caught by N row(s)/case(s)` line with N of one or more, records
per arm which of the two said so, and calls the verdict UNREADABLE — a finding, never a
pass — when neither does. That fork is still open: it is the contested half of card
`3165bed1` and no control set's verdict convention was changed.

## ⛔ A crash is not a verdict, and it is loud on the channel a catch is quiet on

Card `43a460d2`, 2026-08-30: 11 of the 20 shared scorers answer a harness-break probe
with an uncaught Python traceback rather than a graded arm. From the scorer's own
printed output that is the safe direction — it refused to grade, so it cannot report a
false catch. But a traceback exits non-zero, and non-zero is the first channel above.
So the same break the scorer refused to grade was graded a **catch** one layer up, and
the run went GREEN with zero findings. Reproduced end to end before repair.

`harness_break_line` now reads the arm's output for a traceback and
`read_sabotage_verdict` asks it **before** either verdict channel, stamping the third
outcome `harness-break` — a finding, never a catch and never a hole. The same reading
guards the `--sabotage` capability probe, which had the defect in its sharpest form: a
control set that crashed on the nonsense arm exited non-zero, was therefore declared to
honour the flag, had its arms listed and run, and every one of those arms crashed and
was graded caught. `worktree_cost_selftest.py` is the box's worked example of a control
set reporting this shape about itself.

⚠️ **What this does NOT do**, and it is the open half of `43a460d2`: it changes no
scorer. Whether a harness break should be a distinct **exit status** on the 11 — a
third code rather than 0/1 — is a convention change across other passes' instruments
and is not an unattended call. This repair makes the audit stop misreading them; it
does not make them speak.

**The `->` columns are what card `3165bed1` closed on 2026-08-22.** THREE of the four
ignored an unrecognised flag — not two, as this docstring said before it was re-measured
— and printed their ordinary green report, so `--list-sabotages` against them yielded
that report and an unguarded reader parsed its prose into sabotage names. All four now
refuse an unrecognised flag with exit 2 and answer `--list-sabotages`, and
`refuses_an_unrecognised_flag` below makes a set that stops doing so a **finding**
rather than a silence. `unbuilt_test_scope_selftest.py` implemented none of the three
probes; giving it `--sabotage <name>` took this audit from 25 arms to 34, because its
nine arms could not be reached from outside before.

Capability is still probed, never assumed, and this script still reads the old dialect:
a control set arriving tomorrow may speak it, and the reading has to survive that. Before
trusting any name list it probes with `--sabotage __no_such_arm__`, and a name list is
rejected when it comes back equal to the clean report.

⚠️ **A listable arm name cannot contain whitespace.** Every reader of a
`--list-sabotages` list takes the first whitespace-delimited token as the name, so an arm
called `ignored/compiled inverted` is asked for as `ignored/compiled`, refused, and the
refusal's non-zero exit reads as a caught sabotage. `unbuilt_test_scope_selftest.py`'s
nine arms were renamed to hyphenated slugs for exactly this reason.

## Reporting

Every control set that ran is named in the output with its exit status and duration,
and so is every sabotage arm. A run that says "all green" without saying which sets it
ran is the same defect one layer up (215th pass: a probe that could not run is not a
negative result).

## Usage

    scripts/nightly-shared-control-set-audit.py            # audit ~/.nightly-shared
    scripts/nightly-shared-control-set-audit.py --root DIR # audit a fixture directory
    scripts/nightly-shared-control-set-audit.py --json     # machine-readable result

Every run **first runs this script's own control set**, clean arm and all seven sabotage
arms, and audits nothing if it is not sound: an audit whose instrument cannot report a
defect says green either way. `--skip-own-control-set` turns that off for a fast manual
run and the report says so out loud. The control set drives this script in turn, and
`NIGHTLY_CONTROL_SET_AUDIT_RUNNING` in the environment breaks the recursion the same way
`find_controls.py --run` breaks its own.

Exit 0 = every control set ran and behaved. Exit 1 = at least one finding, or this
script's own control set is unsound. Exit 2 = the audit could not be carried out at all
(the root is missing) — kept apart from exit 1 so a caller cannot read "could not run"
as "ran and found nothing".

Pinned by `scripts/nightly-shared-control-set-audit-selftest.py`: 38 cases and 17
sabotage arms, clean 38/38 and all 17 caught, measured 2026-09-25 when the arm-table
branch (34 cases, 15 arms) and the traceback branch (29 cases, 11 arms) were merged.
An instrument that miscounts its own control set is the one number a reader cannot
check cheaply, so re-take it when you add a case or an arm.
"""

import argparse
import ast
import collections
import json
import os
import shutil
import subprocess
import sys
import time

DEFAULT_ROOT = os.path.expanduser("~/.nightly-shared")

# Control sets that guard a module in the root but do not live beside it. The only
# member today is the build-tag predicate's, which stayed in the pass directory that
# wrote it. A registered path that has gone missing is a FAILURE, never a skip: the
# module is still here and the thing that proved it works is not.
EXTERNAL_CONTROL_SETS = {
    "compiled_here": "~/.nightly-348-buildtags/selftest.py",
}

# Modules in the root that had no control set when this script was written. Each entry
# is a standing gap, not a licence: the audit fails if the list stops matching what is
# on disk in either direction. `citation_screen` and `stale_identifier_neighbourhood`
# are here because `~/.nightly-shared/README.md` calls their controls "in-file" and
# neither file contains one — their controls live scattered in `~/.nightly-*` pass
# directories, reachable only through `find_controls.py`.
KNOWN_UNCOVERED = {
    "citation_screen",
    "find_controls",
    "fleet_repos",
    "stale_identifier_neighbourhood",
}

# The structural property that separates a control set from the module it guards: a
# control set declares the table of arms it can be asked to run. Measured over
# `~/.nightly-shared` on 2026-08-31 — 54 python files, 25 control sets — this predicate
# reproduces every row the `_selftest` suffix produces, with no file classified
# differently by the two channels.
ARM_TABLE_NAMES = frozenset({
    "ARMS",
    "CASES",
    "CONTROL_ARMS",
    "NEGATIVE_CONTROLS",
    "SABOTAGES",
})

# Control sets that live in the root and whose filename does not carry the `_selftest`
# suffix, so nothing in the name says which module they guard. The structural channel
# recognises them as control sets and runs them either way; this registry is the only
# thing that can say what they cover, so without an entry the module they guard is
# still reported uncovered. Empty today — every control set in the root is spelled
# `<module>_selftest.py` — and, like the two registries above, the audit fails if it
# stops matching disk in either direction.
UNSUFFIXED_CONTROL_SETS = {
    # "control.py": "name_keyed_routing",
}

# A control set is allowed this long for its clean arm and for each sabotage arm. The
# slowest arm on this box takes about three seconds; the cap is here so a control set
# that wedges fails the audit instead of holding the scheduler slot until the job's own
# wall-clock cap kills the whole run and loses every result collected so far.
ARM_TIMEOUT_SECONDS = 600

# Three of the four control sets shell out to `go`, and on this box `go` is reachable
# only through mise's shim directory, which a login shell puts on PATH and the scheduler
# does not. `healthcheck/deploy.sh` prepends the same directory for the same reason.
MISE_SHIM_DIRECTORY = os.path.expanduser("~/.local/share/mise/shims")

# Indirection so the audit's own control set can take the toolchain away.
find_executable = shutil.which


def ensure_go_toolchain_on_path():
    """Put `go` on PATH, or say why the audit cannot be carried out.

    ⛔ Measured on this guard's first scheduled run: without it, three of the four
    control sets die with `FileNotFoundError: 'go'` and the audit reports three red
    clean arms. That reads as three broken instruments and is nothing of the kind — the
    probe could not run, and a probe that could not run is not a negative result (215th
    pass). So a missing toolchain refuses the whole audit rather than colouring it.
    """
    if find_executable("go"):
        return None
    if os.path.isdir(MISE_SHIM_DIRECTORY):
        os.environ["PATH"] = MISE_SHIM_DIRECTORY + os.pathsep + os.environ.get("PATH", "")
        if find_executable("go"):
            return None
    return (
        "`go` is not on PATH and mise's shim directory did not supply it. Three of the "
        "four control sets shell out to the Go toolchain and would all report a red "
        "clean arm, which would read as three broken instruments rather than one "
        "missing toolchain, so nothing was audited."
    )


def module_stem(filename):
    """The importable name of a python file, or None if it is not one we audit.

    Skips the backup copies passes leave behind (`citation_screen.py.before-315`),
    which are not modules and whose control sets, if any, guard a dead version.
    """
    if not filename.endswith(".py"):
        return None
    return filename[: -len(".py")]


def declares_an_arm_table(path):
    """Does this file declare an arm table at module level, and is it readable at all?

    Returns `(declares, unreadable_because)`. The second half is not decoration: this
    predicate is the only thing in the audit that parses a file, so it is the only thing
    that can find one that does not parse, and a file the classifier could not read is a
    file it guessed about.

    The structural property of a control set on this box is that it declares the table
    of arms it can be asked to run — `SABOTAGES`, `ARMS`, `CASES`, `NEGATIVE_CONTROLS`
    or `CONTROL_ARMS` — and a module does not. Read statically off the ast, with no
    import, the same way `verify_hold.detect_shape` reads where a hold is taken: the
    files in this root run suites and shell out to `go`, and importing one to ask what
    it is would run it.

    Only top-level assignments count. A name bound inside a function is a local and says
    nothing about the file's shape, and `ast.walk` would count it.
    """
    try:
        with open(path, "rb") as handle:
            tree = ast.parse(handle.read(), filename=path)
    except (SyntaxError, ValueError) as error:
        return False, f"{type(error).__name__}: {error}"
    for node in tree.body:
        targets = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
            targets = [node.target]
        for target in targets:
            if isinstance(target, ast.Name) and target.id in ARM_TABLE_NAMES:
                return True, None
    return False, None


def control_set_exists(path):
    """Is this control set on disk?

    Its own function so the audit's control set can take it away and show that a
    registered path pointing at nothing then reads as a pass.
    """
    return os.path.exists(path)


CONTROL_SET_SUFFIX = "_selftest"

DiscoveredFiles = collections.namedtuple(
    "DiscoveredFiles",
    ["control_sets", "modules", "unattributed_control_sets", "unreadable"],
)


def discover(root, unsuffixed_control_sets=None):
    """Split the root's python files into control sets and the modules they guard.

    ⛔ **Classification is structural; only attribution reads the name.** Until
    2026-08-31 this function decided both questions off the `_selftest` suffix, and a
    control set spelled anything else got two wrong answers at once: it was not
    recognised as a control set, so none of its arms ever ran, and it was then counted
    as a module needing a guard of its own. Latent at 0 of 25 when it was found — every
    control set in the root is spelled `<module>_selftest.py` — and card `da86b1ab`
    names the promotion it fires on. A file that declares an arm table is a control set
    whatever it is called.

    The name channel is kept alongside the structural one rather than replaced by it,
    and the union is deliberate: a control set that builds its arms in a shape the ast
    read cannot see would otherwise be demoted to a module, and the two channels agree
    on every file in the root today, so the union costs nothing and can only add.

    Which module an unsuffixed control set guards is **not** derivable. Importing the
    guarded module looked like the answer and is not: measured over the root's 25
    control sets, only 9 import the module they guard, and `tree_hold_selftest.py`
    imports `instrument_answered` instead because it drives `tree_hold` as a
    subprocess. So the suffix stays the attribution channel where it is present,
    `unsuffixed_control_sets` is the registry for where it is not, and anything left
    over is returned unattributed rather than guessed at.
    """
    if unsuffixed_control_sets is None:
        unsuffixed_control_sets = UNSUFFIXED_CONTROL_SETS
    control_sets = {}
    modules = set()
    unattributed = {}
    unreadable = {}
    for filename in sorted(os.listdir(root)):
        stem = module_stem(filename)
        if stem is None:
            continue
        path = os.path.join(root, filename)
        declares, unreadable_because = declares_an_arm_table(path)
        if unreadable_because is not None:
            # A python file in the instrument root that will not parse is broken
            # whichever kind it is, and the classifier just guessed about it. Say so.
            unreadable[filename] = unreadable_because
        if not (declares or stem.endswith(CONTROL_SET_SUFFIX)):
            modules.add(stem)
            continue
        if stem.endswith(CONTROL_SET_SUFFIX):
            control_sets[stem[: -len(CONTROL_SET_SUFFIX)]] = path
        elif filename in unsuffixed_control_sets:
            control_sets[unsuffixed_control_sets[filename]] = path
        else:
            # Recognised, so it will be run; unattributed, so it covers nothing. Keyed
            # by its own stem to keep it out of `modules` and to give the report a name
            # to print — never by the module it might guard, which is the guess.
            unattributed[stem] = path
            control_sets[stem] = path
    return DiscoveredFiles(control_sets, modules, unattributed, unreadable)


CAUGHT_BY_MARKER = "caught by "

# The first line CPython writes for an unhandled exception. Both spellings occur: the
# plain one, and the "during handling of the above exception" chain.
TRACEBACK_MARKERS = (
    "Traceback (most recent call last):",
    "During handling of the above exception, another exception occurred:",
)


def harness_break_line(output):
    """The exception line of a control set that crashed, or None if it did not.

    A control set that dies with an unhandled exception did not grade its arm. It
    reached no case, said nothing about the instrument, and exited non-zero on the way
    out — and a non-zero exit is exactly the channel `read_sabotage_verdict` reads a
    CATCH from. So the safest-looking outcome the scorer can produce (it refused to
    answer) becomes the strongest one the audit can report (the sabotage was caught),
    and nothing in between notices. Card `43a460d2` measured 11 of the 20 shared
    scorers answering the harness-break probe this way.

    This is the audit's own docstring warning turned into a predicate. `list_sabotages`
    already says a bad arm name gets "a `KeyError` traceback per arm, and [the audit]
    reads every one of those tracebacks as a caught sabotage" — that was written about
    one path and is true of every path.

    Returns the last non-empty line of the crashed output (`KeyError: ...`), because a
    finding that does not say what broke sends the reader back to run the arm again.
    """
    if not any(marker in output for marker in TRACEBACK_MARKERS):
        return None
    lines = [line for line in output.strip().splitlines() if line.strip()]
    return lines[-1].strip() if lines else "an unhandled exception with no message"


def caught_row_count(output):
    """How many rows a sabotage arm says it reddened, or None if it does not say.

    The two control sets on this box that exit 0 on a caught sabotage both report the
    catch in this one shape — `caught by 5 row(s): [...]`, `caught by 7 case(s): [...]`
    — and it is the only signal separating them from a control set that did not notice
    its own instrument was broken. None and 0 are different answers: None is a control
    set that never made the claim, 0 is one that made it and reddened nothing.
    """
    seen = None
    for line in output.splitlines():
        position = line.find(CAUGHT_BY_MARKER)
        if position < 0:
            continue
        remainder = line[position + len(CAUGHT_BY_MARKER):].split()
        if not remainder or not remainder[0].isdigit():
            continue
        seen = max(seen or 0, int(remainder[0]))
    return seen


def run_arm(command, label):
    """Run one arm of a control set and record how it went.

    `ok` is the honest reading of the arm: whether the process exited zero. Deciding
    what a zero *means* is the caller's job, and it is not the same question for the
    two arms — a clean arm must exit zero, while a sabotage arm's verdict is not in the
    exit code at all on half the control sets here (see the table in the module
    docstring), so the caller reads it with `caught_row_count` as well.
    """
    started = time.monotonic()
    try:
        finished = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=ARM_TIMEOUT_SECONDS,
        )
        exit_code = finished.returncode
        output = finished.stdout.decode("utf-8", "replace")
        timed_out = False
    except subprocess.TimeoutExpired as expired:
        exit_code = None
        output = (expired.output or b"").decode("utf-8", "replace")
        timed_out = True
    return {
        "label": label,
        "command": command,
        "exit_code": exit_code,
        "timed_out": timed_out,
        "seconds": round(time.monotonic() - started, 1),
        "ok": exit_code == 0,
        "caught_rows": caught_row_count(output),
        "output": output,
        "output_tail": "\n".join(output.strip().splitlines()[-4:]),
    }


def read_sabotage_verdict(arm):
    """Stamp `arm` with what its sabotage did, and return a complaint or None.

    The verdict is not in the exit code on every control set here, so both channels are
    read and the one that answered is recorded on the arm. Shared with the audit's own
    control set, which speaks the non-zero dialect, so this function is the one place
    that knows how to read either.
    """
    broke = harness_break_line(arm["output"])
    if broke:
        # Asked before either verdict channel, because a crash speaks the same channel
        # a catch does and speaks it louder. An arm that raised graded nothing, so
        # neither "caught" nor "uncaught" is available — the third outcome is the only
        # honest one, and it is a finding. `worktree_cost_selftest.py` is the worked
        # example of a control set reporting this shape about itself.
        arm["verdict"] = "harness-break"
        arm["verdict_read_from"] = "an unhandled exception, which grades nothing"
        return f"crashed instead of grading: {broke}"
    if not arm["ok"]:
        arm["verdict"] = "caught"
        arm["verdict_read_from"] = "the exit code"
        return None
    if arm["caught_rows"]:
        arm["verdict"] = "caught"
        arm["verdict_read_from"] = f"{arm['caught_rows']} caught row(s)"
        return None
    if arm["caught_rows"] == 0:
        arm["verdict"] = "uncaught"
        arm["verdict_read_from"] = "a caught-by line naming no rows"
        return "reddened no rows"
    # Neither channel spoke. Calling this a pass is the failure mode the whole script
    # is written around, so it is a complaint instead.
    arm["verdict"] = "unreadable"
    arm["verdict_read_from"] = "neither the exit code nor a caught-by line"
    return "exited 0 and reported no caught rows, so its verdict is unreadable"


NONSENSE_SABOTAGE = "__no_such_sabotage_arm__"

# A flag no control set can implement. Distinct from NONSENSE_SABOTAGE above: that one
# asks whether `--sabotage` is honoured, this one asks whether an argument the control
# set does not recognise is refused at all.
NONSENSE_FLAG = "--__no_such_flag_on_any_control_set__"

# `main` runs this script's own control set before auditing anything, and that control
# set drives this script. The env var breaks the recursion the same way
# `find_controls.py --run` breaks its own.
NESTING_GUARD_VARIABLE = "NIGHTLY_CONTROL_SET_AUDIT_RUNNING"

OWN_CONTROL_SET = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "nightly-shared-control-set-audit-selftest.py",
)


def run_own_control_set(stream=None):
    """Run this script's control set — clean arm and every sabotage — before auditing.

    An audit whose own instrument is broken cannot be read, whichever way it answers, so
    a red here stops the run rather than colouring it. A missing control set is the same
    thing and is reported as one: 'the control set is gone' and 'the control set passed'
    must never print alike.
    """
    if not control_set_exists(OWN_CONTROL_SET):
        print(f"own control set {OWN_CONTROL_SET} is not on disk", file=stream)
        return False

    previous = os.environ.get(NESTING_GUARD_VARIABLE)
    os.environ[NESTING_GUARD_VARIABLE] = "1"
    try:
        clean = run_arm([sys.executable, OWN_CONTROL_SET], "clean")
        print(f"own control set  clean  exit {clean['exit_code']}  {clean['seconds']}s",
              file=stream)
        if not clean["ok"]:
            print(clean["output_tail"], file=stream)
            return False

        names = list_sabotages(OWN_CONTROL_SET, clean["output"])
        if not names:
            print("own control set will not list its sabotage arms", file=stream)
            return False

        healthy = True
        for name in names:
            arm = run_arm(
                [sys.executable, OWN_CONTROL_SET, "--sabotage", name], f"sabotage {name}"
            )
            complaint = "timed out" if arm["timed_out"] else read_sabotage_verdict(arm)
            print(
                f"own control set  sabotage {name}  "
                + (complaint or f"caught by {arm['verdict_read_from']}"),
                file=stream,
            )
            if complaint:
                healthy = False
        return healthy
    finally:
        if previous is None:
            os.environ.pop(NESTING_GUARD_VARIABLE, None)
        else:
            os.environ[NESTING_GUARD_VARIABLE] = previous


def probe_sabotage_flag(path):
    """Does this control set implement `--sabotage`, ignore it, or crash on it?

    Two of the four control sets on this box ignore an argument they do not recognise
    and print their ordinary green report. Asking one of those for `--list-sabotages`
    returns its whole report, and a reader that splits it into words gets sabotage arms
    named `CAUGHT`, `GREEN` and `9/9`. So capability is probed, never assumed: a
    control set that honours the protocol must refuse an arm that cannot exist.

    Three outcomes, not two, and the third is why this is no longer a predicate called
    `honours_sabotage_flag`. A control set that raises on the nonsense arm exits
    non-zero, which the old reading took for the clean refusal it was hoping for — so a
    crashing control set was declared conforming, its arms were listed and run, and
    every one of those arms crashed too and was graded a caught sabotage. That is card
    `43a460d2` in one call: the probe and the verdict read the same channel, and a
    harness break is louder on it than either answer.

    Returns `{"honoured": bool, "harness_break": str or None}`. A break is reported by
    the caller and never counted as either answer.
    """
    arm = run_arm([sys.executable, path, "--sabotage", NONSENSE_SABOTAGE], "probe")
    if arm["timed_out"]:
        return {"honoured": False, "harness_break": None}
    broke = harness_break_line(arm["output"])
    if broke:
        return {"honoured": False, "harness_break": broke}
    # Either channel is enough, because the two conforming dialects use different ones:
    # a non-zero exit, or a line saying the name is not one of its arms.
    honoured = arm["exit_code"] != 0 or "unknown sabotage" in arm["output_tail"].lower()
    return {"honoured": honoured, "harness_break": None}


def refuses_an_unrecognised_flag(path):
    """Does this control set refuse an argument it does not know, or run anyway?

    A control set that ignores an unrecognised flag answers every question with its
    ordinary green report, so no caller can tell an honoured flag from an ignored one —
    and the ignored reading is the green one. `--list-sabotages` against such a set
    hands back its whole suite report, and a reader that splits that into words gets
    sabotage arms called `ok`, `CLEAN:` and `9/9`, runs each, and reads the resulting
    refusals as caught sabotages. That is what this audit's own first draft did, and it
    printed 25 findings that were all artefacts.

    The refusal has to be in the **exit code**. A control set that prints a complaint
    and exits 0 is still green to every caller reading the status, which is the same
    defect one layer down. Three of the four control sets on this box ignored an
    unrecognised flag until card `3165bed1`; all four refuse one now, so this predicate
    guards a property rather than describing one.
    """
    arm = run_arm([sys.executable, path, NONSENSE_FLAG], "probe-unrecognised-flag")
    if arm["timed_out"]:
        return False
    return arm["exit_code"] != 0


def list_sabotages(path, clean_output):
    """The sabotage arms this control set will name, or None if it will not name any.

    None and the empty list are different answers and the report keeps them apart:
    None means the control set cannot be asked, the empty list means it was asked and
    has none. Only called once `probe_sabotage_flag` has said `--sabotage` is real.

    Honouring `--sabotage` does not imply honouring `--list-sabotages`, and one of the
    four control sets on this box honours the first and ignores the second: it runs its
    whole suite instead, so an unguarded reader turns its report into sabotage arms
    called `ok` and `CLEAN:`, runs each, gets a `KeyError` traceback per arm, and reads
    every one of those tracebacks as a caught sabotage. `clean_output` is what makes
    that legible — a control set that ignores the flag answers it with the same report
    it just gave.
    """
    clean_arm = run_arm([sys.executable, path], "clean-again")
    try:
        finished = subprocess.run(
            [sys.executable, path, "--list-sabotages"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=ARM_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return None
    if finished.returncode != 0:
        return None
    listed = finished.stdout.decode("utf-8", "replace")
    # Compare against a fresh clean run as well as the stored one: a control set whose
    # report carries a duration or a count that moves between runs would otherwise
    # never match, and the flag would read as honoured on every control set.
    if listed == clean_output or listed == clean_arm["output"]:
        return None
    names = []
    for line in listed.splitlines():
        # Two shapes are in use: a bare name per line, and `name  description`
        # padded into a column. The first whitespace-delimited token is the name in
        # both. A line that does not start with a name is prose and is not an arm.
        stripped = line.strip()
        if not stripped:
            continue
        name = stripped.split()[0]
        if name.startswith("-"):
            continue
        names.append(name)
    return names or None


def audit(root, sabotage_arms=True, external_control_sets=None, known_uncovered=None,
          unsuffixed_control_sets=None):
    """Run every control set guarding a module in `root` and return the result.

    The three registries are parameters rather than reads of the module constants so
    that this function can be driven over a fixture directory. A control set that can
    only be pointed at the one directory it audits cannot be given cases, and an audit
    with no cases is the thing this whole file exists to argue against.
    """
    if external_control_sets is None:
        external_control_sets = EXTERNAL_CONTROL_SETS
    if known_uncovered is None:
        known_uncovered = KNOWN_UNCOVERED
    if unsuffixed_control_sets is None:
        unsuffixed_control_sets = UNSUFFIXED_CONTROL_SETS
    result = {
        "root": root,
        "control_sets": [],
        "uncovered": [],
        "unattributed_control_sets": [],
        "findings": [],
    }
    discovered = discover(root, unsuffixed_control_sets=unsuffixed_control_sets)
    control_sets, modules = discovered.control_sets, discovered.modules
    result["unattributed_control_sets"] = sorted(discovered.unattributed_control_sets)

    for filename in sorted(discovered.unreadable):
        # The classifier could not read this file, so whichever side it landed on was a
        # guess. A guess that is never reported is the silence this whole script argues
        # against, and it does not become a fact by being cheap to miss.
        result["findings"].append(
            f"{filename}: does not parse, so the audit could not tell a control set"
            f" from a module — {discovered.unreadable[filename]}"
        )

    for stem in sorted(discovered.unattributed_control_sets):
        # It runs — that is the half this repair bought. But nothing says which module
        # it guards, so that module is still reported uncovered, and a coverage answer
        # the audit knows is incomplete must not read as a clean one.
        result["findings"].append(
            f"{stem}: declares an arm table and does not end in {CONTROL_SET_SUFFIX!r},"
            f" so its arms run and nothing says which module it guards"
            f" — add it to UNSUFFIXED_CONTROL_SETS"
        )

    for filename, module in sorted(unsuffixed_control_sets.items()):
        # Both directions, exactly as the other two registries are checked: a registry
        # pointing at a file that is gone, or at a module that is gone, is rot.
        if not control_set_exists(os.path.join(root, filename)):
            result["findings"].append(
                f"{module}: UNSUFFIXED_CONTROL_SETS names {filename!r}, which is not in {root}"
            )
        elif module not in modules:
            result["findings"].append(
                f"{module}: UNSUFFIXED_CONTROL_SETS says {filename!r} guards it, and it"
                f" is not a module in {root}"
            )

    for module, path in external_control_sets.items():
        if module not in modules:
            # The module the registry names is gone. Say so rather than dropping the
            # entry: a registry pointing at nothing is rot, and it is silent.
            result["findings"].append(
                f"registry names module {module!r}, which is not in {root}"
            )
            continue
        control_sets.setdefault(module, os.path.expanduser(path))

    for module in sorted(control_sets):
        path = control_sets[module]
        record = {"module": module, "control_set": path, "arms": []}
        result["control_sets"].append(record)

        if not control_set_exists(path):
            record["missing"] = True
            result["findings"].append(
                f"{module}: control set {path} is registered and not on disk"
            )
            continue
        record["missing"] = False

        # Asked before the clean arm, because it is a question about whether this
        # control set can be asked anything at all. A set that ignores it still gets
        # its clean arm and its sabotage probes — the existing capability probes cope
        # with the old dialect — but the report no longer stays silent about it.
        record["refuses_unrecognised_flag"] = refuses_an_unrecognised_flag(path)
        if not record["refuses_unrecognised_flag"]:
            result["findings"].append(
                f"{module}: ignores an unrecognised flag and runs its ordinary report,"
                f" so no flag sent to it can be shown to have been read"
            )

        clean = run_arm([sys.executable, path], "clean")
        record["arms"].append(clean)
        if not clean["ok"]:
            if clean["timed_out"]:
                how = "timed out"
            else:
                broke = harness_break_line(clean["output"])
                how = (
                    f"crashed instead of running: {broke}"
                    if broke
                    else f"exit {clean['exit_code']}"
                )
            result["findings"].append(f"{module}: clean arm {how}")
            # The sabotage arms of a control set whose clean arm is red cannot be
            # read — a red they produce is indistinguishable from the red already
            # there — so they are not run, and the report says which ones those were.
            record["sabotages_run"] = False
            record["sabotages_unrun_because"] = "the clean arm is red"
            continue

        if not sabotage_arms:
            record["sabotages_run"] = False
            record["sabotages_unrun_because"] = "sabotage arms were not requested"
            continue

        flag_probe = probe_sabotage_flag(path)
        if flag_probe["harness_break"]:
            record["sabotages_run"] = False
            record["sabotages_unrun_because"] = (
                "the control set crashed on the capability probe, so whether it "
                "honours --sabotage is unknown rather than answered"
            )
            result["findings"].append(
                f"{module}: crashed on the --sabotage capability probe instead of "
                f"refusing an arm that cannot exist: {flag_probe['harness_break']}"
            )
            continue
        if not flag_probe["honoured"]:
            record["sabotages_run"] = False
            record["sabotages_unrun_because"] = (
                "the control set does not honour --sabotage; it ignored an arm that "
                "cannot exist. Whether its arms ran inside the clean run is not "
                "something this audit can see"
            )
            continue

        names = list_sabotages(path, clean["output"])
        if names is None:
            record["sabotages_run"] = False
            record["sabotages_unrun_because"] = (
                "the control set honours --sabotage but will not list its arms"
            )
            result["findings"].append(
                f"{module}: has sabotage arms and no --list-sabotages, so none of them ran"
            )
            continue

        record["sabotages_run"] = True
        for name in names:
            arm = run_arm([sys.executable, path, "--sabotage", name], f"sabotage {name}")
            record["arms"].append(arm)
            if arm["timed_out"]:
                result["findings"].append(f"{module}: sabotage {name} timed out")
                continue
            complaint = read_sabotage_verdict(arm)
            if complaint:
                result["findings"].append(f"{module}: sabotage {name} {complaint}")

    uncovered = sorted(modules - set(control_sets))
    result["uncovered"] = uncovered
    for module in uncovered:
        if module not in known_uncovered:
            result["findings"].append(
                f"{module}: a module in {root} with no control set, and not in the baseline"
            )
    for module in sorted(known_uncovered):
        if module in control_sets:
            result["findings"].append(
                f"{module}: has a control set now — take it out of KNOWN_UNCOVERED"
            )
        elif module not in modules:
            result["findings"].append(
                f"{module}: in KNOWN_UNCOVERED and not in {root} — take it out"
            )
    return result


def report(result, stream=None):
    """Print which control sets ran, which arms ran, and every finding.

    Naming the sets is not decoration. This audit's own failure mode is reporting
    "all green" after running nothing, and the only thing that separates the two is
    this list.
    """
    print(f"control sets under {result['root']}", file=stream)
    if not result["control_sets"]:
        print("  (none)", file=stream)
    for record in result["control_sets"]:
        if record.get("missing"):
            print(f"  MISSING  {record['module']}  {record['control_set']}", file=stream)
            continue
        for arm in record["arms"]:
            status = "TIMEOUT" if arm["timed_out"] else f"exit {arm['exit_code']}"
            verdict = arm.get("verdict")
            read = f"  {verdict} by {arm['verdict_read_from']}" if verdict else ""
            print(
                f"  ran      {record['module']}  {arm['label']}  {status}"
                f"  {arm['seconds']}s{read}",
                file=stream,
            )
        if not record.get("sabotages_run"):
            print(
                f"  UNRUN    {record['module']}  sabotage arms not run:"
                f" {record.get('sabotages_unrun_because')}",
                file=stream,
            )

    if result.get("unattributed_control_sets"):
        print(
            "control sets that guard an unnamed module: "
            + ", ".join(result["unattributed_control_sets"]),
            file=stream,
        )

    if result["uncovered"]:
        print(
            "modules with no control set: " + ", ".join(result["uncovered"]),
            file=stream,
        )

    if result["findings"]:
        print(f"\n{len(result['findings'])} FINDING(S)", file=stream)
        for finding in result["findings"]:
            print(f"  - {finding}", file=stream)
    else:
        ran = sum(len(r["arms"]) for r in result["control_sets"])
        print(
            f"\nGREEN: {ran} arm(s) across {len(result['control_sets'])} control set(s)",
            file=stream,
        )


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument(
        "--no-sabotage-arms",
        action="store_true",
        help="run only the clean arm of each control set; the report says so per set",
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--skip-own-control-set",
        action="store_true",
        help="audit without first proving this script can report a defect",
    )
    args = parser.parse_args(argv[1:])

    # Run the control before believing the tree is clean (213th and 230th passes). A
    # nested call — this script's own control set drives `main` — skips it, or the two
    # would call each other until the box gave out.
    nested = bool(os.environ.get(NESTING_GUARD_VARIABLE))
    if args.skip_own_control_set or nested:
        why = "asked not to" if args.skip_own_control_set else "already inside one"
        print(f"own control set NOT run: {why}")
    elif not run_own_control_set():
        print("\nthe audit's own control set is not sound; nothing was audited",
              file=sys.stderr)
        return 1

    missing_toolchain = ensure_go_toolchain_on_path()
    if missing_toolchain:
        print(missing_toolchain, file=sys.stderr)
        return 2

    root = os.path.expanduser(args.root)
    if not os.path.isdir(root):
        # Not a finding — a finding is something the audit learned. This is the audit
        # being unable to run, and it gets its own exit status so a caller cannot read
        # it as "nothing wrong here".
        print(f"instrument root {root} does not exist", file=sys.stderr)
        return 2

    result = audit(root, sabotage_arms=not args.no_sabotage_arms)
    if args.json:
        # The full arm output is kept in memory so the flag-honoured comparison can
        # read it; it is megabytes of suite chatter and does not belong in the result.
        for record in result["control_sets"]:
            for arm in record["arms"]:
                arm.pop("output", None)
        json.dump(result, sys.stdout, indent=2)
        print()
    else:
        report(result)
    return 1 if result["findings"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
