extends SceneTree

## Drives ReleaseUpdate against a stand-in for GitHub (tools/release_update_test.sh
## runs it): -- --api=<url> [--page=<url> --base=<url>] --platform=macOS|Windows
## --expect=ok|bad.
## Prints RELEASE_RESULT: PASS or FAIL.

func _initialize() -> void:
	_run.call_deferred()

func _arg(name: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.split("=", true, 1)[1]
	return ""

func _run() -> void:
	var RU: Script = load("res://scripts/release_update.gd")
	var ru: Node = RU.new()
	ru.set("api_url", _arg("api"))
	if _arg("page") != "":
		ru.set("page_url", _arg("page"))
		ru.set("download_base", _arg("base"))
	ru.set("platform_override", _arg("platform"))
	ru.set("dry_run", true)
	root.add_child(ru)
	await process_frame
	ru.call("check")
	var found: Dictionary = await ru.checked
	print("checked: ", found.get("kind"), " ", found.get("text"))
	if str(found.get("kind")) != "newer" or not ru.call("can_install", found):
		print("RELEASE_RESULT: FAIL (no installable newer release)")
		quit(1)
		return
	var done := {"msg": "", "fail": "", "progress": 0}
	ru.connect("installing", func(m: String) -> void: done.msg = m)
	ru.connect("failed", func(m: String) -> void: done.fail = m)
	ru.connect("progress", func(d: int, _t: int) -> void: done.progress = maxi(int(done.progress), d))
	ru.call("download", found)
	var waited := 0.0
	while done.msg == "" and done.fail == "" and waited < float(_arg("wait") if _arg("wait") != "" else "60"):
		await process_frame
		waited += 1.0 / 60.0
	print("installing: '%s'  failed: '%s'  progress seen: %d" % [done.msg, done.fail, done.progress])
	var path := ProjectSettings.globalize_path(str(ru.call("work_path")))
	var ok := false
	if _arg("expect") == "ok":
		ok = done.msg == "Downloaded and checked." and FileAccess.file_exists(path)
	else:
		ok = done.fail.contains("didn't match") and not FileAccess.file_exists(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	print("RELEASE_RESULT: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
