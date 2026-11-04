class_name ReleaseUpdate
extends Node

## Check for Updates from the game's public releases on GitHub: asks for the
## latest release, and if it's newer than this copy, downloads this
## computer's version of it, checks it against the release's SHA256SUMS.txt
## and installs it (the same way an update from a friend installs: Updater).
##
## Mac: PiratesPlunder-mac.zip (the app, zipped). Windows:
## PiratesPlunder-windows.exe. Anything else (Linux, the web version), or a
## release without this computer's file, gets the release page to open
## instead.
##
## Only ever reads: no account, no key. GitHub's API allows 60 questions an
## hour from one internet address, which a shared connection can use up; then
## it asks the releases page instead, which only says the latest version (by
## where it redirects to), and fetches the files by their usual addresses.

signal checked(result: Dictionary)
signal progress(done: int, total: int)
signal failed(reason: String)
## Downloaded and checked; installing (or, in a dry run, done).
signal installing(message: String)
## Downloaded and checked, at `path` (before installing, if it installs).
signal downloaded(path: String)

const REPO := "sparkly-quasar/Pirates-Plunder"
const API := "https://api.github.com/repos/" + REPO + "/releases/latest"
const PAGE := "https://github.com/" + REPO + "/releases/latest"
const DOWNLOADS := "https://github.com/" + REPO + "/releases/download/"
const SUMS := "SHA256SUMS.txt"
const MAC_FILE := "PiratesPlunder-mac.zip"
const WIN_FILE := "PiratesPlunder-windows.exe"
const SERVER_FILE := "PiratesPlunder-server-linux.tar.gz"

## Tests point these elsewhere (a local server) and stop before installing.
var api_url := API
var page_url := PAGE
var download_base := DOWNLOADS
var platform_override := ""
var dry_run := false
## The dedicated server fetches its own package instead (SERVER_FILE), into
## a folder of its own, and unpacks it itself (install = false).
var file_override := ""
var work_dir := ""
var install := true

var _req: HTTPRequest = null
var _job := ""         # "", "check", "page", "sums", "file"
var _release := {}     # the result of the last check
var _file := ""        # the file being downloaded
var _sha := ""         # what it must hash to

func _ready() -> void:
	_req = HTTPRequest.new()
	_req.use_threads = true
	_req.timeout = 0.0
	_req.max_redirects = 8
	_req.download_chunk_size = 1 << 16
	_req.request_completed.connect(_on_done)
	add_child(_req)

func busy() -> bool:
	return _job != ""

func _platform() -> String:
	return platform_override if platform_override != "" else Updater.platform()

## The file this computer installs from a release, or "" if it can't
## install one by itself.
static func file_for(os_name: String) -> String:
	match os_name:
		"macOS": return MAC_FILE
		"Windows": return WIN_FILE
	return ""

func _headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: PiratesPlunder/" + GameConfig.version(), "Accept: application/vnd.github+json"])

## Asks for the latest release. `checked` answers with parse_release()'s
## result, or {kind: "error", text} if GitHub couldn't be reached.
func check() -> void:
	if busy():
		return
	_job = "check"
	_req.timeout = 20.0
	_req.download_file = ""
	var err := _req.request(api_url, _headers())
	if err != OK:
		_job = ""
		checked.emit({"kind": "error", "text": "Couldn't ask GitHub for the latest version."})

## What a release (GitHub's JSON for it) means for this copy: {kind:
## "newer"/"current"/"error", version, page, files ({name: url}), text}.
static func parse_release(data: Variant, mine: String) -> Dictionary:
	if not data is Dictionary or not (data as Dictionary).has("tag_name"):
		return {"kind": "error", "text": "GitHub's answer didn't make sense."}
	var d := data as Dictionary
	var version := str(d.tag_name).trim_prefix("v")
	var files := {}
	for a in d.get("assets", []):
		if a is Dictionary and a.has("name") and a.has("browser_download_url"):
			files[str(a.name)] = str(a.browser_download_url)
	var out := {"version": version, "page": str(d.get("html_url", PAGE)), "files": files}
	if version == "" or not version.left(1).is_valid_int():
		out.kind = "error"
		out.text = "GitHub's answer didn't make sense."
	elif Updater.compare(version, mine) > 0:
		out.kind = "newer"
		out.text = "Version %s is out (you have %s)." % [version, mine]
	else:
		out.kind = "current"
		out.text = "You have the latest version (%s)." % mine
	return out

## Whether `result` (a "newer" check) can be installed here by itself.
func can_install(result: Dictionary) -> bool:
	var name := _wanted()
	return name != "" and result.get("files", {}).has(name) and result.get("files", {}).has(SUMS)

## Downloads this computer's file from the release `result` (a "newer"
## check), checks it, and installs it.
func download(result: Dictionary) -> void:
	if busy():
		return
	if not can_install(result):
		failed.emit("This computer's version isn't in that release. Download it from the releases page.")
		return
	_release = result
	_file = _wanted()
	_job = "sums"
	_req.timeout = 30.0
	_req.download_file = ""
	if _req.request(str(result.files[SUMS]), _headers()) != OK:
		_job = ""
		failed.emit("Couldn't start the download.")

## The SHA-256 a SHA256SUMS.txt gives for `name` ("" if none).
static func sum_for(sums: String, name: String) -> String:
	for line in sums.split("\n"):
		var parts := line.strip_edges().split(" ", false)
		if parts.size() >= 2 and parts[parts.size() - 1].trim_prefix("*") == name and parts[0].length() == 64:
			return parts[0].to_lower()
	return ""

## The API couldn't answer (say, its hourly limit for this address): ask the
## releases page, without following its redirect, which names the latest tag.
func _ask_page(_why_not: String) -> void:
	_job = "page"
	_req.max_redirects = 0
	_req.timeout = 20.0
	_req.download_file = ""
	if _req.request(page_url, _headers()) != OK:
		_job = ""
		_req.max_redirects = 8
		checked.emit({"kind": "error", "text": "Couldn't ask GitHub for the latest version."})

## The tag a releases/latest redirect points to ("v0.15.1"), or "".
static func tag_from_headers(headers: PackedStringArray) -> String:
	for h in headers:
		if h.to_lower().begins_with("location:"):
			var to := h.substr(9).strip_edges()
			var at := to.find("/releases/tag/")
			if at >= 0:
				return to.substr(at + "/releases/tag/".length()).get_slice("?", 0).get_slice("/", 0).uri_decode()
	return ""

## A release known only by its tag: its files at their usual addresses.
static func release_at(tag: String, base: String, page: String, mine: String) -> Dictionary:
	var files := {}
	for name in [MAC_FILE, WIN_FILE, SERVER_FILE, SUMS]:
		files[name] = base + tag + "/" + name
	return parse_release({"tag_name": tag, "html_url": page.replace("/latest", "/tag/" + tag),
		"assets": files.keys().map(func(n: String) -> Dictionary: return {"name": n, "browser_download_url": files[n]})}, mine)

func _wanted() -> String:
	return file_override if file_override != "" else file_for(_platform())

func work_path() -> String:
	return (work_dir if work_dir != "" else Updater.WORK_DIR).path_join(_file)

func _process(_delta: float) -> void:
	if _job == "file":
		progress.emit(_req.get_downloaded_bytes(), _req.get_body_size())

func _on_done(result: int, code: int, got_headers: PackedStringArray, body: PackedByteArray) -> void:
	var job := _job
	_job = ""
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	match job:
		"check":
			var found := parse_release(JSON.parse_string(body.get_string_from_utf8()), GameConfig.version()) if ok else {}
			if not ok or found.kind == "error":
				_ask_page("%s" % (_why(result, code) if not ok else "a strange answer"))
				return
			checked.emit(found)
		"page":
			_req.max_redirects = 8
			var tag := tag_from_headers(got_headers)
			if tag == "":
				var why := "it didn't say which version" if code >= 300 and code < 400 else _why(result, code)
				checked.emit({"kind": "error", "text": "Couldn't reach GitHub to check (%s)." % why})
				return
			checked.emit(release_at(tag, download_base, page_url, GameConfig.version()))
		"sums":
			if not ok:
				failed.emit("Couldn't download the release's fingerprints (%s)." % _why(result, code))
				return
			_sha = sum_for(body.get_string_from_utf8(), _file)
			if _sha == "":
				failed.emit("That release has no %s to check and install, so download it from the releases page." % _file)
				return
			DirAccess.make_dir_recursive_absolute(work_path().get_base_dir())
			DirAccess.remove_absolute(work_path())
			_req.download_file = work_path()
			_req.timeout = 0.0 # a big file on a slow line takes as long as it takes
			_job = "file"
			if _req.request(str(_release.files[_file]), _headers()) != OK:
				_job = ""
				failed.emit("Couldn't start the download.")
		"file":
			_req.download_file = ""
			if not ok:
				DirAccess.remove_absolute(work_path())
				failed.emit("The download didn't finish (%s)." % _why(result, code))
				return
			if FileAccess.get_sha256(work_path()) != _sha:
				DirAccess.remove_absolute(work_path())
				failed.emit("The download didn't match the release's fingerprint, so it wasn't installed. Try again.")
				return
			downloaded.emit(work_path())
			if dry_run:
				installing.emit("Downloaded and checked.")
				return
			if install:
				Net.updater.install_files([_file], str(_release.version))

static func _why(result: int, code: int) -> String:
	if result != HTTPRequest.RESULT_SUCCESS:
		return {HTTPRequest.RESULT_CANT_CONNECT: "no connection", HTTPRequest.RESULT_CANT_RESOLVE: "no internet",
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "a secure connection failed", HTTPRequest.RESULT_TIMEOUT: "it timed out"}.get(result, "error %d" % result)
	return "HTTP %d" % code
