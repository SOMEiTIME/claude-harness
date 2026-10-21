#!/usr/bin/env bash
# Verify for claude-harness: syntax-check every script and run the hook
# self-tests, all under /bin/bash (3.2, what macOS ships and the hooks target).
set -euo pipefail
cd "$(dirname "$0")/.."
for script in *.sh hooks/*.sh verify/*.sh; do
  /bin/bash -n "$script"
done
/bin/bash hooks/test-block-dangerous.sh
/bin/bash hooks/test-stop-verify.sh
