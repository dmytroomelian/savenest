#!/bin/bash
# Local-only AWS acceptance app. Never replaces or publishes the production app.
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="$PWD"
beta_source="$(mktemp -d /tmp/savenest-aws-beta-source.XXXXXX)"
beta_app="$beta_source/SaveNest AWS Beta.app"
beta_installed="$HOME/Applications/SaveNest AWS Beta.app"
beta_scratch="${SAVENEST_BETA_SCRATCH_PATH:-/tmp/savenest-aws-beta-swift}"
rsync -a --exclude='* 2.swift' --exclude='* 2.cjs' --exclude='* 2.md' \
  Sources Tests Resources scripts Package.swift Package.resolved "$beta_source/"
if [[ -d "$source_root/node_modules" ]]; then ln -s "$source_root/node_modules" "$beta_source/node_modules"; fi
(
  cd "$beta_source"
  CONFIGURATION=debug SWIFT_SCRATCH_PATH="$beta_scratch" APP_PATH="$beta_app" bash scripts/build-app.sh
)
python3 - "$beta_app/Contents/Info.plist" <<'PY'
import plistlib,sys
path=sys.argv[1]
with open(path,'rb') as f: value=plistlib.load(f)
value.update(CFBundleIdentifier='app.savenest.aws-beta',CFBundleDisplayName='SaveNest AWS Beta',CFBundleName='SaveNest AWS Beta',SaveNestAccountBaseURL='https://d7ltannvnl.execute-api.eu-north-1.amazonaws.com',SaveNestCloudBaseURL='https://d7ltannvnl.execute-api.eu-north-1.amazonaws.com',SaveNestUpdatesEnabled=False)
value['CFBundleURLTypes']=[{'CFBundleTypeRole':'Editor','CFBundleURLName':'app.savenest.aws-beta.auth','CFBundleURLSchemes':['savenest-beta']}]
value.pop('SaveNestPostHogProjectToken',None)
value.pop('SaveNestPostHogHost',None)
with open(path,'wb') as f: plistlib.dump(value,f)
PY
codesign --force --entitlements Resources/SaveNest.entitlements --sign - "$beta_app"
codesign --verify --deep --strict "$beta_app"
# LaunchServices can register /tmp bundles but excludes them from URL-handler
# resolution. Install the finished beta identity before registering its scheme.
mkdir -p "$(dirname "$beta_installed")"
ditto "$beta_app" "$beta_installed"
codesign --verify --deep --strict "$beta_installed"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$beta_installed"
printf 'Private AWS app: %s\nSource snapshot: %s\n' "$beta_installed" "$beta_source"
