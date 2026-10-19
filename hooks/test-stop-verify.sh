#!/usr/bin/env bash
# Self-test for stop-verify.sh: test-stop-verify.sh [path/to/stop-verify.sh]
# Runs the hook against a scratch repo with a stub verify.sh and checks when it
# runs verify, when it blocks (exit 2), and that it caches passes and times out.

hook="${1:-$(dirname "$0")/stop-verify.sh}"
hook="$(cd "$(dirname "$hook")" && pwd)/$(basename "$hook")"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-harness-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
repo="$tmp/repo"
cd "$repo" || exit 1
git checkout -q -b main
git -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
git push -q origin main 2>/dev/null
git remote set-head origin main
mkdir .claude
printf '.claude/\n' >.git/info/exclude # keep the stub out of the "dirty" check

failures=0
set_verify() { printf '#!/usr/bin/env bash\n%s\n' "$1" >.claude/verify.sh && chmod +x .claude/verify.sh; }

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

set_verify 'echo verify ran >&2; exit 1'
expect 0 "clean tree on the default branch skips verify"

echo change >file.txt
expect 2 "uncommitted work with failing verify blocks"
grep -q "verify ran" "$tmp/stderr" || { echo "FAIL: block reason should include verify output"; failures=$((failures + 1)); }
expect 0 "stop_hook_active lets Claude stop" true

git checkout -q -b feature && git add file.txt &&
  git -c user.name=test -c user.email=test@example.com commit -q -m change
expect 2 "committed work not on the default branch is still verified"

set_verify 'exit 0'
expect 0 "passing verify allows the stop"
set_verify 'exit 1'
expect 0 "unchanged tree after a pass skips verify"
echo more >>file.txt
expect 2 "new changes after a pass are verified again"

set_verify 'sleep 30'
start=$(date +%s)
VERIFY_TIMEOUT=2 expect 2 "hung verify times out and blocks"
grep -q "timed out" "$tmp/stderr" || { echo "FAIL: timeout reason missing"; failures=$((failures + 1)); }
[ $(($(date +%s) - start)) -lt 10 ] || { echo "FAIL: timeout took too long"; failures=$((failures + 1)); }

rm .claude/verify.sh
expect 0 "no verify.sh allows the stop"

printf 'not json' | "$hook" 2>/dev/null
[ $? -eq 0 ] || { echo "FAIL: unparseable input should allow the stop"; failures=$((failures + 1)); }

if [ $failures -eq 0 ]; then
  echo "stop-verify.sh: all tests passed"
else
  echo "stop-verify.sh: $failures test(s) failed"
  exit 1
fi
