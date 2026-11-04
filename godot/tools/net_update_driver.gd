extends Node
# Drives one side of the version tests in tools/NetTest.tscn. See net_test.gd.
#   update-host   hosts, and serves two test files as its "game" for a Mac
#   update-guest  (run with --pretend-version=0.0.1) sees the newer host,
#                 downloads the files and checks every byte
#   legacy-guest  says no hello, like a copy from before 0.6.1, and must
#                 still be let in on the old handshake
#   update-host-real  hosts for a real exported app (posing as an older
#                 version) to download the real Mac build from dist/ (run
#                 tools/package.sh first), install it over itself, restart
#                 and rejoin:
#     godot --headless --path . res://tools/NetTest.tscn -- --role=update-host-real
#     <copy of the app>/Contents/MacOS/Pirates\ Plunder -- --pretend-version=0.6.0 \
#         --join=127.0.0.1:24699 --accept-update
# Not shipped.

const PORT := 24699
const SRC_DIR := "user://update_test_src"

var role := "update-host"
var failures := 0

func _ready() -> void:
	get_tree().create_timer(300.0 if role == "update-host-real" else 60.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	match role:
		"update-host": await _host()
		"update-guest": await _guest()
		"legacy-guest": await _legacy_guest()
		"update-host-real": await _host_real()

## Two files of random bytes, one bigger than a chunk many times over.
func _make_files() -> Array:
	DirAccess.make_dir_recursive_absolute(SRC_DIR)
	var paths := []
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for spec in [["game-part-a.bin", 1500000], ["game-part-b.bin", 70001]]:
		var bytes := PackedByteArray()
		bytes.resize(int(spec[1]))
		for i in bytes.size():
			bytes[i] = rng.randi() & 255
		var path := SRC_DIR.path_join(spec[0])
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
		paths.append(path)
	return paths

func _host() -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.HOST
	Net.updater.test_files = {Updater.platform(): _make_files()}
	_check(Net.host_game(PORT) == OK, "host: listening")
	var differ := []
	Net.updater.versions_differ.connect(func(_p: int, v: String, newer: bool, _c: bool) -> void: differ.append([v, newer]))
	var admitted := [0]
	Net.guest_connected.connect(func() -> void: admitted[0] += 1)
	var served := [0]
	Net.updater.serving_progress.connect(func(_p: int, done: int, total: int) -> void:
		if done >= total: served[0] += 1)
	# First the guest posing as an old version downloads, and must get no seat.
	await _until(func() -> bool: return served[0] > 0)
	_check(differ.size() == 1 and differ[0][0] == "0.0.1" and not differ[0][1],
		"host: saw a friend with the older version 0.0.1")
	_check(admitted[0] == 0, "host: no crew for a friend on another version")
	await _until(func() -> bool: return multiplayer.get_peers().is_empty())
	# Then a copy that never says hello is let in the old way, after a wait.
	await _until(func() -> bool: return admitted[0] > 0)
	_check(admitted[0] == 1, "host: a copy that says no hello still gets a crew")
	await _until(func() -> bool: return multiplayer.get_peers().is_empty())
	_finish(failures == 0)

func _host_real() -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.HOST
	_check(FileAccess.file_exists(Updater.BUNDLED_MAC), "host: the Mac build is in dist/")
	_check(Net.host_game(PORT) == OK, "host: listening")
	var admitted := [0]
	Net.guest_connected.connect(func() -> void: admitted[0] += 1)
	var served := [false]
	Net.updater.serving_progress.connect(func(_p: int, done: int, total: int) -> void:
		if done >= total: served[0] = true)
	await _until(func() -> bool: return served[0])
	_check(admitted[0] == 0, "host: sent the whole Mac build to the older copy, without seating it")
	await _until(func() -> bool: return admitted[0] > 0)
	_check(true, "host: the updated copy restarted and rejoined on the same version")
	_finish(failures == 0)

func _guest() -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	Net.updater.dry_run = true
	_check(GameConfig.version() == "0.0.1", "guest: posing as version 0.0.1")
	var offers := []
	Net.updater.versions_differ.connect(func(p: int, v: String, newer: bool, can_get: bool) -> void:
		offers.append([v, newer, can_get])
		if newer and can_get:
			Net.updater.download_from(p))
	var done := [""]
	Net.updater.installing.connect(func(m: String) -> void: done[0] = m)
	Net.updater.download_failed.connect(func(m: String) -> void: done[0] = "FAILED " + m)
	var joined := [false]
	Net.joined.connect(func() -> void: joined[0] = true)
	await get_tree().create_timer(0.5).timeout
	_check(Net.join_game("127.0.0.1:%d" % PORT) == OK, "guest: connecting")
	await _until(func() -> bool: return done[0] != "")
	_check(offers.size() == 1 and offers[0][1] and offers[0][2],
		"guest: offered the host's newer version (%s)" % [offers])
	_check(done[0] == "Downloaded.", "guest: download finished (%s)" % done[0])
	var same := true
	for name in ["game-part-a.bin", "game-part-b.bin"]:
		var a := FileAccess.get_file_as_bytes(SRC_DIR.path_join(name))
		var b := FileAccess.get_file_as_bytes(Updater.WORK_DIR.path_join(name))
		same = same and a.size() > 0 and a == b
	_check(same, "guest: both files arrived byte for byte")
	_check(not joined[0], "guest: no game joined on the wrong version")
	_finish(failures == 0)

func _legacy_guest() -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	Net.updater.silent = true
	var joined := [false]
	Net.joined.connect(func() -> void: joined[0] = true)
	await get_tree().create_timer(0.5).timeout
	_check(Net.join_game("127.0.0.1:%d" % PORT) == OK, "legacy guest: connecting")
	await _until(func() -> bool: return joined[0])
	_check(joined[0], "legacy guest: welcomed on the old handshake")
	_finish(failures == 0)

func _until(cond: Callable) -> void:
	while not cond.call():
		await get_tree().process_frame

func _check(cond: bool, label: String) -> void:
	if not cond:
		failures += 1
	print(("  [PASS] " if cond else "  [FAIL] "), label)

func _finish(ok: bool) -> void:
	print("NET_RESULT %s: %s" % [role, "ALL PASS" if ok else "FAIL"])
	Net.leave_and_quit(0 if ok else 1)
