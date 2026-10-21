#!/usr/bin/env bash
# Stop hook. Runs the repo's test command (from detect-verify.sh, usually
# .claude/verify.sh) when Claude finishes a turn and, if it fails, exits 2 with
# the tail of its output so Claude keeps fixing.
# - Fails closed on the repo: work on the branch with no test command blocks,
#   and so does any change to .claude/verify.sh (Claude mustn't write its own gate).
# - Stop fires at the end of every turn, so verify only runs when the branch
#   has work on it (uncommitted changes, or commits not on the default branch)
#   and that work changed since the last passing run.
# - If this stop was already forced by a Stop hook (stop_hook_active), it lets
#   Claude stop: one forced retry per turn, then it's back to the user.
# - The test command is killed after VERIFY_TIMEOUT seconds (default 540, under
#   the 600s hook timeout in settings.json) and the timeout counts as a failure.
# Fails open on itself: any problem with the hook allows the stop.
# Written for bash 3.2, which is what macOS ships.

hook_dir="$(cd "$(dirname "$0")" && pwd)"
input="$(cat)"

if ! active="$(printf '%s' "$input" | "$hook_dir/json-field.sh" stop_hook_active)"; then
  echo "stop-verify.sh: couldn't parse hook input (needs jq, python3 or node); skipping verify" >&2
  exit 0
fi
[ "$active" = true ] && exit 0

cwd="$(printf '%s' "$input" | "$hook_dir/json-field.sh" cwd)"
[ -d "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$repo_root" || exit 0
# Settings' env points yarn at a cache sandboxed commands can write to. Verify
# runs outside the sandbox, so it uses the normal cache: nothing written from
# inside the sandbox gets installed unsandboxed.
unset YARN_CACHE_FOLDER

# Is there any work on this branch? Compare against origin's default branch.
default_ref="$(git symbolic-ref -q --short refs/remotes/origin/HEAD)"
for candidate in origin/main origin/master; do
  [ -n "$default_ref" ] && break
  git rev-parse -q --verify "$candidate" >/dev/null && default_ref="$candidate"
done
dirty="$(git status --porcelain)"
if [ -z "$dirty" ] && [ -n "$default_ref" ] && git merge-base --is-ancestor HEAD "$default_ref"; then
  exit 0
fi

# verify.sh must match the branch's base: edited, added, deleted, untracked or
# ignored all count. With no default branch, the base is HEAD.
base="$(git merge-base HEAD "$default_ref" 2>/dev/null)" || base=HEAD
old_verify="$(git rev-parse -q --verify "$base:.claude/verify.sh")"
new_verify=""
[ -f .claude/verify.sh ] && new_verify="$(git hash-object .claude/verify.sh)"
if [ "$old_verify" != "$new_verify" ]; then
  echo "verify.sh changed in this session; human review required." >&2
  exit 2
fi

[ -x "$hook_dir/detect-verify.sh" ] || exit 0
cmd="$("$hook_dir/detect-verify.sh" "$repo_root")"
# With no default branch, a clean tree is the only sign of no work.
[ -z "$cmd" ] && [ -z "$default_ref" ] && [ -z "$dirty" ] && exit 0
if [ -z "$cmd" ]; then
  echo "No test command for this repo. Add .claude/verify.sh or a supported test entry point." >&2
  exit 2
fi

# Fingerprint of the working tree: HEAD, uncommitted diff, untracked file contents.
fingerprint() {
  {
    git rev-parse HEAD
    git diff HEAD --binary
    git ls-files -o --exclude-standard -z | xargs -0 git hash-object -- 2>/dev/null
  } | git hash-object --stdin
}
stamp="$(git rev-parse --git-path claude-verify-passed)"
[ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(fingerprint)" ] && exit 0

# Run verify in its own process group so a timeout kills everything it started.
log="$(mktemp "${TMPDIR:-/tmp}/claude-verify.XXXXXX")"
trap 'rm -f "$log"' EXIT
timeout_secs="${VERIFY_TIMEOUT:-540}"
set -m
bash -c "$cmd" >"$log" 2>&1 </dev/null &
verify_pid=$!
(sleep "$timeout_secs" && kill -TERM -- -"$verify_pid" 2>/dev/null) &
watchdog_pid=$!
wait "$verify_pid"
status=$?
kill -TERM -- -"$watchdog_pid" 2>/dev/null
set +m

if [ $status -eq 0 ]; then
  fingerprint >"$stamp"
  exit 0
fi

if [ $status -eq 143 ]; then
  summary="timed out after ${timeout_secs}s (a hung test or dev server?)"
else
  summary="failed (exit $status)"
fi
{
  echo "\`$cmd\` $summary. The work isn't done until it passes; fix it, or tell the user why it can't pass. Last 40 lines:"
  tail -n 40 "$log"
} >&2
exit 2
