#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClaudeTokenTracker"

echo "=== Claude Token Tracker Installer ==="
echo ""

# Build
bash "$SCRIPT_DIR/build.sh"

echo ""
echo "Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -r "$SCRIPT_DIR/build/$APP_NAME.app" "/Applications/"

echo ""
echo "Done! Claude Token Tracker has been installed."
echo ""
echo "Opening now..."
open "/Applications/$APP_NAME.app"
