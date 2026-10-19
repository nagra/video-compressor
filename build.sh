#!/bin/zsh
# Builds "Video Compressor.app" into ./build.
#   ./build.sh           build only
#   ./build.sh install   build, copy to /Applications and relaunch
#
# The app runs its own copy of the script in Resources/compress-video.command;
# rebuild after changing it.

set -euo pipefail
cd "${0:A:h}"

app="build/Video Compressor.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc -O -swift-version 6 -target arm64-apple-macos15.0 -parse-as-library \
  Sources/App.swift -o "$app/Contents/MacOS/VideoCompressor"
cp Info.plist "$app/Contents/"
cp Resources/compress-video.command "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "Built $app"

if [[ ${1:-} == install ]]; then
  pkill -x VideoCompressor || true
  rm -rf "/Applications/Video Compressor.app"
  cp -R "$app" /Applications/
  open "/Applications/Video Compressor.app"
  echo "Installed to /Applications and launched"
fi
