#!/bin/bash
# Builds ClaudeSwitcher.app — a real, launchable macOS app bundle — from the
# release build of the ClaudeSwitcherApp executable target. Ad-hoc signed
# (no Apple Developer account needed); see plans/KANBAN.md for the plan to
# move to a real Developer ID + notarization later.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="ClaudeSwitcher"
EXECUTABLE_NAME="ClaudeSwitcherApp"
RESOURCE_BUNDLE_NAME="claude-switcher_ClaudeSwitcherApp.bundle"
BUILD_DIR=".build/apple/Products/Release"
OUT_DIR="dist"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "==> Building release binary..."
swift build -c release
RELEASE_DIR=".build/release"
# TODO: universal binary (arm64 + x86_64) for Intel Mac users — swift build
# --arch arm64 --arch x86_64 puts output under .build/apple/Products/Release
# instead; left as a follow-up once the single-arch flow is validated.

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$RELEASE_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp Packaging/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# The SwiftPM-generated Bundle.module accessor resolves resources relative
# to the .app bundle's own root, not Contents/Resources — staging the
# resource bundle there makes codesign reject the app ("unsealed contents
# present in the bundle root"). AppResources.swift works around this by
# looking in Contents/Resources first (the conventional, sealable
# location) and only falling back to Bundle.module in development. So the
# resource bundle goes here, inside Contents/Resources, never at the root.
if [ -d "$RELEASE_DIR/$RESOURCE_BUNDLE_NAME" ]; then
    cp -r "$RELEASE_DIR/$RESOURCE_BUNDLE_NAME" "$APP_BUNDLE/Contents/Resources/$RESOURCE_BUNDLE_NAME"
else
    echo "WARNING: resource bundle not found at $RELEASE_DIR/$RESOURCE_BUNDLE_NAME — localization will not work."
fi

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Verifying signature..."
codesign --verify --verbose "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo "    Run it with: open '$APP_BUNDLE'"
