#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
install_dir="$HOME/Applications"
if [[ $# -gt 0 ]]; then
    install_dir="$1"
fi
app="$install_dir/Wayback Folder Downloader.app"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

mkdir -p "$build_dir/Contents/MacOS"
cp "$project_dir/Info.plist" "$build_dir/Contents/Info.plist"
swiftc -swift-version 6 -target "$(uname -m)-apple-macos14.0" -O \
    "$project_dir"/Sources/*.swift -o "$build_dir/Contents/MacOS/WaybackFolderDownloader"
mkdir -p "$install_dir"
ditto "$build_dir" "$app"
codesign --force --sign - "$app"
printf '%s\n' "$app"
