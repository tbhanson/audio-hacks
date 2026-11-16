#!/bin/bash
# mp3stats.sh — one-line loudness/dynamics summary per audio file in a directory.
# Usage: ./mp3stats.sh [dir]   (default: current directory)
# Needs: ffmpeg + ffprobe (brew install ffmpeg). Works on macOS and Linux.
#
# Columns:
#   dur    duration m:ss
#   LUFS   integrated loudness (EBU R128)
#   LRA    loudness range in LU (bigger = more dynamic)
#   TP     true peak in dBFS (above about -1 is hot; above 0 means overshoot on decode)
#   crest  sample peak minus overall RMS in dB (bigger = more dynamic/peaky)
#   flag   "!" if TP > -1 dBFS

dir="${1:-.}"
printf "%-44s %6s %7s %5s %6s %6s  %s\n" name dur LUFS LRA TP crest flag

find -L "$dir" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' -o -iname '*.flac' \) | sort |
while IFS= read -r f; do
  secs=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" </dev/null)
  out=$(ffmpeg -nostdin -hide_banner -nostats -i "$f" -af "ebur128=peak=true,astats=metadata=0" -f null - 2>&1)

  lufs=$(printf '%s\n' "$out" | awk '/Integrated loudness:/{getline; print $2}' | tail -1)
  lra=$( printf '%s\n' "$out" | awk '/Loudness range:/{getline; print $2}' | tail -1)
  tp=$(  printf '%s\n' "$out" | awk '/True peak:/{getline; print $2}' | tail -1)
  # astats prints per-channel blocks, then an "Overall" block; take the last of each
  pk=$(  printf '%s\n' "$out" | awk '/Peak level dB:/{v=$NF} END{print v}')
  rms=$( printf '%s\n' "$out" | awk '/RMS level dB:/{v=$NF} END{print v}')

  awk -v n="$(basename "$f")" -v s="$secs" -v l="$lufs" -v r="$lra" -v t="$tp" -v p="$pk" -v m="$rms" 'BEGIN{
    if (length(n)>44) n=substr(n,1,43) "~"
    d=int(s+0.5); flag=(t+0 > -1) ? "!" : ""
    printf "%-44s %3d:%02d %7.1f %5.1f %6.1f %6.1f  %s\n", n, d/60, d%60, l, r, t, p-m, flag
  }'
done
