#!/bin/bash
# Suffix cuts at trunk. Both documented scans require `[:`; a suffix cut is `[n:]`.
for d in ~/repos/*/; do
  n=$(basename "$d")
  case "$n" in *-wt-*|claude-squad|happy) continue;; esac
  [ -d "$d/.git" ] || continue
  trunk=$(git -C "$d" rev-parse --verify -q main >/dev/null && echo main || \
          (git -C "$d" rev-parse --verify -q master >/dev/null && echo master))
  [ -n "$trunk" ] || continue
  git -C "$d" grep -nE '\[len\([a-zA-Z_][a-zA-Z0-9_.]*\)\s*-\s*[0-9a-zA-Z_]+\s*:\]' "$trunk" -- '*.go' \
    2>/dev/null | grep -v '_test.go' | sed "s|^|$n |"
done
