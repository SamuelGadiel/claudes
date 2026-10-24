#!/bin/bash
# Builds ClaudeS.app — a real, launchable macOS app bundle — from the
# release build of the ClaudeSApp executable target. Ad-hoc signed
# (no Apple Developer account needed); see plans/KANBAN.md for the plan to
# move to a real Developer ID + notarization later.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="ClaudeS"
EXECUTABLE_NAME="ClaudeSApp"
RESOURCE_BUNDLE_NAME="claudes_ClaudeSApp.bundle"
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
# Bundled so the GUI app can install it into the user's PATH on first
# launch (ShellInstall, called from AppDelegate) — without this, `cs`
# install-cli` has nothing to point at until the user builds it separately.
cp "$RELEASE_DIR/cs" "$APP_BUNDLE/Contents/MacOS/cs"
cp Packaging/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# VERSION (major.minor.patch+build) is the single source of truth — kept
# out of Info.plist so a version bump never needs a second file edited by
# hand. CFBundleVersion (the build counter) is what macOS itself compares
# to decide an update is newer; CFBundleShortVersionString is the
# user-facing semver shown in Finder/About.
VERSION_STRING="$(cat VERSION)"
SHORT_VERSION="${VERSION_STRING%+*}"
BUILD_NUMBER="${VERSION_STRING##*+}"
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
# assets/ is the single source of truth for the icon — Packaging/ only
# holds build-time metadata (Info.plist), not a second copy of artwork.
cp assets/ClaudeS.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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
