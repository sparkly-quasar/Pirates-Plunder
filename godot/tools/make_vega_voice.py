"""Makes Vega's higher voice (assets/audio/sfx/voice_high/) from the original
spoken lines, with Praat's Change Gender (pitch-synchronous, so it stays
smooth). Needs `pip install praat-parselmouth`. Run from godot/:

    python3 tools/make_vega_voice.py

Settings chosen by ear on 2026-11-05: a middle pitch of 230 Hz (265 for the
rising question in TCWantMe), formants raised 27%, intonation 18% wider.
"""
import os
import parselmouth
from parselmouth.praat import call

SFX = "assets/audio/sfx"
LINES = {"Treasure.WAV": 230, "AyeCapt.WAV": 230, "TCWantMe.wav": 265, "TC_trans.wav": 230}
FORMANT_SHIFT = 1.27
PITCH_RANGE = 1.18

os.makedirs(os.path.join(SFX, "voice_high"), exist_ok=True)
for name, target in LINES.items():
    snd = parselmouth.Sound(os.path.join(SFX, name))
    new = call(snd, "Change gender", 75, 400, FORMANT_SHIFT, target, PITCH_RANGE, 1.0)
    new = call(new, "Resample", 22050, 50)
    if call(new, "Get absolute extremum", 0, 0, "None") > 0.98:
        call(new, "Scale peak", 0.98)
    new.save(os.path.join(SFX, "voice_high", name), "WAV")
    print("made voice_high/" + name)
