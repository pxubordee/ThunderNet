#!/usr/bin/env bash
# Builds the development place file (examples + tests) from the Rojo project.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
rojo build dev.project.json -o build/ThunderNet.rbxlx
