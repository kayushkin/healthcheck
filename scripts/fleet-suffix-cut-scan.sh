#!/bin/bash
# Suffix cuts at trunk. Both documented scans require `[:`; a suffix cut is `[n:]`.
#
# Linked worktrees are excluded because their parent repository is walked on its own
# path, so scanning both reports every hit twice. The test is git's own — see
# lib/git-worktree.sh. It used to be `case "$n" in *-wt-*)`, a test on the directory's
# NAME, while the sibling guard in this same directory already asked git. Measured
# 2026-08-31 before the change: 35 directories say `-wt-`, git calls the same 35 linked
# worktrees, and neither answer has a member the other lacks — so this is a repair to a
# latent disagreement, not to a live one. The name convention is exact for exactly as
# long as every worker keeps spelling it that way, and nothing makes them.
#
# `claude-squad` and `happy` stay a name test on purpose. They are vendored upstream
# trees, and "we did not write this" is a policy about two specific repositories with no
# structural property to read.
#
# ⚠️ The worktree test is REDUNDANT today and a reader should not take it for the thing
# doing the work. `[ -d "$d/.git" ]` on the next line already refuses every linked
# worktree, because a worktree's `.git` is a FILE. Measured 2026-08-31, three runs over
# the same tree:
#
#     as written                          21 lines
#     is_linked_worktree disarmed         21 lines   <- unchanged
#     that AND the `.git` test disarmed   78 lines   <- 31 worktree directories appear
#
# So no arm aimed at this line alone can come back anything but VACUOUS while the line
# below it stands, and the `-wt-` version it replaced was equally redundant. It is kept
# because the two lines mean different things: one says "not a second checkout", the
# other says "a normal checkout at all", and the first should not be left implied by the
# second.
. "$(dirname "${BASH_SOURCE[0]}")/lib/git-worktree.sh"

for d in ~/repos/*/; do
  n=$(basename "$d")
  case "$n" in claude-squad|happy) continue;; esac
  is_linked_worktree "$d" && continue
  [ -d "$d/.git" ] || continue
  trunk=$(git -C "$d" rev-parse --verify -q main >/dev/null && echo main || \
          (git -C "$d" rev-parse --verify -q master >/dev/null && echo master))
  [ -n "$trunk" ] || continue
  git -C "$d" grep -nE '\[len\([a-zA-Z_][a-zA-Z0-9_.]*\)\s*-\s*[0-9a-zA-Z_]+\s*:\]' "$trunk" -- '*.go' \
    2>/dev/null | grep -v '_test.go' | sed "s|^|$n |"
done
