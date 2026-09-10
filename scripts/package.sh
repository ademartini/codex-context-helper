#!/bin/bash
# Uses only the installed Xcode and macOS tools. Never installs or downloads tools.
# Default: development-only ad-hoc signature with Hardened Runtime.
# Distribution opt-in requires BOTH existing DEVELOPER_ID_APPLICATION (name/SHA-1)
# and NOTARYTOOL_PROFILE (stored notarytool keychain profile). No credentials are created.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_mode=development
signing_identity=-
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" || -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" || -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "Distribution requires both an existing Developer ID Application identity and an existing notarytool profile. Nothing was installed." >&2
    exit 1
  fi
  package_mode=distribution
fi

for required_tool in xcodebuild xcrun codesign ditto security plutil awk; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "Missing prerequisite: $required_tool. Stop and ask the user; install nothing." >&2
    exit 1
  fi
done
xcrun --sdk macosx --show-sdk-path >/dev/null

if [[ "$package_mode" == distribution ]]; then
  signing_identity="$(security find-identity -v -p codesigning | awk -v desired="$DEVELOPER_ID_APPLICATION" '
    /"Developer ID Application:/ {
      hash = $2; name = $0
      sub(/^[^"]*"/, "", name); sub(/".*$/, "", name)
      if (desired == hash || desired == name) { print hash; exit }
    }')"
  if [[ -z "$signing_identity" ]]; then
    echo "The requested valid Developer ID Application identity is unavailable. Stop; no credential acquisition was attempted." >&2
    exit 1
  fi
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null
  # Validate the existing profile before doing distribution packaging. This contacts
  # Apple's notarization service, but does not install or acquire any component.
  xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" --output-format json >/dev/null
fi

output_dir="${PACKAGE_OUTPUT_DIR:-$repo_root/dist/$package_mode}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app_path="$output_dir/CodexContextHelper.app"
if [[ -e "$app_path" || -e "$output_dir/CodexContextHelper.zip" ]]; then
  echo "Package destination already exists. Choose a fresh PACKAGE_OUTPUT_DIR to preserve it: $output_dir" >&2
  exit 1
fi

xcodebuild -project "$repo_root/CodexContextHelper.xcodeproj" \
  -scheme CodexContextHelper -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$output_dir/DerivedData" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build >"$output_dir/build.log" 2>&1

ditto "$output_dir/DerivedData/Build/Products/Release/CodexContextHelper.app" "$app_path"
# Explicit post-build signing avoids Xcode disabling Hardened Runtime for ad-hoc builds.
if [[ "$package_mode" == development ]]; then
  codesign --force --sign - --options runtime --timestamp=none "$app_path"
else
  codesign --force --sign "$signing_identity" --options runtime --timestamp "$app_path"
fi
codesign --verify --strict --verbose=2 "$app_path"
codesign --display --verbose=4 "$app_path" >"$output_dir/signature.txt" 2>&1
if ! awk '/flags=.*runtime/ { found = 1 } END { exit !found }' "$output_dir/signature.txt"; then
  echo "Package signature is missing Hardened Runtime. Packaging failed." >&2
  exit 1
fi
codesign --display --entitlements :- "$app_path" >"$output_dir/entitlements.plist" 2>/dev/null
if [[ -s "$output_dir/entitlements.plist" ]]; then
  sandbox_value="$(plutil -extract com.apple.security.app-sandbox raw -o - "$output_dir/entitlements.plist" 2>/dev/null || true)"
  if [[ "$sandbox_value" == true ]]; then
    echo "Unexpected App Sandbox entitlement. Packaging failed." >&2
    exit 1
  fi
fi

if [[ "$package_mode" == development ]]; then
  cat >"$output_dir/DEVELOPMENT-ONLY.txt" <<'NOTICE'
Development-only local build. Signed ad-hoc with Hardened Runtime.
Not signed with Developer ID, not notarized, and not approved for distribution.
Launch this app from a stable location when testing Accessibility or launch at login.
No tool, SDK, dependency, signing identity, or notarization profile was acquired.
NOTICE
else
  ditto -c -k --keepParent "$app_path" "$output_dir/CodexContextHelper.zip"
  xcrun notarytool submit "$output_dir/CodexContextHelper.zip" \
    --keychain-profile "$NOTARYTOOL_PROFILE" --wait --output-format plist >"$output_dir/notarization.plist"
  if [[ "$(plutil -extract status raw -o - "$output_dir/notarization.plist")" != Accepted ]]; then
    echo "Notarization was not accepted. Distribution packaging failed." >&2
    exit 1
  fi
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  # Recreate the archive with the stapled ticket, replacing only this script's archive.
  ditto -c -k --keepParent "$app_path" "$output_dir/CodexContextHelper-stapled.zip"
  mv "$output_dir/CodexContextHelper-stapled.zip" "$output_dir/CodexContextHelper.zip"
  codesign --verify --strict --verbose=2 "$app_path"
fi
printf 'Packaged %s build: %s\n' "$package_mode" "$app_path"
