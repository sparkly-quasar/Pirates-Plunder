extends Node

## Autoload. Carries the choices made before the expedition into it: how we're
## playing, which island, and what each team is made of. Kept tiny and plain so
## the host can send exactly this across the wire and both players end up on
## the same island with the same rosters.

enum Mode {
	SOLO,    ## practice: the NAVS alone on the island, no pirates
	HOTSEAT, ## two to four crews taking turns at one computer
	HOST,    ## NAVS, running the game for up to three friends who join over the network
	GUEST,   ## one of the other crews, playing on a friend's hosted game
	COMPUTER, ## single player: the NAVS against one to three computer-controlled crews
	SERVER,  ## a dedicated server: no crew of its own, every crew a player online or the computer
}

## Who sails each crew. HUMAN is someone at this computer (the host, the single
## player, or one of the players sharing a computer); FRIEND is someone who
## joins over the network; COMPUTER is a ComputerPlayer. What's stored is only
## the choice "a person or the computer"; ctrl_of() works out the rest from how
## we're playing.
enum Ctrl { HUMAN, COMPUTER, FRIEND }
const MIN_TEAMS := 2
const MAX_TEAMS := 4

## How hard the computer's pirates play (single player only).
enum Difficulty { EASY, NORMAL, HARD }
const DIFFICULTY_NAMES := ["Easy", "Normal", "Hard"]

const DEFAULT_TEAM_SIZE := 10
## The most people a crew can have (the original sailed 14 and grew from there).
const MAX_TEAM_SIZE := 16
## `partner` when every crew plays for itself.
const FREE_FOR_ALL := -1

## Navigator surnames, handed out in order — the NAVS are "navigators".
const NAV_NAMES := [
	"Bering", "Hudson", "Drake", "Cook", "Magellan", "Cabot", "Tasman",
	"Frobisher", "Baffin", "Dias", "Cartier", "Vespucci",
	"Bougainville", "Vancouver", "Flinders", "Shackleton", "La Salle", "Champlain",
]
const PIRATE_NAMES := [
	"BlackPatch", "Redhand", "Kidd", "Bonny", "Teach", "Rackham",
	"Vane", "Hornigold", "Every", "Roberts", "Read", "Morgan",
	"Lowther", "Low", "England", "Bellamy", "Tew", "Davis",
]
const CORSAIR_NAMES := [
	"Barbarossa", "Dragut", "Surcouf", "Lafitte", "Bart", "Cassard",
	"Forbin", "Kemal", "Duguay", "Murat", "Turgut", "Rais",
	"Hamidou", "Fleury", "Pellegrin", "Misson", "Thurot", "Lemoine",
]
const BUCCANEER_NAMES := [
	"Grammont", "Dampier", "Mansvelt", "Wafer", "Sharp", "Coxon",
	"Swan", "Ringrose", "de Graaf", "Brasiliano", "Lussan", "Exquemelin",
	"Olonnais", "Mings", "Morris", "Townley", "Bartolomeu", "Lewis",
]
const CREW_NAMES := [NAV_NAMES, PIRATE_NAMES, CORSAIR_NAMES, BUCCANEER_NAMES]

var mode: Mode = Mode.SOLO
## Kept across games (reset() leaves them alone): you pick them once.
var difficulty: Difficulty = Difficulty.NORMAL
## Short / medium / long: the island's size and how many chests it holds.
var length: TerrainGrid.Length = TerrainGrid.Length.MEDIUM
var island_seed := 0
var configured := false
## Team size the host chose; the guest must pick exactly this many.
var team_target := DEFAULT_TEAM_SIZE

## How many crews land (2-4; practice alone is always just the NAVS), and who
## sails each one, indexed by Character.Team (see ctrl_of). The NAVS are always
## this computer's own crew, except on a guest, which plays `my_team`.
var team_count := MIN_TEAMS
var controllers: Array = [Ctrl.HUMAN, Ctrl.HUMAN, Ctrl.HUMAN, Ctrl.HUMAN]
var my_team := 0

## How many of each class per crew, keyed by CharacterStats.Kind.
var team_counts: Array = [{}, {}, {}, {}]
var nav_counts: Dictionary:
	get:
		return team_counts[0]
	set(v):
		team_counts[0] = v
var pirate_counts: Dictionary:
	get:
		return team_counts[1]
	set(v):
		team_counts[1] = v

## A line to show on the menu when we land back there unexpectedly (a lost
## connection, a version mismatch).
var menu_notice := ""

## Single player keeps your NAVS between games: everyone who has landed, with
## their coached skills (CharacterStats.to_dict()), saved to disk. The computer's
## pirates are always fresh.
const CREW_PATH := "user://crew.cfg"
var crew_path := CREW_PATH # the tests point this elsewhere
var crew: Array = []
## Regular multiplayer: the names each crew's player would like their sailors
## to have (from their Your Crew), per team: [{kind, name}]. Names only — in
## a regular match everyone starts fresh. Empty: the usual list's names.
var team_names: Array = [[], [], [], []]
## Handed from a won game to the coaching screen: more than 0 when a round of
## coaching is due (everyone gets one try, see CoachPanel), whether a new
## recruit joins first, and the names of who was on the island.
var coaching_sessions := 0
var recruit_due := false
## The campaign: who from your crew lands first (Campaign.party(), by name),
## so the same sailors keep sailing and the rest wait ashore.
var crew_first: Array = []
var last_party: Array = []
## The finished game, for the results page (see Main._results()).
var last_results: Dictionary = {}
## Set by the menu's Your Crew: the coaching screen opens to look over the
## whole saved crew, with nothing to spend.
var crew_view := false
## The campaign island being played (Campaign.CHAPTERS index), or -1 for any
## other game. Set by the campaign screen, kept in a saved game.
var campaign_chapter := -1
## Battle Royale (multiplayer, hosting or on a server): every crew for itself
## on a big island, each player bringing their own trained crew from single
## player, whole and uncapped (a player with none brings ten fresh recruits;
## the computer's seats are fresh too). It's a short match of `br_rounds`
## games; the most games won takes it. Vega sails only in the final round,
## unless the game was set up with `br_vega` (she may sail every round).
## The host checks each crew against the coaching limits (sanitize_crew). Match
## coaching between rounds lasts for the match only: nobody's saved crew is
## changed by playing one.
## Each player's turn in a multiplayer game lasts at most this many seconds,
## then passes on; 0 = no limit. Chosen when the game is set up (servers
## suggest 3 minutes; games hosted by a player or on one computer, none).
var turn_seconds := 0
const TURN_CHOICES := [0, 60, 120, 180, 300]
const SERVER_TURN_SECONDS := 180

static func turn_limit_text(seconds: int) -> String:
	return "no turn limit" if seconds <= 0 else ("%d-minute turns" % (seconds / 60) if seconds % 60 == 0 else "%d-second turns" % seconds)

var battle_royale := false
## The server list was opened from the menu's Battle Royale page: a new game
## started there begins as one.
var browse_royale := false
var br_rounds := 3
var br_vega := false
const BR_ROUNDS := [1, 3, 5]

## The tutorial is running (see Tutorial): a fresh crew, one waiting pirate,
## nothing saved.
var tutorial := false
const TUTORIAL_SEED := 5150
## The campaign was just finished for the first time: the ending plays after
## coaching.
var ending_due := false

func _ready() -> void:
	reset()
	load_crew()
	# After updating itself from a friend, the game restarts with these.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--join="):
			auto_join = a.trim_prefix("--join=")
		elif a.begins_with("--browse="):
			auto_browse = a.trim_prefix("--browse=")
		elif a == "--updated":
			menu_notice = "Updated to version %s." % version()

## Four crews can play as two sides of two (2v2): the crew that teams up with
## the NAVS (1 Pirates, 2 Corsairs, 3 Buccaneers); the other two are the other
## side. FREE_FOR_ALL: every crew for itself. Whoever sets up the game picks.
var partner := FREE_FOR_ALL

## Set at launch: a friend's address to join straight away.
var auto_join := ""
## Set at launch: a server to look up straight away on the Play on a Server
## screen (after updating from it).
var auto_browse := ""
## The main menu's Check for Updates found a newer version on this server
## (its server-list entry) and the player said yes: the server list fetches
## it straight away, and the game restarts into the menu.
var update_from := {}

## This build's version, from project.godot (the one place it's set). Tests
## can pose as another version with --pretend-version=X.
static func version() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pretend-version="):
			return a.trim_prefix("--pretend-version=")
	return str(ProjectSettings.get_setting("application/config/version", "dev"))

func reset() -> void:
	crew_first = []
	team_count = MIN_TEAMS
	my_team = 0
	controllers = [Ctrl.HUMAN, Ctrl.HUMAN, Ctrl.HUMAN, Ctrl.HUMAN]
	new_match()
	island_seed = randi()
	team_counts = []
	for t in MAX_TEAMS:
		team_counts.append(default_counts())
	team_target = DEFAULT_TEAM_SIZE
	team_names = [[], [], [], []]
	seat_owners = {}
	partner = FREE_FOR_ALL
	current_slot = ""
	campaign_chapter = -1
	tutorial = false
	battle_royale = false
	turn_seconds = 0
	br_rounds = 3
	br_vega = false
	configured = false

## Who sails crew `team` in this game. Single player: the computer sails
## every crew but yours. Sharing a computer: a person here unless the setup
## screen gave the crew to the computer. Hosting: a friend over the network,
## likewise. A guest takes the host's word (resolved_controllers()).
func ctrl_of(team: int) -> int:
	if team <= 0 and mode != Mode.GUEST and mode != Mode.SERVER:
		return Ctrl.HUMAN
	var chosen: int = int(controllers[clampi(team, 0, MAX_TEAMS - 1)])
	match mode:
		Mode.SOLO:
			return Ctrl.HUMAN
		Mode.COMPUTER:
			return Ctrl.COMPUTER
		Mode.HOTSEAT:
			return Ctrl.COMPUTER if chosen == Ctrl.COMPUTER else Ctrl.HUMAN
		Mode.HOST, Mode.SERVER:
			return Ctrl.COMPUTER if chosen == Ctrl.COMPUTER else Ctrl.FRIEND
	return chosen

## ctrl_of() for every crew, as sent to guests and kept with a saved game.
func resolved_controllers() -> Array:
	var out := []
	for t in MAX_TEAMS:
		out.append(ctrl_of(t))
	return out

## How many crews are on the island in this game.
func teams_in_play() -> int:
	return 1 if mode == Mode.SOLO else team_count

## How much longer north to south the island is than usual (a campaign
## island can ask for it).
func island_stretch() -> float:
	return float(Campaign.chapter(campaign_chapter).get("stretch", 1.0)) if in_campaign() else 1.0

## The island is built for this many crews (practice uses a two-crew island).
func island_teams() -> int:
	return MIN_TEAMS if mode == Mode.SOLO else team_count

## Playing two sides of two (it takes four crews).
func two_v_two() -> bool:
	return partner >= 1 and partner < MAX_TEAMS and team_count == MAX_TEAMS and mode != Mode.SOLO

## The side each crew is on: in 2v2 the NAVS and their partner are side 0 and
## the other two side 1. Free-for-all: empty (every crew is its own side).
func sides() -> Array:
	return sides_for(partner if two_v_two() else FREE_FOR_ALL, team_count)

static func sides_for(with_navs: int, teams: int) -> Array:
	if teams != MAX_TEAMS or with_navs < 1 or with_navs >= MAX_TEAMS:
		return []
	var out := [0, 1, 1, 1]
	out[with_navs] = 0
	return out

## "the NAVS and the Corsairs against the Pirates and the Buccaneers".
func sides_text() -> String:
	var s := sides()
	if s.is_empty():
		return "every crew for itself"
	var ours := []
	var theirs := []
	for t in MAX_TEAMS:
		if int(s[t]) == 0:
			ours.append("the " + team_name(t))
		else:
			theirs.append("the " + team_name(t))
	return "%s against %s" % [" and ".join(ours), " and ".join(theirs)]

func is_computer(team: int) -> bool:
	return team >= 0 and team < MAX_TEAMS and ctrl_of(team) == Ctrl.COMPUTER

func is_friend(team: int) -> bool:
	return team >= 0 and team < MAX_TEAMS and ctrl_of(team) == Ctrl.FRIEND

func has_computer_crews() -> bool:
	for t in range(1, teams_in_play()):
		if is_computer(t):
			return true
	return false

## Crews that people play (anyone but the computer), in turn order.
func human_teams() -> Array:
	var out := []
	for t in teams_in_play():
		if not is_computer(t):
			out.append(t)
	return out

static func team_name(t: int) -> String:
	return GameServer.TEAM_NAMES[clampi(t, 0, MAX_TEAMS - 1)]

## Two of each class — the balanced starting ten.
func default_counts() -> Dictionary:
	return balanced_counts(DEFAULT_TEAM_SIZE)

## Who would land with `counts` for crew `side`, for the setup screens'
## lists of names: build_roster() as `as_mode` would play it (single player
## brings your veterans first), without changing anything.
func preview_roster(counts: Dictionary, side := 0, as_mode := -1) -> Array:
	var saved_counts: Dictionary = team_counts[side]
	var saved_mode := mode
	var saved_chapter := campaign_chapter
	team_counts[side] = counts
	if as_mode >= 0:
		mode = as_mode as Mode
	campaign_chapter = -1
	var out := build_roster(side)
	team_counts[side] = saved_counts
	mode = saved_mode
	campaign_chapter = saved_chapter
	return out

## The names in `roster` (build_roster's) of class `kind`, joined for a list.
static func names_of(roster: Array, kind: int) -> String:
	var names: Array[String] = []
	for e in roster:
		if int(e[0]) == kind and str((e[2] if e.size() > 2 else {}).get("special", "")) == "":
			names.append(str(e[1]))
	return ", ".join(names)

## A crew of `size`, the classes taken in turn — the balanced five, grown or
## cut to fit. A dedicated server's computer crews land like this.
func balanced_counts(size: int) -> Dictionary:
	var out := {}
	for kind in CharacterStats.Kind.values():
		out[kind] = 0
	var order := [CharacterStats.Kind.FIGHTER, CharacterStats.Kind.RUNNER, CharacterStats.Kind.SCOUT,
		CharacterStats.Kind.SWORDSMAN, CharacterStats.Kind.DIGGER]
	for i in clampi(size, 1, MAX_TEAM_SIZE):
		out[order[i % order.size()]] += 1
	return out

## The makeup computer crews land with: the same as the NAVS everywhere but
## on a dedicated server, which has no crew of its own to copy.
func computer_counts() -> Dictionary:
	if mode == Mode.SERVER:
		return balanced_counts(team_target)
	return nav_counts.duplicate()

## The roster the setup screen edits: your own side's.
func editing_counts() -> Dictionary:
	return team_counts[my_team] if mode == Mode.GUEST else team_counts[0]

func team_size(counts: Dictionary = editing_counts()) -> int:
	var total := 0
	for k in counts:
		total += int(counts[k])
	return total

## Counts that came over the network: only known classes, sane numbers.
static func sanitize_counts(raw: Variant) -> Dictionary:
	var out := {}
	if not raw is Dictionary:
		return out
	for kind in CharacterStats.Kind.values():
		var v: Variant = raw.get(kind, 0)
		out[kind] = clampi(int(v), 0, MAX_TEAM_SIZE) if (v is int or v is float) else 0
	return out

## Expands the chosen counts into a concrete, named roster: [kind, name,
## saved skills or {}] per person. `team` is a Character.Team (true/false still
## mean PIRATES/NAVS). In single player your NAVS come from the saved crew
## first — the same Scout as last time, coaching and all — and anyone new is a
## fresh recruit.
func build_roster(team: Variant = 0) -> Array:
	var side: int = clampi(int(team), 0, MAX_TEAMS - 1)
	if in_match() and side < match_crews.size() and not match_crews[side].is_empty():
		# Later games of a match (and every Battle Royale round): exactly the
		# crew from last time, coached. Vega waits ashore until she's allowed.
		var vega_ok := not battle_royale or br_vega_allowed()
		return match_crews[side].filter(func(d: Dictionary) -> bool: return vega_ok or str(d.get("special", "")) == "") \
			.map(func(d: Dictionary) -> Array: return [int(d.kind), str(d.name), d])
	var names: Array = CREW_NAMES[side]
	var counts: Dictionary = team_counts[side]
	var veterans: Array = [] if side != 0 or not uses_crew() else ordered_crew()
	var taken := {}
	var names_only := false
	if veterans.is_empty() and in_match() and not battle_royale and side < team_names.size():
		# Regular multiplayer: this crew's player's Your Crew names, but fresh
		# skills. A name an earlier crew already asked for stays theirs, and
		# no fresh name takes one anybody asked for.
		names_only = true
		for t in team_names.size():
			if t == side:
				continue
			for d in team_names[t]:
				taken[str(d.name)] = true
		veterans = team_names[side].filter(func(d: Dictionary) -> bool: return _names_free_before(side, str(d.name)))
	for d in veterans:
		taken[str(d.name)] = true
	var out: Array = []
	var fresh := 0
	for kind in [CharacterStats.Kind.SCOUT, CharacterStats.Kind.DIGGER,
			CharacterStats.Kind.RUNNER, CharacterStats.Kind.FIGHTER,
			CharacterStats.Kind.SWORDSMAN]:
		var mine := veterans.filter(func(d: Dictionary) -> bool: return int(d.kind) == kind)
		for n in int(counts.get(kind, 0)):
			if n < mine.size():
				out.append([kind, str(mine[n].name), {} if names_only else mine[n]])
				continue
			var name := _new_name(names, taken, fresh)
			taken[name] = true
			fresh += 1
			out.append([kind, name, {}])
	if out.is_empty():
		out.append([CharacterStats.Kind.FIGHTER, names[0], {}])
	if in_campaign():
		if side == 0 and Campaign.vega_sails(campaign_chapter):
			var vega := vega_dict()
			out.append([int(vega.kind), str(vega.name), vega])
		elif side != 0:
			_drill(out, int(Campaign.chapter(campaign_chapter).get("drilled", 0)), side)
	return out

## No crew before `side` asked for `name` (so `side` may have it).
func _names_free_before(side: int, name: String) -> bool:
	for t in mini(side, team_names.size()):
		for d in team_names[t]:
			if str(d.name) == name:
				return false
	return true

## The names (and classes) of your Your Crew, for a regular multiplayer game:
## everyone but Vega, in crew order, no skills.
func my_crew_names() -> Array:
	return sanitize_names(crew.filter(func(d: Dictionary) -> bool: return str(d.get("special", "")) == ""))

## Names a player sent: at most MAX_TEAM_SIZE of {kind, name}, known classes,
## unique printable names. Anything else is dropped.
static func sanitize_names(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	var seen := {}
	for p in (raw as Array).slice(0, 64):
		if out.size() >= MAX_TEAM_SIZE:
			break
		if not p is Dictionary or not p.has("kind") or not p.has("name"):
			continue
		var kind := int(p.kind) if (p.kind is int or p.kind is float) else -1
		if kind < 0 or kind >= CharacterStats.Kind.size():
			continue
		var name := clean_name(str(p.name)).left(MAX_NAME_LENGTH)
		if name == "" or seen.has(name):
			continue
		seen[name] = true
		out.append({"kind": kind, "name": name})
	return out

## Vega as she stands in your crew (coached, maybe renamed), or as she was
## found if the crew was started over since.
func vega_dict() -> Dictionary:
	for d in crew:
		if str(d.get("special", "")) == Campaign.SPECIAL_VEGA:
			return d
	return Campaign.make_vega().to_dict()

## Campaign rivals come drilled: `sessions` coaching tries each (at the usual
## odds), rolled from the island, so every player meets the same crews.
func _drill(roster: Array, sessions: int, side: int) -> void:
	if sessions <= 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = island_seed * 7 + side
	for entry in roster:
		var st := CharacterStats.make(int(entry[0]), str(entry[1]))
		for n in sessions:
			var picks: Array = CharacterStats.SKILLS + ["team_spirit"]
			st.coach(picks[rng.randi() % picks.size()], rng)
		entry[2] = st.to_dict()

## The next name not already in use; past the end of the list, "Drake II" etc.
func _new_name(names: Array, taken: Dictionary, start: int) -> String:
	for round_ in range(1, 10):
		for i in names.size():
			var name: String = names[(start + i) % names.size()]
			if round_ > 1:
				name += " " + ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"][round_]
			if not taken.has(name):
				return name
	return names[0]

# --- the saved crew ----------------------------------------------------------

func uses_crew() -> bool:
	return (mode == Mode.COMPUTER or mode == Mode.SOLO) and not tutorial

## Sets up the tutorial's island: a short one, a crew of five (one of each
## class, fresh recruits), and a single pirate.
func start_tutorial() -> void:
	reset()
	mode = Mode.COMPUTER
	tutorial = true
	island_seed = TUTORIAL_SEED
	length = TerrainGrid.Length.SHORT
	difficulty = Difficulty.EASY
	team_count = 2
	team_counts[0] = {CharacterStats.Kind.SCOUT: 1, CharacterStats.Kind.DIGGER: 1, CharacterStats.Kind.RUNNER: 1,
		CharacterStats.Kind.FIGHTER: 1, CharacterStats.Kind.SWORDSMAN: 1}
	team_counts[1] = {CharacterStats.Kind.FIGHTER: 1}
	configured = true

func load_crew() -> void:
	var cfg := ConfigFile.new()
	crew = []
	if cfg.load(crew_path) != OK:
		return
	for d in cfg.get_value("crew", "people", []):
		if d is Dictionary and d.has("kind") and d.has("name"):
			crew.append(d)

func save_crew() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("crew", "people", crew)
	cfg.save(crew_path)

## Records how these people stand now (skills, confidence earned on the island),
## adding anyone new to the crew.
func remember(people: Array) -> void:
	for stats in people:
		var d: Dictionary = stats.to_dict()
		var i := crew.find_custom(func(e: Dictionary) -> bool: return str(e.name) == str(d.name))
		if i >= 0:
			crew[i] = d
		else:
			crew.append(d)
	save_crew()

## A Battle Royale round played with this player's crew: each sailor who
## landed has the game added to their career in the saved crew (by name;
## nothing else about the saved crew changes). `people` is [{name, tally,
## won}].
func add_careers(people: Array) -> void:
	var changed := false
	for p in people:
		for i in crew.size():
			var d: Dictionary = crew[i]
			if str(d.name) == str(p.get("name", "")):
				var st := CharacterStats.make(int(d.kind), str(d.name))
				st.apply_saved(d)
				st.add_career(p.get("tally", {}), bool(p.get("won", false)))
				d["career"] = st.career
				changed = true
	if changed:
		save_crew()

const MAX_NAME_LENGTH := 16

## Gives a crew member a name of your choosing. Names identify people between
## games, so a blank or already-taken name is refused. Returns the name they
## end up with.
func rename(old_name: String, wanted: String) -> String:
	var name := wanted.strip_edges().left(MAX_NAME_LENGTH)
	if name == "" or name == old_name:
		return old_name
	for d in crew:
		if str(d.name) == name:
			return old_name
	for d in crew:
		if str(d.name) == old_name:
			d.name = name
	var i := last_party.find(old_name)
	if i >= 0:
		last_party[i] = name
	save_crew()
	return name

## Single player: a new sailor of `kind` joins the saved crew, named `wanted`
## if that's free (else the next navigator's name), and gets a place on the
## next island. Returns them.
func recruit(kind: int, wanted := "") -> CharacterStats:
	var taken := {}
	for d in crew:
		taken[str(d.name)] = true
	var name := wanted.strip_edges().left(MAX_NAME_LENGTH)
	if name == "" or taken.has(name):
		name = _new_name(NAV_NAMES, taken, crew.size())
	var st := CharacterStats.make(kind as CharacterStats.Kind, name)
	crew.append(st.to_dict())
	save_crew()
	nav_counts[kind] = int(nav_counts.get(kind, 0)) + 1
	team_target = team_size(nav_counts)
	recruit_due = false
	return st

## Single player: when the saved crew has grown past the usual ten, everyone
## in it lands (up to MAX_TEAM_SIZE), unless the roster was already changed.
## Returns whether it changed the counts.
func fit_counts_to_crew() -> bool:
	if not uses_crew() or crew.size() <= team_size(nav_counts) or nav_counts != default_counts():
		return false
	var counts := {}
	for kind in CharacterStats.Kind.values():
		counts[kind] = 0
	for i in mini(crew.size(), MAX_TEAM_SIZE):
		counts[int(crew[i].kind)] += 1
	nav_counts = counts
	team_target = team_size(counts)
	return true

func clear_crew() -> void:
	crew = []
	save_crew()

# --- one saved game ----------------------------------------------------------

## Three save slots for games on this computer (single player, practice,
## players sharing one computer), and one for an online match the host runs.
## The in-game menu's Save Game picks a slot; the main menu's Saved Games
## loads or deletes them, and Continue picks up the newest. A game on one
## computer is cleared from its slot once it's played to the end; an online
## match instead saves itself after every game, so a campaign can go on over
## many evenings. Slot 1 is the file the single slot always used.
const SAVE_PATH := "user://savegame.cfg"
const ONLINE_SAVE_PATH := "user://online_save.cfg"
var save_path := SAVE_PATH # the tests point these elsewhere
var online_save_path := ONLINE_SAVE_PATH
## The saved game to load into the next Main scene, then emptied. Empty after
## loading an online match saved between games: the next island is a new one.
var resume: Dictionary = {}
## Whether the game now running came from a save slot.
var resumed := false
## The slot the game now running was loaded from or last saved to (a path),
## so it can be cleared when the game is played to the end. "" for none.
var current_slot := ""
const SLOTS := 3
## An online match: crew -> the player id (player_id()) of whoever sailed it,
## so each friend who comes back to a saved match gets their own crew again.
var seat_owners := {}

## Slot `i` (0, 1, 2) for games on this computer.
func slot_path(i: int) -> String:
	return save_path if i <= 0 else "%s_%d.cfg" % [save_path.get_basename(), i + 1]

func slot_paths() -> Array[String]:
	var out: Array[String] = []
	for i in SLOTS:
		out.append(slot_path(i))
	return out

## What's in a slot, for the save screens: {} when empty, else its summary,
## when it was saved (Unix time; 0 for saves older than this) and the mode.
func save_info(path: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return {}
	var game: Variant = cfg.get_value("save", "game", {})
	if not game is Dictionary or game.is_empty():
		return {}
	return {"summary": str(cfg.get_value("save", "summary", "")),
		"saved_at": int(cfg.get_value("save", "saved_at", 0)),
		"mode": int(cfg.get_value("save", "mode", Mode.COMPUTER))}

## The most recently saved slot on this computer, or "" if all are empty.
func newest_save() -> String:
	var best := ""
	var best_at := -1
	for path in slot_paths():
		var info := save_info(path)
		if not info.is_empty() and int(info.saved_at) > best_at:
			best = path
			best_at = int(info.saved_at)
	return best

func has_any_save() -> bool:
	return newest_save() != ""

## "Saved today at 21:04", "Saved 2 Nov at 09:30", or "" when not known.
static func saved_when(unix: int, now: int = -1) -> String:
	if unix <= 0:
		return ""
	var offset := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var t := Time.get_datetime_dict_from_unix_time(unix + offset)
	var today := Time.get_datetime_dict_from_unix_time((now if now >= 0 else int(Time.get_unix_time_from_system())) + offset)
	var clock := "%02d:%02d" % [int(t.hour), int(t.minute)]
	if t.year == today.year and t.month == today.month and t.day == today.day:
		return "Saved today at " + clock
	const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "Saved %d %s at %s" % [int(t.day), MONTHS[clampi(int(t.month) - 1, 0, 11)], clock]

func can_save() -> bool:
	if tutorial:
		return false
	return mode == Mode.SOLO or mode == Mode.COMPUTER or mode == Mode.HOTSEAT or mode == Mode.HOST

## Where this game saves: online matches have their own slot, so they never
## overwrite a game saved on this computer.
func save_slot() -> String:
	return online_save_path if mode == Mode.HOST or mode == Mode.SERVER else save_path

## `game` is GameServer.save_state(), or empty for an online match saved
## between games. `path` defaults to save_slot().
func save_game(game: Dictionary, summary: String, path := "") -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("save", "mode", mode)
	cfg.set_value("save", "difficulty", difficulty)
	cfg.set_value("save", "seed", island_seed)
	cfg.set_value("save", "length", length)
	cfg.set_value("save", "teams", team_count)
	cfg.set_value("save", "partner", partner)
	cfg.set_value("save", "target", team_target)
	cfg.set_value("save", "ctrl", resolved_controllers())
	cfg.set_value("save", "owners", seat_owners)
	cfg.set_value("save", "summary", summary)
	cfg.set_value("save", "match", match_state())
	cfg.set_value("save", "campaign", campaign_chapter)
	cfg.set_value("save", "campaign_level", Campaign.level)
	cfg.set_value("save", "turn", turn_seconds)
	cfg.set_value("save", "game", game)
	cfg.set_value("save", "saved_at", int(Time.get_unix_time_from_system()))
	var where := path if path != "" else save_slot()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(where).get_base_dir())
	cfg.save(where)

## An online match between games: the crews, the score and coaching, and who
## sailed what. Continuing it starts the next island.
func save_match(path := "") -> void:
	save_game({}, match_summary(), path)

## "Online match: NAVS 2, Pirates 1 after 3 games" for the menu.
func match_summary() -> String:
	var parts: Array[String] = []
	for t in mini(team_count, match_score.size()):
		parts.append("%s %d" % [team_name(t), int(match_score[t])])
	return "Online match: %s after %d game%s" % [", ".join(parts), match_games, "" if match_games == 1 else "s"]

func has_save(path := "") -> bool:
	return FileAccess.file_exists(path if path != "" else save_path)

## A line for the menu: what the saved game is.
func save_summary(path := "") -> String:
	var cfg := ConfigFile.new()
	if cfg.load(path if path != "" else save_path) != OK:
		return ""
	return str(cfg.get_value("save", "summary", ""))

## Sets everything up to continue the saved game; false if there isn't one.
## An online match may have been saved between games (no game in it): then
## the next game is on a new island, with the crews as they stand.
func load_game(path := "") -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path if path != "" else save_path) != OK:
		return false
	var game: Variant = cfg.get_value("save", "game", {})
	var saved_mode := int(cfg.get_value("save", "mode", Mode.COMPUTER))
	var online := saved_mode == Mode.HOST or saved_mode == Mode.SERVER
	if not game is Dictionary or (game.is_empty() and not online):
		return false
	reset()
	mode = saved_mode as Mode
	difficulty = int(cfg.get_value("save", "difficulty", Difficulty.NORMAL)) as Difficulty
	island_seed = int(cfg.get_value("save", "seed", 0))
	length = clampi(int(cfg.get_value("save", "length", TerrainGrid.Length.MEDIUM)), 0, 2) as TerrainGrid.Length
	team_target = clampi(int(cfg.get_value("save", "target", DEFAULT_TEAM_SIZE)), 1, MAX_TEAM_SIZE)
	apply_match_state(cfg.get_value("save", "match", {}))
	# After the match state, which only knows how many crews it has kept so far.
	team_count = clampi(int(cfg.get_value("save", "teams", MIN_TEAMS)), MIN_TEAMS, MAX_TEAMS)
	partner = clampi(int(cfg.get_value("save", "partner", FREE_FOR_ALL)), FREE_FOR_ALL, MAX_TEAMS - 1)
	_fit_match()
	var ctrl: Variant = cfg.get_value("save", "ctrl", [])
	if ctrl is Array and ctrl.size() == MAX_TEAMS:
		controllers = ctrl.map(func(v: Variant) -> int: return clampi(int(v), 0, Ctrl.FRIEND))
	var owners: Variant = cfg.get_value("save", "owners", {})
	seat_owners = {}
	if owners is Dictionary:
		for t in owners:
			if int(t) >= 0 and int(t) < MAX_TEAMS and str(owners[t]) != "":
				seat_owners[int(t)] = str(owners[t])
	if online:
		# A crew someone sailed is theirs to come back to, even if the computer
		# took it over when they left.
		for t in seat_owners:
			controllers[t] = Ctrl.HUMAN
		if game.is_empty():
			island_seed = randi()
	campaign_chapter = clampi(int(cfg.get_value("save", "campaign", -1)), -1, Campaign.count() - 1)
	if campaign_chapter >= 0:
		Campaign.level = clampi(int(cfg.get_value("save", "campaign_level", 0)), 0, 2)
	turn_seconds = clampi(int(cfg.get_value("save", "turn", 0)), 0, 3600)
	resume = game
	current_slot = "" if online else (path if path != "" else save_path)
	configured = true
	return true

func delete_save(path := "") -> void:
	var where := path if path != "" else save_path
	if FileAccess.file_exists(where):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(where))

## A random name for this copy of the game, kept on disk, so a host or a
## server can give a returning player their own crew in a saved match. It's
## only random letters, nothing about the player. Tests running several copies
## on one computer give each its own with --player-id=.
const PLAYER_PATH := "user://player.cfg"
var _player_id := ""

func player_id() -> String:
	if _player_id != "":
		return _player_id
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--player-id="):
			_player_id = a.trim_prefix("--player-id=")
			return _player_id
	var cfg := ConfigFile.new()
	if cfg.load(PLAYER_PATH) == OK:
		_player_id = str(cfg.get_value("player", "id", ""))
	if _player_id == "":
		_player_id = Crypto.new().generate_random_bytes(8).hex_encode()
		cfg.set_value("player", "id", _player_id)
		cfg.save(PLAYER_PATH)
	return _player_id

## The name other players see on a server: in its lobby and in their server
## lists. Kept beside the player id; it starts as this computer's user name.
var _player_name := ""

func player_name() -> String:
	if _player_name != "":
		return _player_name
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--player-name="):
			_player_name = clean_name(a.trim_prefix("--player-name="))
	var cfg := ConfigFile.new()
	if _player_name == "" and cfg.load(PLAYER_PATH) == OK:
		_player_name = clean_name(str(cfg.get_value("player", "name", "")))
	if _player_name == "" and not OS.has_feature("web"): # a browser's USER is just "web_user"
		var user := OS.get_environment("USER") if OS.has_environment("USER") else OS.get_environment("USERNAME")
		_player_name = clean_name(user.capitalize())
	if _player_name == "":
		_player_name = "A pirate"
	return _player_name

func set_player_name(raw: String) -> void:
	var clean := clean_name(raw)
	if clean == "" or clean == _player_name:
		return
	_player_name = clean
	var cfg := ConfigFile.new()
	cfg.load(PLAYER_PATH)
	cfg.set_value("player", "id", player_id())
	cfg.set_value("player", "name", clean)
	cfg.save(PLAYER_PATH)

## A name fit to show anyone: printable, no BBCode brackets, at most 20 long.
static func clean_name(raw: String) -> String:
	var out := ""
	for ch in raw:
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127 and not ch in ["[", "]"]:
			out += ch
	return out.strip_edges().left(20).strip_edges()

# --- a match ----------------------------------------------------------------

## A match is a run of games between the same crews — at one computer, or
## friends online. Each crew (names, coached skills, attitudes, confidence)
## carries from game to game, and everyone starts fresh with every new match,
## so nobody begins one with an advantage. After each game every crew coaches
## every one of its people once (one try each, see CharacterStats.coach), win
## or lose, so the winner can't pull away. Computer crews coach straight away.
## Online, the host's copy is the real one: a guest sends its whole plan and
## the host rolls it and sends the results across. The crew that moves first
## takes turns from game to game.
var match_crews: Array = [[], []] # per team: CharacterStats.to_dict()s; empty before the first game ends
var match_score := [0, 0]
var match_coached := [false, false] # per team: has coached since the last game
var match_note := [[], []]        # per team: the last coaching results, as coach_crew() gives them
var match_ready := [false, false] # online: who is ready for the next game
var match_games := 0              # games finished in this match
var match_rng := RandomNumberGenerator.new()

func new_match() -> void:
	match_crews = []
	match_score = []
	match_coached = []
	match_note = []
	match_ready = []
	match_games = 0
	_fit_match()
	match_rng.randomize()

## Grows (or trims) the per-crew match lists to the number of crews, keeping
## what's there.
func _fit_match() -> void:
	var n := clampi(team_count, MIN_TEAMS, MAX_TEAMS)
	for pair in [[match_crews, []], [match_score, 0], [match_coached, false], [match_note, []], [match_ready, false]]:
		var list: Array = pair[0]
		while list.size() < n:
			list.append(pair[1].duplicate() if pair[1] is Array else pair[1])
		list.resize(n)

func in_match() -> bool:
	return mode == Mode.HOTSEAT or mode == Mode.HOST or mode == Mode.GUEST or mode == Mode.SERVER

## Which crew moves first this game: the NAVS in the first game of a match,
## then each crew in turn, so nobody keeps the head start.
func first_team() -> int:
	if in_campaign() and Campaign.chapter(campaign_chapter).get("pirates_first", false):
		return 1
	return (match_games % team_count) if in_match() else 0

func in_campaign() -> bool:
	return campaign_chapter >= 0 and mode == Mode.COMPUTER

## Sets everything up for campaign island `i`, with your crew made up as
## `counts` (which must add up to the island's crew size).
func start_campaign(i: int, counts: Dictionary) -> void:
	reset()
	var c := Campaign.chapter(i)
	mode = Mode.COMPUTER
	campaign_chapter = clampi(i, 0, Campaign.count() - 1)
	island_seed = int(c.seed)
	length = int(c.length) as TerrainGrid.Length
	difficulty = int(c.difficulty) as Difficulty
	team_count = int(c.rivals) + 1
	team_counts[0] = counts.duplicate()
	for t in range(1, MAX_TEAMS):
		team_counts[t] = balanced_counts(int(c.rival_crew))
	crew_first = Campaign.party()
	configured = true

## Your crew (Vega aside) in the order they're picked to land: in the
## campaign, those already sailing it first (crew_first), then the rest as
## they are in the crew.
func ordered_crew() -> Array:
	var regular := crew.filter(func(d: Dictionary) -> bool: return str(d.get("special", "")) == "")
	if crew_first.is_empty():
		return regular
	var first := []
	for n in crew_first:
		for d in regular:
			if str(d.name) == str(n):
				first.append(d)
	return first + regular.filter(func(d: Dictionary) -> bool: return not crew_first.has(str(d.name)))

## A campaign's island makeup: the counts you last chose, cut or grown to the
## island's crew size.
func campaign_counts(size: int, wanted: Dictionary = {}) -> Dictionary:
	var out := {}
	var total := 0
	for kind in CharacterStats.Kind.values():
		out[kind] = clampi(int(wanted.get(kind, 0)), 0, size)
		total += int(out[kind])
	if total == size:
		return out
	# Otherwise the crew in landing order (those sailing the campaign first,
	# a new recruit or someone brought in among them), as many as there's
	# room for, topped up with the classes taken in turn.
	out = counts_of(ordered_crew().slice(0, size))
	total = 0
	for kind in out:
		total += int(out[kind])
	var order := [CharacterStats.Kind.FIGHTER, CharacterStats.Kind.RUNNER, CharacterStats.Kind.SCOUT,
		CharacterStats.Kind.SWORDSMAN, CharacterStats.Kind.DIGGER]
	var i := 0
	while total > size:
		var biggest: int = order[0]
		for k in order:
			if int(out[k]) > int(out[biggest]):
				biggest = k
		out[biggest] = int(out[biggest]) - 1
		total -= 1
	while total < size:
		out[order[i % order.size()]] = int(out[order[i % order.size()]]) + 1
		total += 1
		i += 1
	return out

# --- Battle Royale ----------------------------------------------------------

## The Battle Royale settings, as sent to guests and kept with a saved match.
func royale_state() -> Dictionary:
	return {"on": battle_royale, "rounds": br_rounds, "vega": br_vega}

func apply_royale(d: Dictionary) -> void:
	battle_royale = bool(d.get("on", false))
	br_rounds = int(d.get("rounds", 3)) if BR_ROUNDS.has(int(d.get("rounds", 3))) else 3
	br_vega = bool(d.get("vega", false))
	if battle_royale:
		partner = FREE_FOR_ALL

## Sets up a Battle Royale: free-for-all, a long island unless chosen otherwise.
func set_battle_royale(on: bool, rounds := 3, vega := false) -> void:
	battle_royale = on
	br_rounds = rounds if BR_ROUNDS.has(rounds) else 3
	br_vega = vega
	if on:
		partner = FREE_FOR_ALL

## Hosting a Battle Royale from this computer: four crews on a long island.
func host_royale() -> void:
	reset()
	mode = Mode.HOST
	set_battle_royale(true)
	length = TerrainGrid.Length.LONG
	team_count = MAX_TEAMS

## This game is the Battle Royale's last.
func br_final_round() -> bool:
	return battle_royale and match_games >= br_rounds - 1

## Every round has been played.
func br_over() -> bool:
	return battle_royale and match_games >= br_rounds

func br_vega_allowed() -> bool:
	return br_vega or br_final_round()

## "Round 2 of 3", "Final round".
func br_round_text() -> String:
	if br_final_round():
		return "Final round" if br_rounds > 1 else "One round"
	return "Round %d of %d" % [match_games + 1, br_rounds]

## The crew this player brings to a Battle Royale: everyone in their saved
## crew, Vega too (the host keeps her ashore until she's allowed), or ten
## fresh recruits if they haven't one yet.
func my_br_crew() -> Array:
	if not crew.is_empty():
		return crew.duplicate(true)
	var out: Array = []
	var taken := {}
	var counts := default_counts()
	var i := 0
	for kind in [CharacterStats.Kind.SCOUT, CharacterStats.Kind.DIGGER, CharacterStats.Kind.RUNNER,
			CharacterStats.Kind.FIGHTER, CharacterStats.Kind.SWORDSMAN]:
		for n in int(counts.get(kind, 0)):
			var name := _new_name(NAV_NAMES, taken, i)
			taken[name] = true
			i += 1
			out.append(CharacterStats.make(kind, name).to_dict())
	return out

## A crew a player sent, made fit to land: at most MAX_TEAM_SIZE sailors and
## one Vega, known classes, unique printable names, every skill between where
## its class starts and as far as coaching can take it, spirit 20-100,
## confidence 0-100. Anything else is dropped. Empty if nothing was usable.
static func sanitize_crew(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	var names := {}
	var vega := false
	for p in (raw as Array).slice(0, 64):
		if not p is Dictionary or not p.has("kind") or not p.has("name"):
			continue
		var kind := int(p.kind) if (p.kind is int or p.kind is float) else -1
		if kind < 0 or kind >= CharacterStats.Kind.size():
			continue
		var name := clean_name(str(p.name)).left(MAX_NAME_LENGTH)
		if name == "" or names.has(name):
			continue
		var special := str(p.get("special", ""))
		if special != "" and (special != Campaign.SPECIAL_VEGA or vega):
			continue
		var regulars := out.filter(func(d: Dictionary) -> bool: return not d.has("special")).size()
		if special == "" and regulars >= MAX_TEAM_SIZE:
			continue
		var st := Campaign.make_vega() if special != "" else CharacterStats.make(kind, name)
		st.person_name = name
		for skill in CharacterStats.SKILLS:
			var v: Variant = p.get(skill)
			if v is int or v is float:
				st.set(skill, clampf(float(v), minf(st.start_value(skill), st.coach_cap(skill)), st.coach_cap(skill)))
		var spirit: Variant = p.get("team_spirit")
		if spirit is int or spirit is float:
			st.team_spirit = clampf(float(spirit), 20.0, CharacterStats.MAX_SKILL)
		var conf: Variant = p.get("confidence")
		if conf is int or conf is float:
			st.confidence = clampf(float(conf), 0.0, 100.0)
		for a in CharacterStats.ATTITUDES:
			if p.get(a) is bool:
				st.set(a, p.get(a))
		names[name] = true
		vega = vega or special != ""
		out.append(st.to_dict())
	return out

## "NAVS 2, Pirates 1, Corsairs 0" and who's ahead.
func br_standings() -> String:
	var parts: Array[String] = []
	for t in mini(team_count, match_score.size()):
		parts.append("%s %d" % [team_name(t), int(match_score[t])])
	return ", ".join(parts)

## The crews with the most rounds won (one, or several level).
func br_leaders() -> Array:
	var best := -1
	var out := []
	for t in mini(team_count, match_score.size()):
		var n := int(match_score[t])
		if n > best:
			best = n
			out = [t]
		elif n == best:
			out.append(t)
	return out if best > 0 else []

## "The Pirates take the Battle Royale!" or a shared win, when it's over.
func br_result() -> String:
	var lead := br_leaders()
	if lead.is_empty():
		return "Nobody won a round: the Battle Royale ends level."
	if lead.size() == 1:
		return "The %s take the Battle Royale!" % team_name(int(lead[0]))
	return "The Battle Royale is shared: %s." % " and ".join(lead.map(func(t: int) -> String: return "the " + team_name(t)))

## The class makeup of a crew (for the lobby's summary).
static func counts_of(people: Array) -> Dictionary:
	var out := {}
	for kind in CharacterStats.Kind.values():
		out[kind] = 0
	for d in people:
		if str(d.get("special", "")) == "":
			out[int(d.kind)] = int(out.get(int(d.kind), 0)) + 1
	return out

## Whether this copy's player has finished the campaign: their ship flies the
## Golden Rooster flag.
func is_captain() -> bool:
	return Campaign.is_captain()

## A game of the match is over: remember every crew as it stands and open a
## round of coaching. `crews` holds each team's CharacterStats; `winner` is a
## team, or GameServer.DRAW / NOBODY for none. (Chests delivered used to earn
## coaching; now every crew coaches everyone, so it's ignored.)
func end_game_in_match(crews: Array, winner: int, _delivered: Array = []) -> void:
	team_count = clampi(crews.size(), MIN_TEAMS, MAX_TEAMS)
	_fit_match()
	var s := sides()
	# In 2v2 the winner's partner won too.
	var won := func(t: int) -> bool:
		return winner >= 0 and (t == winner or (not s.is_empty() and int(s[t]) == int(s[winner])))
	for t in crews.size():
		var kept: Array = []
		if battle_royale:
			# Vega stayed ashore this round: she's still in the crew for the final.
			var landed: Array = crews[t].map(func(st: CharacterStats) -> String: return st.person_name)
			kept = match_crews[t].filter(func(d: Dictionary) -> bool:
				return str(d.get("special", "")) != "" and not landed.has(str(d.name)))
		match_crews[t] = crews[t].map(func(st: CharacterStats) -> Dictionary: return st.to_dict()) + kept
		match_coached[t] = false
		match_note[t] = []
		match_ready[t] = false
		if won.call(t) and t < match_score.size():
			match_score[t] += 1
	match_games += 1
	for t in crews.size():
		if is_computer(t):
			_auto_coach(t)
			match_ready[t] = true

## A computer crew coaches everyone at once, as "coach everyone for me" would.
func _auto_coach(team: int) -> void:
	var plan := {}
	for i in match_crews[team].size():
		var d: Dictionary = match_crews[team][i]
		var st := CharacterStats.make(int(d.kind), str(d.name))
		st.apply_saved(d)
		plan[i] = st.auto_pick()
	coach_plan_in_match(team, plan)

## One try for each of `people` (CharacterStats, changed in place) at what
## `plan` (index -> pick) says. Anyone without a pick, or with one that can't
## do anything, sits it out. Returns a line per try: {"text", "ok"}.
static func coach_crew(people: Array, plan: Dictionary, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for i in people.size():
		var pick: Variant = plan.get(i, "")
		var st: CharacterStats = people[i]
		if not pick is String or not st.can_coach(pick):
			continue
		var before := float(st.get(pick)) if not pick in CharacterStats.ATTITUDES else 0.0
		var gain := st.coach(pick, rng)
		out.append({"text": st.result_text(pick, gain, before), "ok": gain > 0.0})
	return out

## A coaching plan that came over the network: index -> pick, for people this
## crew has, picks that exist. Anything else is dropped.
static func sanitize_plan(raw: Variant, size: int) -> Dictionary:
	var out := {}
	if not raw is Dictionary:
		return out
	for k in raw:
		var v: Variant = raw[k]
		if (k is int or k is float) and int(k) >= 0 and int(k) < size and v is String \
				and CharacterStats.COACH_PICKS.has(v):
			out[int(k)] = v
	return out

## `team` coaches its crew for this round, by `plan` (index -> pick). Once a
## round: false if it already has, or the plan is for nobody. The results go
## in match_note[team].
func coach_plan_in_match(team: int, plan: Variant) -> bool:
	if team < 0 or team >= match_crews.size() or match_crews[team].is_empty() or bool(match_coached[team]):
		return false
	var clean := sanitize_plan(plan, match_crews[team].size())
	if clean.is_empty():
		return false
	var people: Array = []
	for d in match_crews[team]:
		var st := CharacterStats.make(int(d.kind), str(d.name))
		st.apply_saved(d)
		people.append(st)
	match_note[team] = coach_crew(people, clean, match_rng)
	match_crews[team] = people.map(func(st: CharacterStats) -> Dictionary: return st.to_dict())
	match_coached[team] = true
	return true

## Renames `team`'s person `index`; names must be unique within the crew.
func rename_in_match(team: int, index: int, wanted: String) -> void:
	if team < 0 or team >= match_crews.size() or index < 0 or index >= match_crews[team].size():
		return
	var name := wanted.strip_edges().left(MAX_NAME_LENGTH)
	if name == "":
		return
	for d in match_crews[team]:
		if str(d.name) == name:
			return
	match_crews[team][index].name = name

## Every crew except the computer's has said it's ready for the next game.
func all_ready() -> bool:
	for t in match_ready.size():
		if not bool(match_ready[t]) and not is_computer(t):
			return false
	return true

## What the host sends the guests between games.
func match_state() -> Dictionary:
	return {"crews": match_crews, "score": match_score, "coached": match_coached,
		"note": match_note, "ready": match_ready, "games": match_games, "ctrl": resolved_controllers(),
		"partner": partner, "royale": royale_state()}

func apply_match_state(d: Dictionary) -> void:
	var crews: Variant = d.get("crews", [])
	if crews is Array and crews.size() >= MIN_TEAMS and crews.size() <= MAX_TEAMS:
		team_count = crews.size()
		_fit_match()
		for t in crews.size():
			var clean: Array = []
			if crews[t] is Array:
				for p in crews[t]:
					if p is Dictionary and p.has("kind") and p.has("name"):
						clean.append(p)
			match_crews[t] = clean
	for key in ["score", "coached", "note", "ready"]:
		var v: Variant = d.get(key)
		if v is Array and v.size() == team_count:
			set("match_" + key, v)
	match_games = maxi(0, int(d.get("games", match_games)))
	if d.get("royale") is Dictionary:
		apply_royale(d.royale)
	if d.has("partner"):
		partner = clampi(int(d.partner), FREE_FOR_ALL, MAX_TEAMS - 1)
	var ctrl: Variant = d.get("ctrl")
	if ctrl is Array and ctrl.size() == MAX_TEAMS:
		controllers = ctrl.map(func(v: Variant) -> int: return clampi(int(v), 0, Ctrl.FRIEND))
