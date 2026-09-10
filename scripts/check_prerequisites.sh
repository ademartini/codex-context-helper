#!/bin/sh
# Read-only checks. Deliberately contains no installer/package-manager fallback.
set -eu
for tool in xcodebuild xcrun swift codesign security python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing prerequisite: $tool. Stop and ask the user; install nothing." >&2; exit 1; }
done
xcodebuild -version
swift --version
xcrun --sdk macosx --show-sdk-path
