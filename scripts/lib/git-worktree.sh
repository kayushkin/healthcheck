#!/usr/bin/env bash
#
# git-worktree.sh — the one answer to "is this directory under ~/repos a second
# checkout of a repository the caller already walks?"
#
# Extracted from repo-build-audit.sh on 2026-08-31, working card
# `0c618352-7b2a-4ccb-823b-18dbb396fa34`. It lived as a private function in that
# script while `fleet-suffix-cut-scan.sh`, two paragraphs away in the same
# directory, answered the same question from the directory's NAME. Two answers to
# one question is the thing that goes wrong quietly: the name test is exact only
# for as long as every worker keeps spelling worktrees `-wt-`, and nothing makes
# them. Sourced, not copied, so there is one definition to keep true.
#
# Source it as:
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/git-worktree.sh"

# is_linked_worktree <dir> — is this directory a second checkout of a repository
# the sweep already walks, rather than a repository of its own?
#
# `git worktree add` is the workflow this box's own todos prescribe ("work from a
# worktree off origin/main"), and workers make those worktrees as siblings under
# ~/repos. A linked worktree answers `rev-parse --git-dir` exactly like a real
# repository, so every loop below counted one as an extra repo: the Go and ELF
# passes built and scanned the same tree twice, and the smoke pass did worse. A
# worktree ships its parent's committed smoke, so the derived port registry saw
# two claims on one number and check_port_collisions aborted the WHOLE sweep
# before a single smoke booted.
#
# That is not a hypothetical. On 2026-08-01 a worker left
# ~/repos/llm-bridge-server-workdir behind; the 03:30 run died in one second, all
# 61 smokes went unrun, and smoke-report.json kept the previous night's verdict —
# so the guard read green for another day while measuring nothing. The guard's
# own recommended workflow switched the guard off.
#
# The test is git's own and never looks at the directory's name: in a linked
# worktree the per-worktree git dir (<repo>/.git/worktrees/<name>) differs from
# the repository's common dir; in a main checkout the two are the same path.
is_linked_worktree() {
  local dir="$1" gitdir common
  gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$gitdir" != "$common" ]
}
