class_name AudioManifest
extends RefCounted

## The ONE place that maps a game event to an audio file.
##
## PLACEHOLDER ASSETS: every path below points at a sound extracted from the
## original 1996 "Richard Carr's Treasure Island", which is COPYRIGHTED. They
## are stand-ins so we can build and feel the game. Before any public release,
## swap them for original/licensed sounds — you only need to edit this file.
## See ../PLACEHOLDER_ASSETS.md.

const DIG := "res://assets/audio/sfx/Digging.WAV"
const TREASURE := "res://assets/audio/sfx/Treasure.WAV" # "Ahhh, treasure!" — digging one up
const WIN := "res://assets/audio/sfx/Win.WAV"
const WELCOME := "res://assets/audio/sfx/Welcome.wav"
const WALK := "res://assets/audio/sfx/Walking.WAV"

# Sword fights and the two-team game (M2). Names are the original files' own;
# which line each one speaks is a best guess until someone listens through them.
const SWORD := "res://assets/audio/sfx/SwordF.WAV"
const TIE := "res://assets/audio/sfx/Tie.wav"
const CAPTURED := "res://assets/audio/sfx/Lost.wav"
const YOUR_TURN := "res://assets/audio/sfx/AyeCapt.WAV"
const LOSE := "res://assets/audio/sfx/NextTime.WAV"

# Handing over a chest (by filename and length; nobody has listened yet):
# "You want me to carry the treasure?" ... "I'll carry it now."
const OFFER_CARRY := "res://assets/audio/sfx/TCWantMe.wav" # re-extracted clean: see PLACEHOLDER_ASSETS.md
const TAKE_CARRY := "res://assets/audio/sfx/TC_trans.wav"

# Coaching between games: did the session work? ("Successful" is heard only here.)
const COACH_SUCCESS := "res://assets/audio/sfx/Successf.WAV"
const COACH_FAIL := "res://assets/audio/sfx/CUnsucc.WAV"
