#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${OMT_TEST_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation)}"
xcodebuild -project OMTReceiver.xcodeproj -scheme OMTReceiver \
  -destination "$destination" -configuration Debug \
  -derivedDataPath build/DerivedData -resultBundlePath "build/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  CODE_SIGNING_ALLOWED=NO test
