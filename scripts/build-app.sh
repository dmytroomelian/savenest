#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
reuse_assets="${RELEASE_REUSE_ASSETS:-0}"
if [[ "$reuse_assets" == "1" ]]; then
  missing=()
  for asset in electron/renderer/workspace.js build/AppIcon.icns build/reader-third-party-licenses.txt; do
    [[ -f "$asset" ]] || missing+=("$asset")
  done
  if (( ${#missing[@]} )); then
    echo "RELEASE_REUSE_ASSETS=1 requires prepared assets: ${missing[*]}" >&2
    echo "Run the release orchestrator (or npm run build:ui && swift scripts/make-icon.swift) first." >&2
    exit 1
  fi
else
  if [[ "${ELECTRON_HELPER:-0}" == "1" ]]; then node scripts/build-ui.mjs; fi
fi
if [[ "${ELECTRON_HELPER:-0}" == "1" ]]; then node scripts/build-services.mjs; fi
build_args=(-c "$configuration" --product SaveNest)
if [[ -n "${SWIFT_SCRATCH_PATH:-}" ]]; then build_args+=(--scratch-path "$SWIFT_SCRATCH_PATH"); fi
if [[ -n "${TARGET_ARCH:-}" ]]; then
  case "$TARGET_ARCH" in arm64|x86_64) build_args+=(--arch "$TARGET_ARCH");; *) echo "TARGET_ARCH must be arm64 or x86_64" >&2; exit 1;; esac
fi
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
source scripts/sparkle-common.sh
app="${APP_PATH:-build/SaveNest.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/SaveNest" "$app/Contents/MacOS/SaveNest"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f node_modules/@mozilla/readability/Readability.js ]]; then
  cp node_modules/@mozilla/readability/Readability.js "$app/Contents/Resources/ReaderReadability.js"
fi
# Local builds do not replace themselves with a public release.
/usr/libexec/PlistBuddy -c 'Set :SaveNestUpdatesEnabled false' "$app/Contents/Info.plist"
if [[ "${ELECTRON_HELPER:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$app/Contents/Info.plist"
  # The outer Electron bundle advertises the Services port; the child must not duplicate it.
  /usr/libexec/PlistBuddy -c 'Delete :NSServices' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$app/Contents/Info.plist"
fi
if [[ "$reuse_assets" != "1" ]]; then
  swift scripts/make-icon.swift
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Use a Developer ID identity for distribution; ad-hoc signing is for local use.
embed_sparkle "$app" "${SIGNING_IDENTITY:--}"
signing_options=(--force --entitlements Resources/SaveNest.entitlements --sign "${SIGNING_IDENTITY:--}")
# Ad-hoc local builds have no Team ID for hardened runtime library validation.
if [[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != "-" ]]; then signing_options+=(--options runtime --timestamp); fi
xattr -cr "$app"
codesign "${signing_options[@]}" "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
