#!/bin/bash
# Direct Apple XCTest runner for unit tests; no UI automation or IDE-session handshake.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${TEST_DERIVED_DATA:-$repo_root/.build-unit}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
developer_dir="$(xcode-select -p)"
xctest_path="$(xcrun --find xctest)"
xcodebuild -project "$repo_root/CodexContextHelper.xcodeproj" \
  -scheme CodexContextHelper -destination 'platform=macOS' -derivedDataPath "$build_dir" \
  -disableAutomaticPackageResolution -skipPackageUpdates build-for-testing >"$build_dir/unit-build.log" 2>&1
app_path="$build_dir/Build/Products/Debug/CodexContextHelper.app"
# The test bundle imports the app's Debug dylib. No application main is executed.
env -i PATH=/usr/bin:/bin \
  DYLD_LIBRARY_PATH="$app_path/Contents/MacOS:$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib" \
  DYLD_FRAMEWORK_PATH="${developer_dir%/Developer}/SharedFrameworks" \
  "$xctest_path" "$app_path/Contents/PlugIns/CodexContextHelperTests.xctest" >"$build_dir/unit-tests.log" 2>&1
if ! /usr/bin/grep -Eq 'Executed [1-9][0-9]* tests?, with 0 failures' "$build_dir/unit-tests.log"; then
  echo "No passing unit-test execution found. Inspect $build_dir/unit-tests.log" >&2
  exit 1
fi
tail -n 4 "$build_dir/unit-tests.log"
