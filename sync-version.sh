#!/usr/bin/env bash
# sync-version.sh — Pull version from SageFs and update lua/sagefs/version.lua
# Usage: ./sync-version.sh [path-to-sagefs-repo]
#
# If no path given, tries ../SageFs relative to this repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAGEFS_DIR="${1:-$SCRIPT_DIR/../SageFs}"
VERSION_FILE="$SCRIPT_DIR/lua/sagefs/version.lua"

if [ ! -f "$SAGEFS_DIR/Directory.Build.props" ]; then
  echo "ERROR: Cannot find $SAGEFS_DIR/Directory.Build.props"
  echo "Usage: $0 [path-to-sagefs-repo]"
  exit 1
fi

VERSION=$(grep -oP '(?<=<Version>)[^<]+' "$SAGEFS_DIR/Directory.Build.props")

if [ -z "$VERSION" ]; then
  echo "ERROR: Could not extract version from Directory.Build.props"
  exit 1
fi

echo "return \"$VERSION\"" > "$VERSION_FILE"
echo "Synced version to $VERSION"
