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

## ⛔ The exit code does not carry the verdict, and it differs per control set

Measured 2026-08-22 over the four control sets on this box, and it is the reason this
script is longer than a loop over `python3 <selftest>`:

    control set                          clean  sabotage-caught  nonsense arm
    ~/.nightly-348-buildtags/selftest.py   0          0              1
    reach_control_selftest.py              0          0              2
    collect_reach_claims_selftest.py       0          1              1
    unbuilt_test_scope_selftest.py         0     (arms are internal) 0

**Two of the four exit 0 when a sabotage is caught**, so a runner that reads only the
exit code cannot tell a caught sabotage from a hole in the case list — it would call
both green. `reach_control_selftest.py` carries a sabotage arm named
`read-only-the-exit-code` warning against exactly this, so the mistake is a known one.
This script therefore reads a sabotage verdict as **caught** when the arm exits
non-zero *or* prints a `caught by N row(s)/case(s)` line with N of one or more, records
per arm which of the two said so, and calls the verdict UNREADABLE — a finding, never a
pass — when neither does.

**Two of the four also ignore an unknown flag** and print their ordinary green report,
so `--list-sabotages` against them yields their whole report, and an unguarded reader
parses its prose into sabotage names. Before trusting any name list, this script probes
with `--sabotage __no_such_arm__`: a control set that honours the protocol refuses it,
and one that comes back green does not implement `--sabotage` at all.

Making the four agree on one protocol would be better than reading four dialects. That
is a change to other passes' instruments and is filed as its own card, not done here.

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

Pinned by `scripts/nightly-shared-control-set-audit-selftest.py`: 19 cases and 7
sabotage arms, all caught, measured 2026-08-22.
"""

import argparse
import json
import os
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

# A control set is allowed this long for its clean arm and for each sabotage arm. The
# slowest arm on this box takes about three seconds; the cap is here so a control set
# that wedges fails the audit instead of holding the scheduler slot until the job's own
# wall-clock cap kills the whole run and loses every result collected so far.
ARM_TIMEOUT_SECONDS = 600


def module_stem(filename):
    """The importable name of a python file, or None if it is not one we audit.

    Skips the backup copies passes leave behind (`citation_screen.py.before-315`),
    which are not modules and whose control sets, if any, guard a dead version.
    """
    if not filename.endswith(".py"):
        return None
    return filename[: -len(".py")]


def control_set_exists(path):
    """Is this control set on disk?

    Its own function so the audit's control set can take it away and show that a
    registered path pointing at nothing then reads as a pass.
    """
    return os.path.exists(path)


def discover(root):
    """Split the root's python files into control sets and the modules they guard."""
    control_sets = {}
    modules = set()
    for filename in sorted(os.listdir(root)):
        stem = module_stem(filename)
        if stem is None:
            continue
        if stem.endswith("_selftest"):
            control_sets[stem[: -len("_selftest")]] = os.path.join(root, filename)
        else:
            modules.add(stem)
    return control_sets, modules


CAUGHT_BY_MARKER = "caught by "


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

# `main` runs this script's own control set before auditing anything, and that control
# set drives this script. The env var breaks the recursion the same way
# `find_controls.py --run` breaks its own.
NESTING_GUARD_VARIABLE = "NIGHTLY_CONTROL_SET_AUDIT_RUNNING"

OWN_CONTROL_SET = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "nightly-shared-control-set-audit-selftest.py",
)


def run_own_control_set(stream=sys.stdout):
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


def honours_sabotage_flag(path):
    """Does this control set implement `--sabotage`, or does it ignore unknown flags?

    Two of the four control sets on this box ignore an argument they do not recognise
    and print their ordinary green report. Asking one of those for `--list-sabotages`
    returns its whole report, and a reader that splits it into words gets sabotage arms
    named `CAUGHT`, `GREEN` and `9/9`. So capability is probed, never assumed: a
    control set that honours the protocol must refuse an arm that cannot exist.
    """
    arm = run_arm([sys.executable, path, "--sabotage", NONSENSE_SABOTAGE], "probe")
    if arm["timed_out"]:
        return False
    # Either channel is enough, because the two conforming dialects use different ones:
    # a non-zero exit, or a line saying the name is not one of its arms.
    return arm["exit_code"] != 0 or "unknown sabotage" in arm["output_tail"].lower()


def list_sabotages(path, clean_output):
    """The sabotage arms this control set will name, or None if it will not name any.

    None and the empty list are different answers and the report keeps them apart:
    None means the control set cannot be asked, the empty list means it was asked and
    has none. Only called once `honours_sabotage_flag` has said `--sabotage` is real.

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


def audit(root, sabotage_arms=True, external_control_sets=None, known_uncovered=None):
    """Run every control set guarding a module in `root` and return the result.

    The two baselines are parameters rather than reads of the module constants so that
    this function can be driven over a fixture directory. A control set that can only
    be pointed at the one directory it audits cannot be given cases, and an audit with
    no cases is the thing this whole file exists to argue against.
    """
    if external_control_sets is None:
        external_control_sets = EXTERNAL_CONTROL_SETS
    if known_uncovered is None:
        known_uncovered = KNOWN_UNCOVERED
    result = {
        "root": root,
        "control_sets": [],
        "uncovered": [],
        "findings": [],
    }
    control_sets, modules = discover(root)

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

        clean = run_arm([sys.executable, path], "clean")
        record["arms"].append(clean)
        if not clean["ok"]:
            how = "timed out" if clean["timed_out"] else f"exit {clean['exit_code']}"
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

        if not honours_sabotage_flag(path):
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


def report(result, stream=sys.stdout):
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
