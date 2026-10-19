# Video Compressor

A macOS menu bar app that shrinks videos with ffmpeg while keeping them visually lossless. Drag a video onto the menu bar icon (or onto the drop zone that appears while you drag) and a `<name>_compressed.mp4` lands next to the original.

## What it does

- Re-encodes with x264 at CRF 18, `slow` preset, same resolution and frame rate.
- Copies AAC audio untouched; other audio (PCM from `.mov`, etc.) becomes 192 kbps AAC.
- Adds `+faststart` so the file streams on the web without waiting for a full download.
- Scores the result against the original with VMAF (SSIM if your ffmpeg lacks libvmaf). 95+ is generally indistinguishable.
- Leaves already-compressed files alone: if re-encoding would make a file bigger, it's discarded.
- Never touches the original. Dropping the same file again replaces its `_compressed` copy.

While it works, the menu bar shows progress. When a file finishes you get a notification; click it to reveal the file in Finder. The menu has a file picker, cancel, recent results, a drop zone toggle and launch at login.

## Requirements

- macOS 15 or later on Apple silicon
- Xcode or the Command Line Tools (Swift 6)
- ffmpeg, which `./build.sh install` sets up for you

## Build and install

```sh
./build.sh           # builds build/Video Compressor.app
./build.sh install   # also installs ffmpeg if needed, copies the app to /Applications and launches it
```

If ffmpeg isn't in `/opt/homebrew/bin` or `/usr/local/bin`, `install` runs `brew install ffmpeg`. If Homebrew isn't installed either, it asks before installing it, since that needs your admin password.

The app is ad-hoc signed, so macOS asks once for notification permission and, if your videos live in Desktop, Documents or Downloads, for access to that folder. Rebuilding changes the signature, so the folder prompts can come back after a rebuild.

## The script on its own

The app runs `Resources/compress-video.command`, which also works without the app:

```sh
Resources/compress-video.command [-c CRF] [-f] video [video ...]
```

- `-c CRF` sets quality; lower is better (default 18; try 20–22 for smaller files)
- `-f` overwrites an existing `_compressed` file

Double-click it in Finder and it asks you to drag videos into the Terminal window. The app bundles its own copy of the script, so run `./build.sh install` again after changing it.
