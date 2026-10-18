#!/usr/bin/env bash
# Verify for Media-Eroder: production build (no test suite yet; add `yarn test`
# here when Vitest lands, PLAN.md milestone 2). Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d node_modules ] || yarn install --frozen-lockfile
yarn build
