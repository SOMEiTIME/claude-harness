#!/usr/bin/env bash
# Verify for midi-interval-processor: warning-free build, then the GoogleTest
# suite if gtest is installed (it isn't on every machine; the Dockerfile has it).
set -euo pipefail
cd "$(dirname "$0")/.."
build_log="$(make midiToInterval 2>&1)" || { echo "$build_log"; exit 1; }
echo "$build_log"
if grep -q "warning:" <<<"$build_log"; then
  echo "Build has warnings; the code is meant to stay warning-free." >&2
  exit 1
fi
if echo '#include <gtest/gtest.h>' | g++ -std=c++11 -x c++ -fsyntax-only - >/dev/null 2>&1; then
  make test
else
  echo "gtest not installed; skipped make test (run it in Docker: docker build ./ --tag midi_interval_tests)"
fi
