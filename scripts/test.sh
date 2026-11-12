#!/usr/bin/env bash
# Runs the ThunderNet test suite with the Luau CLI simulated Roblox runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/embed.mjs tests/cli/generated/AllModules.luau
luau tests/cli/run.luau
