#!/bin/zsh
# Builds "Video Compressor.app" into ./build.
#   ./build.sh           build only
#   ./build.sh install   install ffmpeg if needed, build, copy to /Applications and relaunch
#
# The app runs its own copy of the script in Resources/compress-video.command;
# rebuild after changing it.

set -euo pipefail
cd "${0:A:h}"

# The app only looks for ffmpeg where Homebrew puts it, since apps launched from
# Finder don't get your shell's PATH.
has_ffmpeg() {
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [[ -x $dir/ffmpeg && -x $dir/ffprobe ]]; then return 0; fi
  done
  return 1
}

brew_path() {
  for brew in ${commands[brew]:-} /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x $brew ]]; then print -r -- $brew; return 0; fi
  done
  return 1
}

install_ffmpeg() {
  if has_ffmpeg; then return; fi

  local brew
  if ! brew=$(brew_path); then
    if [[ ! -t 0 ]] || ! read -q "?ffmpeg is installed with Homebrew, which isn't set up yet. Install Homebrew now? [y/N] "; then
      echo
      echo "Install Homebrew from https://brew.sh, then run ./build.sh install again."
      exit 1
    fi
    echo
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew=$(brew_path)
  fi

  echo "Installing ffmpeg with Homebrew (this can take a few minutes)…"
  "$brew" install ffmpeg
}

if [[ ${1:-} == install ]]; then
  install_ffmpeg
fi

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
