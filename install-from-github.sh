#!/usr/bin/env bash
# Install the guardrails from main on GitHub, never from the local clone:
#   install-from-github.sh            install or update
#   install-from-github.sh --dry-run  show what would change, write nothing
# Claude can write to the local clone (it's under ~/Documents/GitHub) and can move
# its local branches, so a check inside install.sh proves nothing. main on GitHub
# only changes when the user merges a PR, so that's what gets installed.
# install.sh copies this script into ~/.claude/hooks/claude-harness/, where
# Claude's sandbox can't write; run that copy.
set -euo pipefail

repo="https://github.com/SOMEiTIME/claude-harness.git"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-harness-main.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

git clone --quiet --depth 1 --branch main "$repo" "$tmp/harness"
echo "claude-harness main at $(git -C "$tmp/harness" log -1 --format='%h %s')"
"$tmp/harness/install.sh" "$@"
