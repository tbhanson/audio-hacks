# audio-hacks

Small scripts for music/audio production tasks. Not a polished toolkit --
working scripts kept together because they're likely to get reused or
adapted.

## musescore-rehearsal-export/

Generates one rehearsal MP3 per voice from a MuseScore SATB choir score:
the featured voice loud, the others quiet, for one-voice-at-a-time practice.

- `rehearsal-export-ms4-buggy.rkt` -- the straightforward version. Edits a
  MuseScore 4 `.mscx`'s per-instrument `<Channel>` volume (MIDI CC7) and
  exports via the MS4 CLI. **Kept for reference / documentation, not
  actual use** -- MuseScore 4.7.x has a regression where per-channel mixer
  state (mute, solo, and apparently plain volume) isn't honored during
  audio export, so every voice comes out sounding identical ("tutti").
  Confirmed with `pairwise_diff.sh` (see below).

- `rehearsal-export-ms3-workaround.rkt` -- the working version. Round-trips
  the score through MuseScore 3.6.2 (MusicXML export from MS4, import +
  re-save in MS3), applies the same volume edit to the MS3-format `.mscx`,
  and exports via the MS3 CLI, which still respects per-channel volume.

  Before trusting a full batch run on a new score, check the sample
  `<Channel>` block the script prints against what you expect -- the MS3
  XML shape hasn't been independently verified beyond the one score this
  was built against.

## audio-diagnostics/

- `pairwise_diff.sh` -- for a directory of audio files, computes a
  pairwise difference signal (ffmpeg, downmixed to mono first) and reports
  its mean volume in dB for every pair. Values <= -60 dB mean the two
  files are essentially identical; > -40 dB means they genuinely differ.
  Originally built to prove the MS4 export bug above by showing all pairs
  clustering near -53 to -54 dB (identical) vs. -13 to -19 dB for a
  correctly-separated MS3 export.

- `mp3stats.sh` -- for a directory of audio files (mp3, m4a, wav, flac),
  prints one summary line per file: duration, integrated loudness (LUFS),
  loudness range (LRA), true peak (dBFS) and crest factor (peak minus RMS,
  in dB). One ffmpeg pass per file. Files with a true peak above -1 dBFS
  are flagged with `!`; a true peak above 0 means the decoded MP3 overshoots
  full scale. Useful for a quick check for clipping and loudness differences
  across versions of a piece.

  Usage:
  ```
  ./pairwise_diff.sh <directory-of-mp3s>
  ```

## Related

- [audio-catalog](https://github.com/tbhanson/audio-catalog): catalogs
  audio files into SQLite (size, duration, tags) and estimates speech,
  music, noise and silence per file. Lives in its own repo because it is
  a multi-module program, not a single script.
