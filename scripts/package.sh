#!/usr/bin/env bash
# Builds the drag-and-drop .rbxm from the package Rojo project.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
if [ -z "$VERSION" ]; then
	echo "VERSION is empty" >&2
	exit 1
fi

mkdir -p build
OUTPUT="build/ThunderNet-${VERSION}.rbxm"
rojo build default.project.json -o "$OUTPUT"
echo "built $OUTPUT"
