#!/bin/zsh
# Compress videos with x264 at near visually lossless quality.
# Writes <name>_compressed.mp4 next to each input, then reports the size
# saving and a VMAF score (SSIM if ffmpeg lacks libvmaf) against the original.
#
# Usage:
#   compress-video.command [-c CRF] [-f] video [video ...]
#   Or double-click it in Finder and drag videos into the window when asked.
#
#   -c CRF  x264 quality, lower is better (default 18; try 20-22 for smaller files)
#   -f      overwrite an existing _compressed file

set -u
# Finder launches don't always load the shell profile, so make Homebrew visible.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

crf=18
force=0

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts ":c:fh" opt; do
  case $opt in
    c) crf=$OPTARG ;;
    f) force=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

for tool in ffmpeg ffprobe; do
  command -v $tool >/dev/null || { echo "$tool not found. Install it with: brew install ffmpeg"; exit 1; }
done

if (( $# == 0 )); then
  print -n "Drag one or more videos here, then press Enter: "
  read -r line
  # Split the dropped paths the way the shell would, honouring quotes and escaped spaces.
  set -- "${(@Q)${(z)line}}"
fi
(( $# )) || { usage; exit 1; }

human() {
  if (( $1 < 1048576 )); then printf '%d KB' $(( $1 / 1024 ))
  else printf '%.1f MB' $(( $1 / 1048576.0 )); fi
}

# x264 needs even dimensions for yuv420p; the reference gets the same scale so
# the quality metrics compare like with like.
even='scale=trunc(iw/2)*2:trunc(ih/2)*2'

quality() {
  local out=$1 src=$2
  if ffmpeg -hide_banner -filters 2>/dev/null | grep -q libvmaf; then
    ffmpeg -hide_banner -i "$out" -i "$src" \
      -lavfi "[1:v]${even}[ref];[0:v][ref]libvmaf=n_threads=$(sysctl -n hw.ncpu)" -f null - 2>&1 \
      | grep -oE 'VMAF score: [0-9.]+' | awk '{printf "VMAF %.1f", $3}'
  else
    ffmpeg -hide_banner -i "$out" -i "$src" \
      -lavfi "[1:v]${even}[ref];[0:v][ref]ssim" -f null - 2>&1 \
      | grep -oE 'All:[0-9.]+' | awk -F: '{printf "SSIM %.4f", $2}'
  fi
}

compress() {
  local src=$1
  local out="${src:r}_compressed.mp4"

  [[ -f $src ]] || { echo "✗ Not a file: $src"; return 1; }
  if [[ -e $out ]] && (( ! force )); then
    echo "✗ $out already exists (use -f to overwrite)"
    return 1
  fi

  # Keep AAC audio untouched; anything else (PCM from .mov, etc.) can't go in an mp4 as is.
  local acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$src")
  local -a audio
  case $acodec in
    '') audio=() ;;
    aac) audio=(-c:a copy) ;;
    *) audio=(-c:a aac -b:a 192k) ;;
  esac

  echo "→ ${src:t} (CRF $crf)"
  ffmpeg -hide_banner -loglevel error -stats -y -i "$src" \
    -map 0:v:0 -map '0:a:0?' \
    -vf "$even" -c:v libx264 -preset slow -crf $crf -profile:v high -pix_fmt yuv420p \
    $audio -movflags +faststart -map_metadata 0 "$out" || { rm -f "$out"; echo "✗ ffmpeg failed on $src"; return 1; }

  local before=$(stat -f%z "$src") after=$(stat -f%z "$out")
  if (( after >= before )); then
    rm -f "$out"
    echo "• Already well compressed: re-encoding grew it ($(human $before) → $(human $after)), so it was left alone."
    return 0
  fi

  echo "  Checking quality against the original..."
  local score=$(quality "$out" "$src")
  echo "✓ $(human $before) → $(human $after) ($(( 100 - after * 100 / before ))% smaller), ${score:-quality check failed}"
  echo "  ${out}"
}

failed=0
for f in "$@"; do
  compress "$f" || failed=1
  echo
done
exit $failed
