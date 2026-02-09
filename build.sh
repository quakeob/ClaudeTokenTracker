#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClaudeTokenTracker"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# --- Pre-flight checks ---

# Check for Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    echo "Error: Xcode Command Line Tools not found."
    echo "Install them with: xcode-select --install"
    exit 1
fi

# Check for Swift compiler
if ! xcrun swiftc --version &>/dev/null; then
    echo "Error: Swift compiler not found."
    echo "Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

# Check for Claude Code data directory
if [ ! -d "$HOME/.claude" ]; then
    echo "Warning: ~/.claude not found. Install Claude Code first for token tracking."
fi

# --- Detect macOS version ---

MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
VFS_FLAGS=""

if [ "$MACOS_MAJOR" -ge 26 ]; then
    # macOS 26 (Tahoe) has a duplicate SwiftBridging modulemap bug in CLT.
    # The VFS overlay maps out the conflicting module.modulemap.
    echo "Detected macOS $MACOS_MAJOR - applying VFS overlay workaround..."
    VFS_FLAGS="-vfsoverlay $SCRIPT_DIR/vfs_overlay.yaml"
fi

# --- Detect architecture ---

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET="arm64-apple-macosx14.0"
else
    TARGET="x86_64-apple-macosx14.0"
fi

# --- Find SDK ---

SDK_PATH=""
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" ]; then
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
elif xcrun --show-sdk-path &>/dev/null; then
    SDK_PATH="$(xcrun --show-sdk-path)"
else
    echo "Error: Could not find macOS SDK."
    exit 1
fi

# --- Build ---

echo "Building $APP_NAME..."
echo "  Architecture: $ARCH"
echo "  SDK: $SDK_PATH"
echo ""

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

xcrun swiftc \
    $VFS_FLAGS \
    -swift-version 5 \
    -target "$TARGET" \
    -sdk "$SDK_PATH" \
    -framework SwiftUI \
    -framework AppKit \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$SCRIPT_DIR/Sources/main.swift"

echo ""
echo "Build successful: $APP_BUNDLE"
echo ""
echo "To run:     open $APP_BUNDLE"
echo "To install: cp -r $APP_BUNDLE /Applications/"
