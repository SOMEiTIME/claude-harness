#!/usr/bin/env bash
# Print the test command for a repo: detect-verify.sh <repo-root>
# Prints one shell command to run from the repo root, or nothing if it can't
# tell. First match wins:
#   .claude/verify.sh, package.json "test" script, Cargo, Go, pytest,
#   Makefile "test" target, CMake/ctest.
# Written for bash 3.2, which is what macOS ships.

root="${1:?usage: detect-verify.sh <repo-root>}"
cd "$root" || exit 1
hook_dir="$(cd "$(dirname "$0")" && pwd)"

# Use verify.sh whenever it exists, so chmod -x can't drop to a weaker command.
if [ -f .claude/verify.sh ]; then
  if [ -x .claude/verify.sh ]; then echo .claude/verify.sh; else echo "bash .claude/verify.sh"; fi
  exit 0
fi

if [ -f package.json ]; then
  test_script="$("$hook_dir/json-field.sh" scripts.test <package.json 2>/dev/null)"
  # npm init's placeholder isn't a test command.
  case "$test_script" in
    "" | *"no test specified"*) ;;
    *)
      if [ -f yarn.lock ]; then echo "yarn test"
      elif [ -f pnpm-lock.yaml ]; then echo "pnpm test"
      else echo "npm test"
      fi
      exit 0
      ;;
  esac
fi

[ -f Cargo.toml ] && { echo "cargo test"; exit 0; }
[ -f go.mod ] && { echo "go test ./..."; exit 0; }

if [ -f pytest.ini ] || [ -f conftest.py ] ||
  grep -qs '^\[tool\.pytest' pyproject.toml || grep -qs '^\[tool:pytest\]' setup.cfg tox.ini; then
  echo "python3 -m pytest"
  exit 0
fi

grep -qs '^test:' Makefile makefile GNUmakefile && { echo "make test"; exit 0; }

# CMake: an existing build dir with tests, else a project that enables them.
# Build first either way, so ctest doesn't run stale binaries.
for testfile in */CTestTestfile.cmake */*/CTestTestfile.cmake; do
  [ -f "$testfile" ] || continue
  dir="$(dirname "$testfile")"
  # Skip subproject dirs inside a build tree; the build root has CMakeCache.txt.
  [ -f "$dir/CMakeCache.txt" ] || continue
  dir="$(printf '%q' "$dir")"
  echo "cmake --build $dir && ctest --test-dir $dir --output-on-failure --no-tests=error"
  exit 0
done
if grep -qsiE '^[[:space:]]*(enable_testing|include[[:space:]]*\([[:space:]]*CTest[[:space:]]*\))' CMakeLists.txt; then
  echo "cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure --no-tests=error"
  exit 0
fi
