#!/bin/bash
# mp3stats.sh — one-line loudness/dynamics summary per audio file.
# Usage: ./mp3stats.sh [-t | -m] <dir-or-file> [<dir-or-file> ...]   (default: current directory)
#   -t   tab-separated output with full, untruncated names (paste into Numbers/Excel,
#        or redirect to a .tsv file)
#   -m   Markdown table (full names)
#   (default is a space-padded table for the terminal; long names are shortened)
#   A directory is scanned (top level only) for mp3/m4a/wav/flac files.
#   Files are processed as given, so copies with the same name in different
#   places can be compared (the name column then shows the end of the path).
# Needs: ffmpeg + ffprobe (brew install ffmpeg). Works on macOS and Linux.
#
# Columns:
#   dur    duration m:ss
#   bytes  file size
#   LUFS   integrated loudness (EBU R128)
#   LRA    loudness range in LU (bigger = more dynamic)
#   TP     true peak in dBFS (above about -1 is hot; above 0 means overshoot on decode)
#   crest  sample peak minus overall RMS in dB (bigger = more dynamic/peaky)
#   flag   "!" if TP > -1 dBFS

fmt=pad
case "$1" in
  -t) fmt=tsv; shift ;;
  -m) fmt=md;  shift ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
esac
[ $# -eq 0 ] && set -- .

# Emit "D<TAB>path" for files found in a directory, "F<TAB>path" for files given directly.
list_files() {
  for a in "$@"; do
    if [ -d "$a" ]; then
      find -L "$a" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' -o -iname '*.flac' \) |
        sort | while IFS= read -r p; do printf 'D\t%s\n' "$p"; done
    elif [ -f "$a" ]; then
      printf 'F\t%s\n' "$a"
    else
      echo "mp3stats: skipping '$a' (not a file or directory)" >&2
    fi
  done
}

case "$fmt" in
  pad) printf "%-44s %6s %10s %7s %5s %6s %6s  %s\n" name dur bytes LUFS LRA TP crest flag ;;
  tsv) printf "name\tdur\tbytes\tLUFS\tLRA\tTP\tcrest\tflag\n" ;;
  md)  printf "| name | dur | bytes | LUFS | LRA | TP | crest | flag |\n|---|--:|--:|--:|--:|--:|--:|:-:|\n" ;;
esac

list_files "$@" | while IFS=$'\t' read -r kind f; do
  secs=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" </dev/null)
  bytes=$(wc -c < "$f" | tr -d ' ')
  out=$(ffmpeg -nostdin -hide_banner -nostats -i "$f" -af "ebur128=peak=true,astats=metadata=0" -f null - 2>&1)

  lufs=$(printf '%s\n' "$out" | awk '/Integrated loudness:/{getline; print $2}' | tail -1)
  lra=$( printf '%s\n' "$out" | awk '/Loudness range:/{getline; print $2}' | tail -1)
  tp=$(  printf '%s\n' "$out" | awk '/True peak:/{getline; print $2}' | tail -1)
  # astats prints per-channel blocks, then an "Overall" block; take the last of each
  pk=$(  printf '%s\n' "$out" | awk '/Peak level dB:/{v=$NF} END{print v}')
  rms=$( printf '%s\n' "$out" | awk '/RMS level dB:/{v=$NF} END{print v}')

  if [ "$kind" = D ]; then name=$(basename "$f"); else name="$f"; fi
  # Padded mode only: shorten long names (directory mode keeps the start,
  # file mode keeps the end, where the folder differs)
  if [ "$fmt" = pad ] && [ ${#name} -gt 44 ]; then
    if [ "$kind" = D ]; then name="${name:0:43}~"; else name="~${name: -43}"; fi
  fi

  awk -v fmt="$fmt" -v n="$name" -v s="$secs" -v b="$bytes" -v l="$lufs" -v r="$lra" -v t="$tp" -v p="$pk" -v m="$rms" 'BEGIN{
    d=int(s+0.5); flag=(t+0 > -1) ? "!" : ""
    dur=sprintf("%d:%02d", d/60, d%60)
    if (fmt=="tsv")      printf "%s\t%s\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%s\n", n, dur, b, l, r, t, p-m, flag
    else if (fmt=="md")  { gsub(/\|/, "\\|", n); printf "| %s | %s | %d | %.1f | %.1f | %.1f | %.1f | %s |\n", n, dur, b, l, r, t, p-m, flag }
    else                 printf "%-44s %6s %10d %7.1f %5.1f %6.1f %6.1f  %s\n", n, dur, b, l, r, t, p-m, flag
  }'
done
