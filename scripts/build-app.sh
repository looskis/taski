#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
output_dir="$repo_dir/dist"
app_dir="$output_dir/Taski.app"
identity=${TASKI_SIGNING_IDENTITY:-}

if [[ ${1:-} == "--unsigned" ]]; then
  identity="-"
elif [[ -z "$identity" ]]; then
  print -u2 "Set TASKI_SIGNING_IDENTITY to a Developer ID/Application identity, or pass --unsigned for local verification."
  exit 2
fi

swift build -c release --package-path "$repo_dir" --product taski
binary_dir=$(swift build -c release --package-path "$repo_dir" --show-bin-path)
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
cp "$binary_dir/taski" "$app_dir/Contents/MacOS/taski"
codesign --force --options runtime --timestamp=none --entitlements "$repo_dir/Packaging/Taski.entitlements" --sign "$identity" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
print "$app_dir"
