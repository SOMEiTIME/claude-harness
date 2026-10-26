#!/usr/bin/env bash
# Install the guardrails from main on GitHub, never from the local clone:
#   install-from-github.sh            install or update
#   install-from-github.sh --dry-run  show what would change, write nothing
# Claude can write to the local clone and move its branches; main on GitHub only
# changes when the user merges a PR. Run the copy install.sh puts in
# ~/.claude/hooks/claude-harness/, where Claude's sandbox can't write.
set -euo pipefail

repo="https://github.com/SOMEiTIME/claude-harness.git"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-harness-main.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

git clone --quiet --depth 1 --branch main "$repo" "$tmp/harness"
echo "claude-harness main at $(git -C "$tmp/harness" log -1 --format='%h %s')"
"$tmp/harness/install.sh" "$@"
