#!/usr/bin/env bash
# Self-test for stop-verify.sh: test-stop-verify.sh [path/to/stop-verify.sh]
# Runs the hook against scratch repos and checks when it runs verify, when it
# blocks (exit 2), that it caches passes and times out, and that it blocks on
# edits to verify.sh and on work in a repo with no test command, and what the
# verify sandbox (verify.sb) stops. Then checks detect-verify.sh's CMake/ctest
# detection.
# Seatbelt sandboxes can't nest, so inside Claude's sandbox or a sandboxed
# verify run, sandbox-exec is swapped for a pass-through and the sandbox's own
# checks are skipped. Anywhere else they must run.

hook="${1:-$(dirname "$0")/stop-verify.sh}"
hook="$(cd "$(dirname "$hook")" && pwd)/$(basename "$hook")"
detect="$(dirname "$hook")/detect-verify.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-harness-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# new_repo <name>: clone a fresh origin with one empty commit on main, and cd into it.
new_repo() {
  git init -q --bare "$tmp/$1.git"
  git clone -q "$tmp/$1.git" "$tmp/$1" 2>/dev/null
  repo="$tmp/$1"
  cd "$repo" || exit 1
  git checkout -q -b main
  git commit -q --allow-empty -m init
  git push -q origin main 2>/dev/null
  git remote set-head origin main
}

sandbox_shim="$tmp/shim"
mkdir "$sandbox_shim"
if sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  real_sandbox=1
elif [ -n "${SANDBOX_RUNTIME:-}${CLAUDE_HARNESS_VERIFY_SANDBOXED:-}" ]; then
  real_sandbox=""
  printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do case "$1" in -f|-D|-p) shift 2 ;; *) break ;; esac; done\nexec "$@"\n' \
    >"$sandbox_shim/sandbox-exec"
  chmod +x "$sandbox_shim/sandbox-exec"
  echo "note: already in a sandbox; skipping the verify sandbox checks"
else
  echo "FAIL: sandbox-exec doesn't work here, and this isn't a sandboxed run"
  exit 1
fi
PATH="$sandbox_shim:$PATH"

failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# expect <0|2> <description> [stop_hook_active]
expect() {
  local want="$1" description="$2" active="${3:-false}" got
  printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":%s}' "$repo" "$active" |
    "$hook" 2>"$tmp/stderr" >/dev/null
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL (want $want, got $got): $description"
    sed 's/^/    /' "$tmp/stderr"
    failures=$((failures + 1))
  fi
}

# Main repo: verify.sh is committed and never changes; tests swap the stub it runs.
new_repo repo
mkdir .claude
printf '#!/usr/bin/env bash\nexec "$(dirname "$0")/stub.sh"\n' >.claude/verify.sh
chmod +x .claude/verify.sh
git add .claude/verify.sh && git commit -q -m "add verify.sh" && git push -q origin main 2>/dev/null
printf '.claude/stub.sh\n' >.git/info/exclude # keep the stub out of the "dirty" check
set_verify() { printf '#!/usr/bin/env bash\n%s\n' "$1" >.claude/stub.sh && chmod +x .claude/stub.sh; }

set_verify 'echo verify ran >&2; exit 1'
expect 0 "clean tree on the default branch skips verify"

echo change >file.txt
expect 2 "uncommitted work with failing verify blocks"
grep -q "verify ran" "$tmp/stderr" || fail "block reason should include verify output"
expect 0 "stop_hook_active lets Claude stop" true

git checkout -q -b feature && git add file.txt && git commit -q -m change
expect 2 "committed work not on the default branch is still verified"

set_verify "echo run >>'$tmp/runs'; exit 0"
expect 0 "passing verify allows the stop"
expect 0 "unchanged tree after a pass skips verify"
[ "$(wc -l <"$tmp/runs")" -eq 1 ] || fail "verify should have run once, ran $(wc -l <"$tmp/runs") times"
set_verify 'exit 1'
echo more >>file.txt
expect 2 "new changes after a pass are verified again"

set_verify "[ \"\$YARN_CACHE_FOLDER\" = '$HOME/.cache/yarn-sandbox' ] || { echo \"YARN_CACHE_FOLDER is \$YARN_CACHE_FOLDER\" >&2; exit 1; }"
echo again >>file.txt
YARN_CACHE_FOLDER="$tmp/other-cache" expect 0 "verify uses the sandbox's yarn cache"

# sandbox_check <description> <shell test that should pass inside the verify sandbox>
sandbox_check() {
  set_verify "$2 || { echo 'sandbox check failed' >&2; exit 1; }"
  echo "$1" >>file.txt
  VERIFY_TIMEOUT=30 expect 0 "verify sandbox: $1"
}
if [ -n "$real_sandbox" ]; then
  probe="$HOME/.claude-harness-sandbox-probe-$$"
  sandbox_check "can write the repo and temp" "touch inside.txt && touch '$tmp/inside.txt'"
  sandbox_check "can't write outside the repo" "! touch '$probe' 2>/dev/null"
  [ -e "$probe" ] && { rm -f "$probe"; fail "verify wrote outside the repo"; }
  sandbox_check "can't plant a git hook" "! touch .git/hooks/pre-push 2>/dev/null"
  sandbox_check "can't change git config" "! git config --local core.hooksPath x 2>/dev/null"
  sandbox_check "can still stage files" "git add inside.txt"
  echo SECRET=1 >.env
  sandbox_check "can't read .env" "! cat .env 2>/dev/null"
  rm .env
  sandbox_check "can't reach the network" "! /usr/bin/nc -z -G 5 1.1.1.1 443 2>/dev/null"
  sandbox_check "can't ask the keychain for passwords" \
    "security find-generic-password -s claude-harness-no-such-item >/dev/null 2>&1; [ \$? -ne 44 ]"
  git reset -q && rm -f inside.txt
fi

# No sandbox, no verify.
mkdir "$tmp/broken" && printf '#!/bin/bash\nexit 1\n' >"$tmp/broken/sandbox-exec" && chmod +x "$tmp/broken/sandbox-exec"
set_verify 'exit 0'
echo nosandbox >>file.txt
PATH="$tmp/broken:$PATH" expect 2 "verify that can't be sandboxed blocks"
grep -q "Can't sandbox the test command" "$tmp/stderr" || fail "no-sandbox reason missing"
mkdir "$tmp/no-profile" && cp "$(dirname "$hook")"/*.sh "$tmp/no-profile/"
real_hook="$hook" && hook="$tmp/no-profile/stop-verify.sh"
expect 2 "missing verify.sb blocks"
hook="$real_hook"

set_verify 'sleep 30'
echo hang >>file.txt
start=$(date +%s)
VERIFY_TIMEOUT=2 expect 2 "hung verify times out and blocks"
grep -q "timed out" "$tmp/stderr" || fail "timeout reason missing"
[ $(($(date +%s) - start)) -lt 10 ] || fail "timeout took too long"

set_verify 'exit 0'
echo edit >>.claude/verify.sh
expect 2 "uncommitted edit to verify.sh blocks"
grep -q "verify.sh changed in this session; human review required." "$tmp/stderr" || fail "verify.sh edit reason missing"
expect 0 "edited verify.sh: stop_hook_active lets Claude stop" true
git commit -q -am "edit verify.sh"
expect 2 "edit to verify.sh committed on the branch blocks"
git rm -q .claude/verify.sh && git commit -q -m "drop verify.sh"
expect 2 "deleting verify.sh blocks"
git checkout -q HEAD~2 -- .claude/verify.sh && git commit -q -m "restore verify.sh"
chmod -x .claude/verify.sh
set_verify 'echo stub ran >&2; exit 1'
expect 2 "verify.sh that lost its x bit still runs (via bash)"
grep -q "stub ran" "$tmp/stderr" || fail "non-executable verify.sh didn't run"
chmod +x .claude/verify.sh

# A repo with no verify.sh on its base and no other test entry point.
new_repo bare
expect 0 "no test command and no work allows the stop"
echo work >file.txt
expect 2 "work with no test command blocks"
grep -q "No test command for this repo. Add .claude/verify.sh or a supported test entry point." "$tmp/stderr" ||
  fail "no-test-command reason missing"
expect 0 "no test command: stop_hook_active lets Claude stop" true
mkdir .claude && printf '#!/usr/bin/env bash\nexit 0\n' >.claude/verify.sh && chmod +x .claude/verify.sh
printf '.claude/\n' >.git/info/exclude
expect 2 "new verify.sh blocks, even when ignored"
grep -q "human review required" "$tmp/stderr" || fail "new verify.sh reason missing"

# A local-only repo: no origin, so no base to compare against.
mkdir "$tmp/local" && cd "$tmp/local" && git init -q && git commit -q --allow-empty -m init
repo="$tmp/local"
expect 0 "clean local-only repo with no test command allows the stop"
echo work >file.txt
expect 2 "work in a local-only repo with no test command blocks"

printf 'not json' | "$hook" 2>/dev/null
[ $? -eq 0 ] || fail "unparseable input should allow the stop"

# detect-verify.sh's CMake/ctest detection. Only the printed command is checked,
# so cmake needn't be installed.
proj="$tmp/cmake"
mkdir -p "$proj"
# expect_detect <substring, or empty for no output> <description>
expect_detect() {
  local got
  got="$("$detect" "$proj")"
  if [ -z "$1" ]; then
    [ -z "$got" ] || fail "$2 (got '$got')"
  else
    case "$got" in *"$1"*) ;; *) fail "$2 (got '$got')" ;; esac
  fi
}
expect_detect '' "unknown stack prints nothing"
printf 'project(x)\n' >"$proj/CMakeLists.txt"
expect_detect '' "CMakeLists.txt without tests prints nothing"
printf 'project(x)\nenable_testing()\n' >"$proj/CMakeLists.txt"
expect_detect 'cmake -S . -B build && cmake --build build && ctest --test-dir build' "CMakeLists.txt with enable_testing is detected"
printf 'project(x)\ninclude(CTest)\n' >"$proj/CMakeLists.txt"
expect_detect 'ctest --test-dir build' "CMakeLists.txt with include(CTest) is detected"
mkdir -p "$proj/out/rel/sub"
touch "$proj/out/rel/CMakeCache.txt" "$proj/out/rel/CTestTestfile.cmake" "$proj/out/rel/sub/CTestTestfile.cmake"
expect_detect 'cmake --build out/rel && ctest --test-dir out/rel ' "build dir with CTestTestfile.cmake is detected"
rm "$proj/CMakeLists.txt"
expect_detect 'ctest --test-dir out/rel ' "build dir is detected without CMakeLists.txt"

if [ $failures -eq 0 ]; then
  echo "stop-verify.sh: all tests passed"
else
  echo "stop-verify.sh: $failures test(s) failed"
  exit 1
fi
