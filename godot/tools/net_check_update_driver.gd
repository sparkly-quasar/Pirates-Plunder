extends Node
# Drives the Play on a Server screen's Check for Updates button against the
# real server (tools/check_update_test.sh starts the server, with stand-in
# downloads for its version, and then these one after another). Not shipped.
#
#   check-old    posing as 0.0.1: Check for Updates finds the server's newer
#                version, connects only to fetch it, and downloads it
#                (a dry run: nothing is installed), without taking a seat.
#   check-same   on the server's version: told it's up to date, and never
#                connects.
#   check-newer  posing as 99.0.0: told it's up to date, and that the
#                server is older.
# Updating from a server is for Mac and Windows copies; on Linux check-old
# expects to be told the server has nothing for this computer.

const ADDRESS := "127.0.0.1:24677"

var role := "check-old"
var failures := 0
var browser: Control

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish())
	Net.updater.dry_run = true
	browser = load("res://scenes/ServerBrowser.tscn").instantiate()
	browser.set("scan_tailnet", false) # only the test server, not this computer's real one
	get_tree().root.add_child(browser)
	await get_tree().process_frame
	browser.address_edit.text = ADDRESS
	browser.call("_look_up")
	var waited := 0.0
	while browser.finder.servers().is_empty() and waited < 10.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	_check(not browser.finder.servers().is_empty(), "%s: the server list finds the test server" % role)
	_press("Check for Updates")
	match role:
		"check-old":
			await _old()
		"check-same":
			await _same()
		_:
			await _newer()
	_finish()

func _old() -> void:
	var mac_or_win := Updater.platform() in ["macOS", "Windows"]
	var waited := 0.0
	while waited < 30.0 and browser.update_label.text != "Downloaded." \
			and not browser.update_label.text.contains("can't send one"):
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	if not mac_or_win:
		_check(browser.update_label.text.contains("can't send one"), "check-old: on %s, told the server has nothing for this computer" % Updater.platform())
		return
	# The dry run stops at "Downloaded." where a real copy would install and restart.
	_check(browser.update_label.text == "Downloaded.", "check-old: Check for Updates downloads the server's version: %s" % browser.update_label.text)
	_check(Net.updater.incoming_version != "0.0.1" and Net.updater.incoming_version != "", "check-old: the version fetched is the server's (%s)" % Net.updater.incoming_version)
	_check(is_instance_valid(browser) and browser.is_inside_tree() and browser.get("_update_only") == true,
		"check-old: no seat was taken (still on the server list, only updating)")
	_check(Array(Net.updater.relaunch_extra).has("--browse=" + ADDRESS), "check-old: after restarting, the game comes back to this server's list")

func _same() -> void:
	await get_tree().create_timer(browser.CHECK_WAIT + 1.0).timeout
	var text: String = browser.status_label.text
	_check(text.begins_with("You're up to date: you have version %s" % GameConfig.version()), "check-same: told it's up to date: %s" % text)
	_check(Net.role == Net.Role.NONE, "check-same: and it never connected")

func _newer() -> void:
	await get_tree().create_timer(browser.CHECK_WAIT + 1.0).timeout
	var text: String = browser.status_label.text
	_check(text.begins_with("You're up to date") and text.contains("Older:"), "check-newer: up to date, and the server is older: %s" % text)
	_check(Net.role == Net.Role.NONE, "check-newer: and it never connected")

func _press(text: String) -> void:
	for b in browser.find_children("*", "Button", true, false):
		if (b as Button).text == text:
			(b as Button).pressed.emit()
			return
	_check(false, "%s: no button %s" % [role, text])

func _check(ok: bool, what: String) -> void:
	print("  [%s] %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _finish() -> void:
	print("NET_RESULT %s %s" % [role, "PASS" if failures == 0 else "FAIL"])
	Net.leave()
	get_tree().quit(0 if failures == 0 else 1)
