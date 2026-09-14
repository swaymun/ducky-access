#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_path="${1:-$project_dir/build/DuckyAccessConfiguratorProfile-$(date +%Y%m%d-%H%M%S).zip}"
tmp_base="${TMPDIR:-/tmp}"
staging_dir="$(mktemp -d "$tmp_base/ducky-access-profile.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

profile_dir="$staging_dir/profile_DuckyAccess"
mkdir -p "$profile_dir"
COPYFILE_DISABLE=1 cp "$project_dir"/profile/DuckyAccess/* "$profile_dir/"

mkdir -p "$(dirname "$output_path")"
(cd "$staging_dir" && zip -qr "$output_path" profile_DuckyAccess)
unzip -tq "$output_path" >/dev/null
echo "$output_path"
