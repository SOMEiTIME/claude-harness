#!/usr/bin/env bash
# Verify for music_viz_gltchr: unit tests (same as CI) and a production build.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d node_modules ] || yarn install --frozen-lockfile
yarn test
yarn build
