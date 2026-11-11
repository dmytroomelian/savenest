#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug
preview_bin_dir="$(swift build -c debug --show-bin-path)"
source scripts/sparkle-common.sh
preview_app="build/SaveNest Preview.app"
mkdir -p "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources"
cp "$preview_bin_dir/SaveNest" "$preview_app/Contents/MacOS/SaveNest"
cp Resources/Info.plist "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.savenest.preview" "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Savenest Preview" "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Savenest Preview" "$preview_app/Contents/Info.plist"
# The sample-library app must not intercept real account callbacks.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :SaveNestUpdatesEnabled false' "$preview_app/Contents/Info.plist"
swift scripts/make-icon.swift
cp build/AppIcon.icns "$preview_app/Contents/Resources/AppIcon.icns"
embed_sparkle "$preview_app" -
codesign --force --sign - "$preview_app"
codesign --verify --deep --strict "$preview_app"
open "$preview_app" --args --ui-preview
