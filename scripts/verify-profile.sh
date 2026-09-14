#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
profile_dir="$project_dir/profile/DuckyAccess"

test "$(find "$profile_dir" -name 'key*.txt' | wc -l | tr -d ' ')" -eq 26
rg -q '^IS_LANDSCAPE 1$' "$profile_dir/config.txt"
rg -q '^z1 NAV$' "$profile_dir/config.txt"
rg -q '^z17 ESC$' "$profile_dir/config.txt"
rg -q '^z26 AppSwitch$' "$profile_dir/config.txt"
rg -q '^F16$' "$profile_dir/key1.txt"
rg -q '^F17$' "$profile_dir/key5.txt"
rg -q '^F20$' "$profile_dir/key17.txt"
rg -q '^F21$' "$profile_dir/key21.txt"
rg -q '^F15$' "$profile_dir/key26.txt"
echo "DuckyAccess profile verified: 26 scripts, landscape layout, OLED labels, and bridge chords."
