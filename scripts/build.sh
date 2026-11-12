#!/usr/bin/env bash
# Builds a place file from the Rojo project (verifies project wiring).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
rojo build default.project.json -o build/ThunderNet.rbxlx
