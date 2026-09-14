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
codesign --force --deep --sign - "$app_dir" >/dev/null
echo "$app_dir"
