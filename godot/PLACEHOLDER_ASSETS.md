# Placeholder assets — READ BEFORE RELEASE

Every sound in `assets/audio/sfx/` was extracted from the original 1996 game
**Richard Carr's Treasure Island**. These files are **copyrighted by their
original authors**. They are used here only as *placeholders* so we can build
and feel out the game.

**Before selling Pirates Plunder, replace them with original or properly
licensed audio.** The owner chose (2026-11-03) to publish the free game with
these clips as an homage, credited in the README with an offer to remove them
at the rights holder's request. That note doesn't grant permission: if asked,
remove them promptly (one file, `scripts/audio_manifest.gd`).

## How to swap them
All playback goes through one file: `scripts/audio_manifest.gd`. It maps game
events (DIG, PICKUP, WIN, …) to file paths. To re-skin the audio:

1. Drop your new files into `assets/audio/sfx/` (or `music/`).
2. Point the constants in `audio_manifest.gd` at the new paths.

Nothing else in the code names a sound file, so that one edit changes the whole
game's audio.

## Re-extracted placeholders
The first extraction (from `SetupTi.exe`, whose InstallShield 3 archive spans
four "disk" volumes) got the join wrong for the 3 files split across two
volumes. Everything after the split point came out as garbage:
`TCWantMe.wav` from 1.36 s (heard as a distorted, buzzing ending),
`NextTime.WAV` from about 0.8 s, and the original `Treasure.exe`. On
2026-10-31 the two sounds were re-extracted with an independent PKWARE DCL
decoder (a port of zlib's `blast.c`) that joins volumes correctly. The result
is identical whether taken from `SetupTi.exe` or the other installer,
`TREASURE.EXE`, a slightly earlier release. The other 38 sounds came out
byte-identical to the first extraction.

`Crawling.WAV` and `Digging.WAV` shipped in 1996 with a broken trailing
metadata note: a LIST/INFO "recording date" section (1996-05-13 and 1996-05-25)
with a garbage length field, which made Godot warn on import. The game's copies
have that 32-byte note removed. Their sound data is byte-identical to the
originals in `../../audio/`, which are left as they shipped.

## The higher voice (`assets/audio/sfx/voice_high/`)
The four lines a sailor speaks (`Treasure.WAV`, `AyeCapt.WAV`, `TCWantMe.wav`,
`TC_trans.wav`) also come in a higher voice, for sailors whose Voice is set to
Higher (Vega's is, from the start). They are derived from the placeholders
above, so the same rule applies to them. Made 2026-11-05 with ffmpeg 6's
rubberband filter: pitch up 1.5x (about 7 semitones) with formants held, then a
1.17x resample with tempo put back, which raises pitch and formants together.
Net effect: pitch x1.5, formants x1.17, length unchanged. The originals sit
around 130-150 Hz; the higher ones around 185-215 Hz.

```
ffmpeg -i IN -af "rubberband=pitch=1.2821:formant=preserved:pitchq=quality,asetrate=22050*1.17,aresample=22050,atempo=1/1.17" -c:a pcm_s16le -ar 22050 -ac 1 voice_high/IN
```

When the placeholders are replaced, record the higher lines with a real voice
actor rather than re-deriving them.

## Music
The original 11 `.mid` music tracks are **not** wired in yet — Godot can't play
MIDI natively. Milestone 2 adds a render step (fluidsynth + a free soundfont →
OGG). Those renders will be placeholders too, subject to the same rule above.
