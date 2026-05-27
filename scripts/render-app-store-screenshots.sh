#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${repo_root}/ios/fastlane/screenshots/en-CA"
marker_file="${repo_root}/ios/fastlane/screenshots/.render-enabled"

mkdir -p "${output_dir}"
touch "${marker_file}"
trap 'rm -f "${marker_file}"' EXIT

cd "${repo_root}/ios"
xcodebuild test \
  -project RoadSenseNS.xcodeproj \
  -scheme RoadSenseNSMockupRender \
  -configuration "Local Debug" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:RoadSenseNSTests/MockupRenderTests/testRenderMockups \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  ENABLE_PREVIEWS=NO
