#!/usr/bin/env bash
# pairwise_diff.sh - Detect duplicate/near-identical audio exports by comparing
# every pair of mp3 (or wav/etc) files in a directory.
#
# For each pair, ffmpeg subtracts one channel from the other and measures the
# volume of the *difference* signal:
#   - Very quiet difference (mean_volume around -60 dB or below, ideally -80/-90)
#     => the two files are effectively identical (this is the MS4 bug you hit).
#   - Loud difference (mean_volume in the -10 to -30 dB range, i.e. close to the
#     original tracks' own loudness) => the two files are genuinely different
#     audio (this is what correctly separated parts should look like).
#
# Usage:
#   ./pairwise_diff.sh /path/to/directory
#
# Requires: ffmpeg on PATH.

set -euo pipefail

DIR="${1:?Usage: $0 <directory-with-audio-files>}"

FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done < <(find "$DIR" -maxdepth 1 -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.m4a" \) | sort)

if [ "${#FILES[@]}" -lt 2 ]; then
  echo "Need at least 2 audio files in $DIR" >&2
  exit 1
fi

labels=()
for f in "${FILES[@]}"; do
  labels+=("$(basename "$f")")
done

echo "Files being compared:"
for i in "${!FILES[@]}"; do
  printf "  [%d] %s\n" "$i" "${labels[$i]}"
done
echo
echo "Pairwise difference-signal mean_volume (dB). Values <= -60 dB suggest"
echo "near-identical/duplicate content; values > -40 dB suggest genuinely"
echo "different audio."
echo

# Header row
printf "%-4s" ""
for i in "${!FILES[@]}"; do
  printf "%8s" "[$i]"
done
echo

for i in "${!FILES[@]}"; do
  printf "%-4s" "[$i]"
  for j in "${!FILES[@]}"; do
    if [ "$i" -eq "$j" ]; then
      printf "%8s" "--"
      continue
    fi
    if [ "$j" -lt "$i" ]; then
      printf "%8s" "\""
      continue
    fi
    result=$(ffmpeg -hide_banner -i "${FILES[$i]}" -i "${FILES[$j]}" -filter_complex \
      "[0:a]aformat=channel_layouts=mono[a0];[1:a]aformat=channel_layouts=mono[a1];[a0][a1]amerge=inputs=2,pan=1c|c0=c0-c1,volumedetect" -f null - 2>&1 \
      | grep "mean_volume" | grep -oE '[-0-9.]+ dB' | head -1 | awk '{print $1}')
    printf "%8s" "${result:-N/A}"
  done
  echo
done
