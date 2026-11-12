#!/usr/bin/env bash
# Builds a drag-and-drop .rbxm from the Wally/package Rojo project.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
if [ -z "$VERSION" ]; then
	echo "VERSION is empty" >&2
	exit 1
fi

WALLY_VERSION="$(awk -F'= *' '/^version *=/{gsub(/"/, "", $2); print $2; exit}' wally.toml)"
if [ -n "$WALLY_VERSION" ] && [ "$WALLY_VERSION" != "$VERSION" ]; then
	echo "VERSION ($VERSION) does not match wally.toml version ($WALLY_VERSION)" >&2
	exit 1
fi

mkdir -p build
OUTPUT="build/ThunderNet-${VERSION}.rbxm"
rojo build default.project.json -o "$OUTPUT"
echo "built $OUTPUT"
