#!/usr/bin/env bash
# Stop hook. When the branch has work on it (uncommitted changes, or commits not
# on the default branch) that changed since the last pass, runs the repo's test
# command (from detect-verify.sh) under sandbox-exec with verify.sb, and on
# failure exits 2 with the tail of its output so Claude keeps fixing.
# - Fails closed on the repo: blocks if there's no test command, if
#   .claude/verify.sh changed (Claude mustn't write its own gate), or if the
#   test command can't be sandboxed.
# - Fails open on its own problems (unparseable input, missing detect-verify.sh).
# - One forced retry per turn: with stop_hook_active set, it lets Claude stop.
# - The test command is killed after VERIFY_TIMEOUT seconds (default 540, under
#   the 600s hook timeout in settings.json); a timeout counts as a failure.
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

# The test command runs code Claude can edit, and hooks run outside Claude's
# sandbox, so verify gets its own (verify.sb). No sandbox, no verify.
profile="$hook_dir/verify.sb"
if [ ! -f "$profile" ] || ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  echo "Can't sandbox the test command (sandbox-exec or $profile unavailable), so it didn't run. Tell the user." >&2
  exit 2
fi
tmp_dir="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
git_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
# The sandbox can't write yarn's normal cache, so point yarn at the sandbox's.
export YARN_CACHE_FOLDER="$HOME/.cache/yarn-sandbox" CLAUDE_HARNESS_VERIFY_SANDBOXED=1

# Run verify in its own process group so a timeout kills everything it started.
log="$(mktemp "$tmp_dir/claude-verify.XXXXXX")"
trap 'rm -f "$log"' EXIT
timeout_secs="${VERIFY_TIMEOUT:-540}"
set -m
sandbox-exec -f "$profile" -D REPO="$(pwd -P)" -D GIT_DIR="$git_dir" -D TMP="$tmp_dir" \
  -D HOME="$(cd "$HOME" && pwd -P)" bash -c "$cmd" >"$log" 2>&1 </dev/null &
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
  echo "\`$cmd\` $summary. The work isn't done until it passes; fix it, or tell the user why it can't pass."
  echo "It ran in the verify sandbox (no network; writes only to the repo and temp). If the sandbox caused the failure, tell the user rather than changing tests. Last 40 lines:"
  tail -n 40 "$log"
} >&2
exit 2
