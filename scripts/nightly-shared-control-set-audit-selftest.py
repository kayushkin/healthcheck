#!/usr/bin/env python3
"""Control set for `nightly-shared-control-set-audit.py`.

The audit's whole job is to notice that an instrument cannot say "no". It is therefore
the one script on this box that most obviously has to be shown saying "no" itself, and
the 101st pass's rule applies to it before anything else: **prove your instrument can
say "yes" before you trust it saying "no"**.

Each case builds a throwaway instrument directory under a temp path — fake modules and
fake control sets, each a few lines of python whose exit code and output are exactly
what the case is about — and drives `audit()` over it. Nothing here reads or runs the
real `~/.nightly-shared`, so a case cannot pass or fail because of what some other pass
did to that directory tonight.

    python3 nightly-shared-control-set-audit-selftest.py                  # CLEAN
    python3 nightly-shared-control-set-audit-selftest.py --list-sabotages
    python3 nightly-shared-control-set-audit-selftest.py --sabotage <name>

A sabotage breaks one of the audit's predicates and **must redden at least one case**.
A sabotage nothing catches is a hole in the case list, not a robust audit, and this
script says so and exits non-zero when it happens.

⚠️ **This control set exits 0 on a CAUGHT sabotage** and reports the catch in a
`caught by N case(s)` line, matching `reach_control_selftest.py` and the build-tag
control set. It exits non-zero only when a sabotage changed nothing, which is the
control being broken rather than the instrument being caught. The four control sets on
this box do not agree on that convention — see the audit's own docstring for the
measured table — so read the line, not the status.
"""

import argparse
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

# The script's name has hyphens in it, matching the other guards in this directory, so
# it cannot be imported by name. Load it by path instead.
_SPEC = importlib.util.spec_from_file_location(
    "nightly_shared_control_set_audit",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "nightly-shared-control-set-audit.py"),
)
audit_module = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(audit_module)


# ---------------------------------------------------------------------------
# Fixture control sets. Each is a whole python program, written into the fixture
# directory, and each one models a dialect measured on the real box.
# ---------------------------------------------------------------------------

# The conforming shape: refuses an arm it does not have, lists its arms, and exits
# non-zero when a sabotage is caught.
CONFORMING = '''\
import sys
if len(sys.argv) > 1 and sys.argv[1] not in ("--sabotage", "--list-sabotages"):
    print("unrecognised argument %r" % sys.argv[1]); sys.exit(2)
ARMS = ["breaks-the-predicate"]
if "--list-sabotages" in sys.argv:
    print("\\n".join(ARMS)); sys.exit(0)
if len(sys.argv) > 2 and sys.argv[1] == "--sabotage":
    if sys.argv[2] not in ARMS:
        print("unknown sabotage %r" % sys.argv[2]); sys.exit(2)
    print("SABOTAGE %s: 1/2 rows as expected" % sys.argv[2]); sys.exit(1)
print("CLEAN: 2/2 rows as expected"); sys.exit(0)
'''

# The exit-zero dialect: a caught sabotage exits 0 and says so in a `caught by` line.
# This is `reach_control_selftest.py` and `~/.nightly-348-buildtags/selftest.py`, and
# an audit that reads only the exit code calls every arm here a hole.
CAUGHT_BY_LINE = '''\
import sys
if len(sys.argv) > 1 and sys.argv[1] not in ("--sabotage", "--list-sabotages"):
    print("unrecognised argument %r" % sys.argv[1]); sys.exit(2)
ARMS = ["breaks-the-predicate"]
if "--list-sabotages" in sys.argv:
    print("\\n".join(ARMS)); sys.exit(0)
if len(sys.argv) > 2 and sys.argv[1] == "--sabotage":
    if sys.argv[2] not in ARMS:
        print("unknown sabotage %r" % sys.argv[2]); sys.exit(2)
    print("SABOTAGE %s: 1/2 rows as expected" % sys.argv[2])
    print("  caught by 3 row(s): ['a', 'b', 'c']"); sys.exit(0)
print("CLEAN: 2/2 rows as expected"); sys.exit(0)
'''

# The hole: the sabotage changes nothing and the control set notices nothing. Exit 0,
# no caught-by line. This is the state the audit exists to find.
SABOTAGE_UNCAUGHT = '''\
import sys
if len(sys.argv) > 1 and sys.argv[1] not in ("--sabotage", "--list-sabotages"):
    print("unrecognised argument %r" % sys.argv[1]); sys.exit(2)
ARMS = ["breaks-the-predicate"]
if "--list-sabotages" in sys.argv:
    print("\\n".join(ARMS)); sys.exit(0)
if len(sys.argv) > 2 and sys.argv[1] == "--sabotage":
    if sys.argv[2] not in ARMS:
        print("unknown sabotage %r" % sys.argv[2]); sys.exit(2)
    print("SABOTAGE %s: 2/2 rows as expected" % sys.argv[2]); sys.exit(0)
print("CLEAN: 2/2 rows as expected"); sys.exit(0)
'''

# The half-honest hole: it says it caught something and names no rows.
SABOTAGE_CAUGHT_NOTHING = '''\
import sys
if len(sys.argv) > 1 and sys.argv[1] not in ("--sabotage", "--list-sabotages"):
    print("unrecognised argument %r" % sys.argv[1]); sys.exit(2)
ARMS = ["breaks-the-predicate"]
if "--list-sabotages" in sys.argv:
    print("\\n".join(ARMS)); sys.exit(0)
if len(sys.argv) > 2 and sys.argv[1] == "--sabotage":
    if sys.argv[2] not in ARMS:
        print("unknown sabotage %r" % sys.argv[2]); sys.exit(2)
    print("  caught by 0 row(s): []"); sys.exit(0)
print("CLEAN: 2/2 rows as expected"); sys.exit(0)
'''

# A red clean arm. Whatever its sabotages then do cannot be read.
CLEAN_ARM_RED = '''\
import sys
print("  \\u26d4 CLEAN RUN IS RED"); sys.exit(1)
'''

# Ignores every flag it does not know and prints its ordinary report. This is
# `unbuilt_test_scope_selftest.py`, and it is the trap: ask it to list its sabotages
# and it hands back a suite report whose words look like arm names.
IGNORES_FLAGS = '''\
import sys
print("   CAUGHT   the predicate cannot read a tag")
print("9/9 sabotages caught"); sys.exit(0)
'''

# Honours --sabotage and ignores --list-sabotages, so its arms exist and cannot be
# enumerated. This is `~/.nightly-348-buildtags/selftest.py` as it stood before
# 2026-08-22, and it is why the audit's first run had a finding.
#
# ⚠️ This one must keep FALLING THROUGH to its ordinary report for a flag it does not
# know — that is the whole shape it models, and `trust-the-arm-list` is the arm that
# reads that report as an arm list. Adding a refusal here (as card `3165bed1` did to
# the four fixtures above) makes `--list-sabotages` exit non-zero, `list_sabotages`
# return None on the status alone, and `trust-the-arm-list` catch nothing. Measured:
# it went straight to CONTROL BROKEN.
NO_LIST_FLAG = '''\
import sys
ARMS = {"breaks-the-predicate": 1}
if len(sys.argv) > 2 and sys.argv[1] == "--sabotage":
    if sys.argv[2] not in ARMS:
        print("unknown sabotage %r" % sys.argv[2]); sys.exit(2)
    print("  caught by 1 row(s): ['a']"); sys.exit(0)
print("CLEAN: 2/2 rows as expected"); sys.exit(0)
'''

# Refuses in prose and exits 0 anyway. Every caller that reads the status still sees a
# green run, so the complaint buys nothing — the refusal has to be in the exit code.
COMPLAINS_ABOUT_THE_FLAG_AND_EXITS_ZERO = '''\
import sys
ARMS = ["breaks-the-predicate"]
if len(sys.argv) > 1 and sys.argv[1] not in ("--sabotage", "--list-sabotages"):
    print("unrecognised argument %r" % sys.argv[1]); sys.exit(0)
if "--list-sabotages" in sys.argv:
    print("\\n".join(ARMS)); sys.exit(0)
if len(sys.argv) > 2 and sys.argv[1] == "--sabotage":
    if sys.argv[2] not in ARMS:
        print("unknown sabotage %r" % sys.argv[2]); sys.exit(2)
    print("SABOTAGE %s: 1/2 rows as expected" % sys.argv[2]); sys.exit(1)
print("CLEAN: 2/2 rows as expected"); sys.exit(0)
'''

MODULE_SOURCE = "# a shared instrument\n"


def build_fixture(directory, modules=(), control_sets=(), extra_files=()):
    """Write one fixture instrument directory and return its path.

    `control_sets` is (module_name, source); the file is named by the convention the
    audit discovers on, so a case cannot pass by the audit being told where to look.
    """
    os.makedirs(directory, exist_ok=True)
    for name in modules:
        with open(os.path.join(directory, name + ".py"), "w") as handle:
            handle.write(MODULE_SOURCE)
    for name, source in control_sets:
        with open(os.path.join(directory, name + "_selftest.py"), "w") as handle:
            handle.write(source)
    for name, source in extra_files:
        with open(os.path.join(directory, name), "w") as handle:
            handle.write(source)
    return directory


def findings_matching(result, needle):
    return [f for f in result["findings"] if needle in f]


# ---------------------------------------------------------------------------
# Cases. Each returns (ok, detail).
# ---------------------------------------------------------------------------

def case_conforming_set_is_green(work):
    root = build_fixture(os.path.join(work, "green"),
                         modules=["alpha"], control_sets=[("alpha", CONFORMING)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return not result["findings"], f"findings={result['findings']}"


def case_conforming_set_runs_its_arms(work):
    root = build_fixture(os.path.join(work, "arms"),
                         modules=["alpha"], control_sets=[("alpha", CONFORMING)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    labels = [a["label"] for a in result["control_sets"][0]["arms"]]
    return labels == ["clean", "sabotage breaks-the-predicate"], f"labels={labels}"


def case_exit_zero_catch_is_still_a_catch(work):
    """The dialect half the box speaks. An audit reading only exit codes fails here."""
    root = build_fixture(os.path.join(work, "exitzero"),
                         modules=["alpha"], control_sets=[("alpha", CAUGHT_BY_LINE)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    arm = result["control_sets"][0]["arms"][1]
    return (not result["findings"] and arm.get("verdict") == "caught"), \
        f"findings={result['findings']} verdict={arm.get('verdict')}"


def case_uncaught_sabotage_is_a_finding(work):
    root = build_fixture(os.path.join(work, "uncaught"),
                         modules=["alpha"], control_sets=[("alpha", SABOTAGE_UNCAUGHT)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return bool(findings_matching(result, "verdict is unreadable")), \
        f"findings={result['findings']}"


def case_catching_no_rows_is_a_finding(work):
    root = build_fixture(os.path.join(work, "zerorows"),
                         modules=["alpha"],
                         control_sets=[("alpha", SABOTAGE_CAUGHT_NOTHING)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return bool(findings_matching(result, "reddened no rows")), \
        f"findings={result['findings']}"


def case_red_clean_arm_is_a_finding(work):
    root = build_fixture(os.path.join(work, "redclean"),
                         modules=["alpha"], control_sets=[("alpha", CLEAN_ARM_RED)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return bool(findings_matching(result, "clean arm exit 1")), \
        f"findings={result['findings']}"


def case_red_clean_arm_does_not_run_sabotages(work):
    """A red produced by a sabotage is unreadable against a red that was already there."""
    root = build_fixture(os.path.join(work, "redclean2"),
                         modules=["alpha"], control_sets=[("alpha", CLEAN_ARM_RED)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    record = result["control_sets"][0]
    return (record["sabotages_run"] is False
            and "clean arm is red" in record["sabotages_unrun_because"]), \
        f"record={record.get('sabotages_unrun_because')}"


def case_flag_ignoring_set_yields_no_invented_arms(work):
    """The trap: its report must not be parsed into sabotage arms called `CAUGHT`."""
    root = build_fixture(os.path.join(work, "ignores"),
                         modules=["alpha"], control_sets=[("alpha", IGNORES_FLAGS)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    record = result["control_sets"][0]
    labels = [a["label"] for a in record["arms"]]
    return (labels == ["clean"] and record["sabotages_run"] is False
            and "does not honour --sabotage" in record["sabotages_unrun_because"]), \
        f"labels={labels} because={record.get('sabotages_unrun_because')}"


def case_flag_ignoring_set_is_a_finding(work):
    """Ignoring an unrecognised flag is reported, not merely worked around.

    The audit already copes with the old dialect — it probes capability instead of
    assuming it — and coping quietly is how the dialect survived. A control set that
    cannot be shown to have read a flag is a finding.
    """
    root = build_fixture(os.path.join(work, "ignoresfinding"),
                         modules=["alpha"], control_sets=[("alpha", IGNORES_FLAGS)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return bool(findings_matching(result, "ignores an unrecognised flag")), \
        f"findings={result['findings']}"


def case_a_complaint_without_a_status_is_still_a_finding(work):
    """Printing "unrecognised argument" and exiting 0 leaves every caller green."""
    root = build_fixture(
        os.path.join(work, "complains"), modules=["alpha"],
        control_sets=[("alpha", COMPLAINS_ABOUT_THE_FLAG_AND_EXITS_ZERO)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return bool(findings_matching(result, "ignores an unrecognised flag")), \
        f"findings={result['findings']}"


def case_a_refusing_set_records_that_it_refused(work):
    """The conforming answer is recorded per control set, not only inferred from silence."""
    root = build_fixture(os.path.join(work, "refuses"),
                         modules=["alpha"], control_sets=[("alpha", CONFORMING)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    record = result["control_sets"][0]
    return record.get("refuses_unrecognised_flag") is True, \
        f"record={record.get('refuses_unrecognised_flag')} findings={result['findings']}"


def case_arms_that_cannot_be_listed_are_a_finding(work):
    root = build_fixture(os.path.join(work, "nolist"),
                         modules=["alpha"], control_sets=[("alpha", NO_LIST_FLAG)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return bool(findings_matching(result, "no --list-sabotages")), \
        f"findings={result['findings']}"


def case_missing_registered_control_set_is_a_finding(work):
    root = build_fixture(os.path.join(work, "missing"), modules=["alpha"])
    result = audit_module.audit(
        root,
        external_control_sets={"alpha": os.path.join(work, "no_such_control_set.py")},
        known_uncovered=set(),
    )
    return bool(findings_matching(result, "registered and not on disk")), \
        f"findings={result['findings']}"


def case_registry_naming_an_absent_module_is_a_finding(work):
    root = build_fixture(os.path.join(work, "ghost"), modules=["alpha"])
    result = audit_module.audit(
        root,
        external_control_sets={"beta": os.path.join(work, "whatever.py")},
        known_uncovered={"alpha"},
    )
    return bool(findings_matching(result, "which is not in")), \
        f"findings={result['findings']}"


def case_new_uncovered_module_is_a_finding(work):
    root = build_fixture(os.path.join(work, "newmodule"), modules=["alpha", "beta"],
                         control_sets=[("alpha", CONFORMING)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return bool(findings_matching(result, "beta: a module in")), \
        f"findings={result['findings']}"


def case_baseline_entry_that_gained_a_control_is_a_finding(work):
    root = build_fixture(os.path.join(work, "gained"), modules=["alpha"],
                         control_sets=[("alpha", CONFORMING)])
    result = audit_module.audit(root, external_control_sets={},
                                known_uncovered={"alpha"})
    return bool(findings_matching(result, "take it out of KNOWN_UNCOVERED")), \
        f"findings={result['findings']}"


def case_baseline_entry_that_left_the_directory_is_a_finding(work):
    root = build_fixture(os.path.join(work, "left"), modules=["alpha"],
                         control_sets=[("alpha", CONFORMING)])
    result = audit_module.audit(root, external_control_sets={},
                                known_uncovered={"departed"})
    return bool(findings_matching(result, "departed: in KNOWN_UNCOVERED")), \
        f"findings={result['findings']}"


def case_uncovered_module_in_the_baseline_is_not_a_finding(work):
    """The baseline has to buy silence for the gaps it names, or nobody keeps it."""
    root = build_fixture(os.path.join(work, "baselined"), modules=["alpha", "beta"],
                         control_sets=[("alpha", CONFORMING)])
    result = audit_module.audit(root, external_control_sets={},
                                known_uncovered={"beta"})
    return (not result["findings"] and result["uncovered"] == ["beta"]), \
        f"findings={result['findings']} uncovered={result['uncovered']}"


def case_backup_copies_are_not_modules(work):
    """`citation_screen.py.before-315` is a dead copy, not an uncovered instrument."""
    root = build_fixture(
        os.path.join(work, "backups"), modules=["alpha"],
        control_sets=[("alpha", CONFORMING)],
        extra_files=[("alpha.py.before-300", MODULE_SOURCE),
                     ("README.md", "# not python\n")],
    )
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    return (not result["findings"] and result["uncovered"] == []), \
        f"findings={result['findings']} uncovered={result['uncovered']}"


def case_report_names_every_control_set_it_ran(work):
    """"All green" without saying what ran is the defect one layer up."""
    root = build_fixture(os.path.join(work, "report"), modules=["alpha"],
                         control_sets=[("alpha", CONFORMING)])
    result = audit_module.audit(root, external_control_sets={}, known_uncovered=set())
    import io
    buffer = io.StringIO()
    audit_module.report(result, stream=buffer)
    text = buffer.getvalue()
    return ("alpha" in text and "clean" in text
            and "sabotage breaks-the-predicate" in text), f"report={text!r}"


def run_main_quietly(argv):
    """Drive the audit's own entry point without its report landing in this output.

    The nesting guard is set because this IS the audit's control set: without it, every
    case that drives `main` makes the audit run this whole file again as a subprocess,
    once per sabotage arm.
    """
    import contextlib
    import io
    previous = os.environ.get(audit_module.NESTING_GUARD_VARIABLE)
    os.environ[audit_module.NESTING_GUARD_VARIABLE] = "1"
    sink = io.StringIO()
    try:
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            return audit_module.main(argv)
    finally:
        if previous is None:
            os.environ.pop(audit_module.NESTING_GUARD_VARIABLE, None)
        else:
            os.environ[audit_module.NESTING_GUARD_VARIABLE] = previous


def case_absent_root_exits_two_not_zero(work):
    """An audit that could not run must not read as an audit that found nothing."""
    code = run_main_quietly(["audit", "--root", os.path.join(work, "no_such_directory")])
    return code == 2, f"exit={code}"


def case_absent_go_toolchain_refuses_the_audit(work):
    """Three control sets need `go`. Without it they all go red, and that is not a
    finding about them — it is the audit being unable to run."""
    real_which = audit_module.find_executable
    real_shims = audit_module.MISE_SHIM_DIRECTORY
    audit_module.find_executable = lambda name: None
    audit_module.MISE_SHIM_DIRECTORY = os.path.join(work, "no_such_shim_directory")
    try:
        root = build_fixture(os.path.join(work, "notoolchain"), modules=["alpha"],
                             control_sets=[("alpha", CONFORMING)])
        code = run_main_quietly(["audit", "--root", root])
        return code == 2, f"exit={code}"
    finally:
        audit_module.find_executable = real_which
        audit_module.MISE_SHIM_DIRECTORY = real_shims


def case_shim_directory_supplies_the_toolchain(work):
    """A PATH without `go` is not a refusal if mise's shims can still supply it."""
    real_which = audit_module.find_executable
    real_shims = audit_module.MISE_SHIM_DIRECTORY
    shims = os.path.join(work, "shims")
    os.makedirs(shims, exist_ok=True)
    seen = []

    def which_after_the_shims_are_added(name):
        seen.append(os.environ.get("PATH", ""))
        return shims + "/go" if shims in os.environ.get("PATH", "") else None

    audit_module.find_executable = which_after_the_shims_are_added
    audit_module.MISE_SHIM_DIRECTORY = shims
    try:
        complaint = audit_module.ensure_go_toolchain_on_path()
        return complaint is None and len(seen) == 2, f"complaint={complaint} probes={len(seen)}"
    finally:
        audit_module.find_executable = real_which
        audit_module.MISE_SHIM_DIRECTORY = real_shims


def case_report_streams_are_late_bound(work):
    """A `stream=sys.stdout` default is bound once, when the function is defined.

    Both reporting functions had it, and the effect was that the audit's own
    control-set report stepped over `contextlib.redirect_stdout` and landed in the
    caller's output. Asserted on the signature because reproducing it needs the audit to
    spawn this whole file eight times per case.
    """
    import inspect
    bad = [
        name for name, function in (("run_own_control_set", audit_module.run_own_control_set),
                                    ("report", audit_module.report))
        if inspect.signature(function).parameters["stream"].default is not None
    ]
    return not bad, f"eagerly bound stream default in {bad}"


def case_findings_make_main_exit_one(work):
    root = build_fixture(os.path.join(work, "mainexit"), modules=["alpha", "beta"],
                         control_sets=[("alpha", CONFORMING)])
    code = run_main_quietly(["audit", "--root", root, "--json"])
    return code == 1, f"exit={code}"


CASES = [
    ("a conforming control set is green", case_conforming_set_is_green),
    ("a conforming control set has its arms run", case_conforming_set_runs_its_arms),
    ("an exit-0 catch is still a catch", case_exit_zero_catch_is_still_a_catch),
    ("a sabotage nothing notices is a finding", case_uncaught_sabotage_is_a_finding),
    ("a catch naming no rows is a finding", case_catching_no_rows_is_a_finding),
    ("a red clean arm is a finding", case_red_clean_arm_is_a_finding),
    ("a red clean arm suppresses the sabotages", case_red_clean_arm_does_not_run_sabotages),
    ("a flag-ignoring set yields no invented arms", case_flag_ignoring_set_yields_no_invented_arms),
    ("arms that cannot be listed are a finding", case_arms_that_cannot_be_listed_are_a_finding),
    ("a flag-ignoring set is a finding", case_flag_ignoring_set_is_a_finding),
    ("a complaint without a status is a finding", case_a_complaint_without_a_status_is_still_a_finding),
    ("a refusing set records that it refused", case_a_refusing_set_records_that_it_refused),
    ("a registered control set that is gone is a finding", case_missing_registered_control_set_is_a_finding),
    ("a registry naming an absent module is a finding", case_registry_naming_an_absent_module_is_a_finding),
    ("a new uncovered module is a finding", case_new_uncovered_module_is_a_finding),
    ("a baseline entry that gained a control is a finding", case_baseline_entry_that_gained_a_control_is_a_finding),
    ("a baseline entry that left is a finding", case_baseline_entry_that_left_the_directory_is_a_finding),
    ("a baselined gap is silent", case_uncovered_module_in_the_baseline_is_not_a_finding),
    ("a backup copy is not an instrument", case_backup_copies_are_not_modules),
    ("the report names what it ran", case_report_names_every_control_set_it_ran),
    ("report streams are late bound", case_report_streams_are_late_bound),
    ("an absent root exits 2", case_absent_root_exits_two_not_zero),
    ("an absent go toolchain refuses the audit", case_absent_go_toolchain_refuses_the_audit),
    ("mise's shims supply the toolchain", case_shim_directory_supplies_the_toolchain),
    ("a finding makes main exit 1", case_findings_make_main_exit_one),
]


# ---------------------------------------------------------------------------
# Sabotages. Each breaks one predicate of the audit; at least one case must redden.
# ---------------------------------------------------------------------------

def _sabotage_read_only_the_exit_code():
    """The mistake reach_control names in its own arm list: trust the exit code."""
    audit_module.caught_row_count = lambda output: None


def _sabotage_assume_the_sabotage_flag():
    """Skip the capability probe. A flag-ignoring control set then looks conforming."""
    audit_module.honours_sabotage_flag = lambda path: True


def _sabotage_trust_the_arm_list():
    """Drop the clean-output comparison, so a suite report parses into arm names.

    ⚠️ This has to remove the guard, not feed it a value it cannot match. The first
    authoring did the latter — it called the real `list_sabotages` with an impossible
    `clean_output` — and caught nothing, because that function takes a *second* clean
    run of its own and compares against that too. It read as a passing control while
    leaving the predicate it names fully intact, which is the exact defect this whole
    family of cards is about, produced here by the hand writing the control.
    """
    import subprocess as sabotaged_subprocess

    def unguarded(path, clean_output):
        finished = sabotaged_subprocess.run(
            [sys.executable, path, "--list-sabotages"],
            stdout=sabotaged_subprocess.PIPE,
            stderr=sabotaged_subprocess.DEVNULL,
            timeout=audit_module.ARM_TIMEOUT_SECONDS,
        )
        if finished.returncode != 0:
            return None
        names = []
        for line in finished.stdout.decode("utf-8", "replace").splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            name = stripped.split()[0]
            if name.startswith("-"):
                continue
            names.append(name)
        return names or None

    audit_module.list_sabotages = unguarded


def _sabotage_assume_the_flag_was_read():
    """Assume every control set read the flag it was sent.

    This is the predicate `refuses_an_unrecognised_flag` exists to be. Without it the
    audit copes with a flag-ignoring control set in silence, which is how three of the
    four kept the dialect for as long as they did.
    """
    audit_module.refuses_an_unrecognised_flag = lambda path: True


def _sabotage_a_missing_control_set_is_a_skip():
    """The registry points at nothing and the audit shrugs."""
    audit_module.control_set_exists = lambda path: True


def _sabotage_an_unreadable_verdict_passes():
    """Treat "the arm said nothing" as "the arm caught it"."""
    audit_module.caught_row_count = lambda output: 1


def _sabotage_coverage_is_never_checked():
    """Stop comparing the directory against the baseline in either direction."""
    original = audit_module.audit

    def without_coverage(root, **kwargs):
        result = original(root, **kwargs)
        result["findings"] = [
            f for f in result["findings"]
            if "no control set" not in f and "KNOWN_UNCOVERED" not in f
        ]
        return result

    audit_module.audit = without_coverage


def _sabotage_an_absent_root_is_green():
    """Report exit 0 when the audit could not be carried out at all."""
    original = audit_module.main

    def forgiving(argv):
        code = original(argv)
        return 0 if code == 2 else code

    audit_module.main = forgiving


def _sabotage_a_missing_toolchain_is_someone_elses_problem():
    """Audit anyway with no `go`, and report three red clean arms as three findings."""
    audit_module.ensure_go_toolchain_on_path = lambda: None


SABOTAGES = {
    "a-missing-toolchain-is-someone-elses-problem":
        _sabotage_a_missing_toolchain_is_someone_elses_problem,
    "read-only-the-exit-code": _sabotage_read_only_the_exit_code,
    "assume-the-sabotage-flag": _sabotage_assume_the_sabotage_flag,
    "assume-the-flag-was-read": _sabotage_assume_the_flag_was_read,
    "trust-the-arm-list": _sabotage_trust_the_arm_list,
    "a-missing-control-set-is-a-skip": _sabotage_a_missing_control_set_is_a_skip,
    "an-unreadable-verdict-passes": _sabotage_an_unreadable_verdict_passes,
    "coverage-is-never-checked": _sabotage_coverage_is_never_checked,
    "an-absent-root-is-green": _sabotage_an_absent_root_is_green,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sabotage")
    parser.add_argument("--list-sabotages", action="store_true")
    args = parser.parse_args()

    if args.list_sabotages:
        for name in SABOTAGES:
            print(name)
        return 0

    if args.sabotage:
        if args.sabotage not in SABOTAGES:
            print(f"unknown sabotage {args.sabotage!r}; --list-sabotages prints the set")
            return 2
        SABOTAGES[args.sabotage]()
        print(f"SABOTAGE ACTIVE: {args.sabotage}")

    work = tempfile.mkdtemp(prefix="control-set-audit-selftest-")
    failed = []
    try:
        for label, case in CASES:
            try:
                ok, detail = case(work)
            except Exception as error:  # a case that explodes is a case that failed
                ok, detail = False, f"raised {type(error).__name__}: {error}"
            print(f"  {'ok  ' if ok else 'FAIL'} {label}")
            if not ok:
                print(f"       {detail}")
                failed.append(label)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    total = len(CASES)
    if args.sabotage:
        print(f"SABOTAGE {args.sabotage}: {total - len(failed)}/{total} cases as expected")
        if not failed:
            print(f"  ⛔ CONTROL BROKEN: sabotage {args.sabotage!r} changed nothing")
            return 1
        print(f"  caught by {len(failed)} case(s): {failed}")
        return 0

    print(f"CLEAN: {total - len(failed)}/{total} cases as expected")
    if failed:
        print("  ⛔ CLEAN RUN IS RED")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
