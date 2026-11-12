#!/usr/bin/env bash
# Full verification: embedded CLI tests, strict analysis, and Rojo build.
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/embed.mjs tests/cli/generated/AllModules.luau
luau tests/cli/run.luau
node scripts/analyze.mjs
mkdir -p build
rojo build default.project.json -o build/ThunderNet.rbxlx
echo "check complete: build/ThunderNet.rbxlx"
