#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
app_dir="$project_dir/build/DuckyAccess.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/arm64-apple-macosx/release/DuckyAccess "$app_dir/Contents/MacOS/DuckyAccess"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
signing_identity="${DUCKY_ACCESS_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '\"' '/Apple Development:/ {print $2; exit}')"
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
fi
codesign --force --deep --sign "$signing_identity" "$app_dir" >/dev/null
echo "Signed with: $signing_identity"
echo "$app_dir"
