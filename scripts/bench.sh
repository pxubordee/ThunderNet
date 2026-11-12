#!/usr/bin/env bash
# Runs ThunderNet CPU benchmarks on the Luau CLI simulated Roblox environment.
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/embed.mjs tests/cli/generated/AllModules.luau
luau benchmarks/cli/run.luau
