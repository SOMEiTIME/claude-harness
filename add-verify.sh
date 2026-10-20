#!/usr/bin/env bash
# Give a repo its test command: add-verify.sh <repo-path>
# Copies verify/<repo-name>.sh to <repo>/.claude/verify.sh unless the repo
# already has one. <repo-name> comes from the origin URL, so worktrees work.
# Commit the result in the repo on a branch; the Stop hook (installed by
# install.sh) runs it at the end of each turn with work on the branch.
set -euo pipefail

harness="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${1:?usage: add-verify.sh <repo-path>}" && git rev-parse --show-toplevel)"
name="$(basename "$(git -C "$repo" remote get-url origin 2>/dev/null || echo "$repo")" .git)"
verify="$repo/.claude/verify.sh"

if [ -f "$verify" ]; then
  echo "$verify already exists; left it alone."
elif [ -f "$harness/verify/$name.sh" ]; then
  mkdir -p "$repo/.claude"
  cp "$harness/verify/$name.sh" "$verify"
  chmod +x "$verify"
  echo "Added $verify (from verify/$name.sh)."
else
  echo "No verify/$name.sh in the harness. Write one there first (tests, build; exit non-zero on failure)." >&2
  exit 1
fi
