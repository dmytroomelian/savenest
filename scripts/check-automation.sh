#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_args=(-c debug)
if [[ -n "${SWIFT_SCRATCH_PATH:-}" ]]; then build_args+=(--scratch-path "$SWIFT_SCRATCH_PATH"); fi
swift build "${build_args[@]}" --product SaveNest
native_bin=$(swift build "${build_args[@]}" --show-bin-path)
"$native_bin/SaveNest" --ui-preview --automation-checks
