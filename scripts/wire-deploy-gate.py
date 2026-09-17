#!/usr/bin/env python3
"""Put the two deploy-gate calls into a repo's deploy.sh: `check` right after the
script's `set -e…` line, `record` as its last act. Idempotent. Prints what it did.

    wire-deploy-gate.py <path to deploy.sh> [--gate '<command>']

It refuses a script it cannot place the calls in with confidence (no `set -e`
line, or an `exec` that replaces the shell before the end) and says why, so a
person wires that one by hand instead of this guessing.
"""
import re, sys

path = sys.argv[1]
gate = '"$HOME/bin/deploy-gate"'
if "--gate" in sys.argv:
    gate = sys.argv[sys.argv.index("--gate") + 1]

text = open(path).read()
if "deploy-gate" in text:
    print(f"already wired: {path}")
    raise SystemExit(0)

lines = text.split("\n")
set_e = next((i for i, l in enumerate(lines) if re.match(r"^\s*set -[a-z]*e", l)), None)
if set_e is None:
    raise SystemExit(f"REFUSED {path}: no `set -e` line; without it a failed check would not stop the deploy")
if any(re.match(r"^\s*exec\s", l) for l in lines):
    raise SystemExit(f"REFUSED {path}: it uses `exec`, so the last line may never run; wire it by hand")

check = [
    "",
    "# One shared gate decides whether this tree may be deployed (main clone, default",
    "# branch, clean, pushed, not behind, and the same for every tree the build reads).",
    "# It lives in healthcheck/scripts/deploy-gate.sh. Do not inline or copy it.",
    f'( cd "$(dirname "$0")" && {gate} check )',
]
record = [
    "",
    "# Last act: write this deploy to repo-store's ledger, so the next agent sees what is live.",
    f'( cd "$(dirname "$0")" && {gate} record )',
]

body = lines[: set_e + 1] + check + lines[set_e + 1 :]
while body and body[-1].strip() == "":
    body.pop()
# A trailing `exit 0` would skip the record; put the record before it.
if body and re.match(r"^\s*exit(\s+0)?\s*$", body[-1]):
    body = body[:-1] + record + ["", body[-1]]
else:
    body = body + record
open(path, "w").write("\n".join(body) + "\n")
print(f"wired: {path}")
