extends Node

## Autoload. The only thing that actually plays sound. Everything else calls
## AudioManager.play(AudioManifest.SOMETHING). Because paths only ever come from
## AudioManifest, re-skinning the whole game's audio is a one-file change.
##
## Uses a small pool of players so overlapping effects don't cut each other off,
## and fails soft (a warning, not a crash) if a file is missing.

const POOL_SIZE := 8
const SETTINGS_PATH := "user://settings.cfg"

var _cache := {}
var _players: Array[AudioStreamPlayer] = []
## 0..1, the game's overall loudness; set from the in-game menu and remembered.
var volume := 0.8
## Off on a dedicated server: nobody's listening, and its copy of the game may
## leave the (placeholder) sounds out altogether.
var enabled := true

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # menu clicks still sound while paused
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		volume = clampf(float(cfg.get_value("audio", "volume", volume)), 0.0, 1.0)
	_apply_volume()

func set_volume(value: float) -> void:
	volume = clampf(value, 0.0, 1.0)
	_apply_volume()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("audio", "volume", volume)
	cfg.save(SETTINGS_PATH)

func _apply_volume() -> void:
	AudioServer.set_bus_mute(0, volume <= 0.001)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.001)))

func play(path: String, volume_db := 0.0) -> void:
	if not enabled:
		return
	var stream := _stream_for(path)
	if stream == null:
		return
	var player := _available_player()
	player.stream = stream
	player.volume_db = volume_db
	player.play()

func _stream_for(path: String) -> AudioStream:
	if _cache.has(path):
		return _cache[path]
	var stream: AudioStream = null
	if ResourceLoader.exists(path):
		stream = load(path)
	else:
		push_warning("AudioManager: missing audio resource '%s'" % path)
	_cache[path] = stream
	return stream

func _available_player() -> AudioStreamPlayer:
	for p in _players:
		if not p.playing:
			return p
	return _players[0] # all busy — reuse the oldest
