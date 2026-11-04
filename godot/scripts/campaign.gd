class_name Campaign
extends RefCounted

## The single-player campaign, THE STAR CHART: fifteen islands in order, each
## a fixed island (the same for everyone) with its own rules, played by your
## own trained crew against computer crews.
##
## The story: Captain BlackPatch's pirates raided the NAVS' harbour by night. They
## took the Star Chart, the only map that shows the way to Treasure Island,
## and they took Vega, the fleet's finest navigator. Act I chases them; on
## island 7 (Gallows Rock) you free Vega, who then sails with you as a special
## sailor with very high skills; on island 12 (BlackPatch's Hideout) you dig up
## the Star Chart, and with it the later islands start fully mapped. Island 15
## is Treasure Island. Winning it plays the ending and makes you a Captain:
## your ship flies the Golden Rooster (CaptainFlag), in single player and
## online.
##
## Goals: "chests" (the usual race), "rescue" (free Vega and walk her onto your
## ship; chests don't win it for you, but the pirates still can) and "chart"
## (get the Star Chart, buried by the gold X, aboard your ship; the same).
##
## Progress lives in its own file (user://campaign.cfg), apart from the save
## slots: which islands you've won, whether you're a Captain, and each
## sailor's record over the campaign for the ending's credits.

const PATH := "user://campaign.cfg"
static var path := PATH ## the tests point this elsewhere
static var _data: Dictionary = {}
static var _loaded_from := ""

const RESCUE := 6 ## Gallows Rock (island 7): free Vega
const CHART := 11 ## BlackPatch's Hideout (island 12): dig up the Star Chart
const FINAL := 14 ## Treasure Island
const VEGA := "Vega"
const SPECIAL_VEGA := "vega"

const ACTS := [[0, "Act I: The Raid"], [5, "Act II: The Rescue"], [10, "Act III: The Star Chart"]]

## Each island: title, story, goal, length (0 Short, 1 Medium, 2 Long), rivals
## (1-3 computer crews), difficulty (0-2), crew (your sailors, Vega not
## counted), rival_crew (each rival's size), drilled (coaching sessions each
## rival sailor has had), storm (your crew rests a quarter less), pirates_first
## (they move first), charted (the whole island is mapped from the start).
const CHAPTERS := [
	{"title": "Ashes in the Harbour", "tip": "Send your Scout ahead standing still: they see furthest. Diggers dig for a third of the energy, so let them do the digging.", "seed": 71031, "goal": "chests", "length": 0, "rivals": 1, "difficulty": 0,
		"crew": 6, "rival_crew": 5, "drilled": 0,
		"story": "Captain BlackPatch's pirates raided the harbour by night. They took the Star Chart, the only map to Treasure Island, and they took Vega, the fleet's finest navigator. Their ship was seen stopping here to bury the loot from the raid. Get it back before they sail on."},
	{"title": "Smugglers' Cove", "tip": "A chest carrier fights at half strength. Keep a fighter near whoever is carrying.", "seed": 50287, "goal": "chests", "length": 0, "rivals": 1, "difficulty": 0,
		"crew": 6, "rival_crew": 6, "drilled": 0,
		"story": "BlackPatch's crew split up to hide their plunder. A smuggler swears one party landed in this cove. Beat them to it, and maybe one of them will talk."},
	{"title": "The Whispering Woods", "tip": "Woods cost more energy to cross and hide who's in them. Stand on open ground to look, crawl through the trees to stay hidden.", "seed": 33901, "goal": "chests", "length": 1, "rivals": 1, "difficulty": 1,
		"crew": 7, "rival_crew": 7, "drilled": 1,
		"story": "Thick woods, and the pirates know them. A bigger island, and these pirates are sharper than the last lot. Keep your Scout standing to see over the trees."},
	{"title": "Storm Reef", "tip": "Strength in a fight rises and falls with energy, and the pirates rest fully while you don't. Fight only with rested sailors, end turns before your crew is worn down, and give the long walks to Runners: they have the most stamina.", "seed": 88412, "goal": "chests", "length": 1, "rivals": 1, "difficulty": 1,
		"crew": 7, "rival_crew": 7, "drilled": 1, "storm": true,
		"story": "A storm is coming in over the reef. Soaked and cold, your crew get back less energy at the start of each turn. Spend it carefully."},
	{"title": "The Corsairs' Bargain", "tip": "Two rival crews race each other as well as you. Let them clash, and grab the chests nearer your ship first.", "seed": 12007, "goal": "chests", "length": 1, "rivals": 2, "difficulty": 1,
		"crew": 8, "rival_crew": 7, "drilled": 2,
		"story": "BlackPatch has sold word of the Star Chart to the Corsairs, and now they want Treasure Island too. Two crews race you for this island's chests."},
	{"title": "BlackPatch's Lookout", "tip": "The pirates move first. Spend your first turn spotting where they went before committing your diggers.", "seed": 64523, "goal": "chests", "length": 1, "rivals": 1, "difficulty": 1,
		"crew": 8, "rival_crew": 8, "drilled": 2, "pirates_first": true,
		"story": "From this island's hill the pirates watch the sea. They saw you coming and landed first. Win here and you'll learn where they're holding Vega."},
	{"title": "Gallows Rock", "tip": "Scout first: she's somewhere near BlackPatch's camp. Rest at your outpost (double energy) before the push, watch for an ambush past it, and bring muscle: Swordsmen and Fighters, rested. The stockade has one gate, and you can't cut her free while a guard stands beside her.", "seed": 29150, "goal": "rescue", "length": 2, "rivals": 1, "difficulty": 1,
		"crew": 9, "rival_crew": 14, "drilled": 3, "guards": 4, "stretch": 1.6,
		"story": "Vega is held somewhere near BlackPatch's camp, behind a stockade with a single gate, and his four best stand guard over her. Scout ahead to find her. Your crew has set up an outpost on the way, where resting gives double energy; past it, pirates lie in ambush. You can't cut her free while a guard stands beside her: capture them, or draw them out through the gate, then get her aboard your ship. Chests won't win this island for you, but if the pirates get enough of them aboard, they sail away with her."},
	{"title": "Vega's Course", "tip": "Vega sees further than anyone and fights well. Use her as your eyes, and keep her out of fights when she's tired.", "seed": 47738, "goal": "chests", "length": 1, "rivals": 1, "difficulty": 1,
		"crew": 9, "rival_crew": 9, "drilled": 3,
		"story": "Vega is free, and she sails with you now: quick, tireless, sharp-eyed and good with a sword. She's taking the helm to cut BlackPatch off. The rest of your crew lands with her."},
	{"title": "Two Flags", "tip": "The pirates and the Corsairs play hard now and hunt carriers. Move carriers with an escort, and hand the chest over before a carrier runs out of energy.", "seed": 15664, "goal": "chests", "length": 1, "rivals": 2, "difficulty": 2,
		"crew": 10, "rival_crew": 9, "drilled": 4,
		"story": "The pirates and the Corsairs have joined forces against you. They play hard now: they take risks and hunt anyone carrying a chest."},
	{"title": "The Long Night", "tip": "A long game in a storm. Rest is everything: never let a sailor end a turn far from home with little energy, and keep your crew together.", "seed": 90321, "goal": "chests", "length": 2, "rivals": 1, "difficulty": 2,
		"crew": 11, "rival_crew": 12, "drilled": 4, "storm": true,
		"story": "A big island in foul weather, against BlackPatch's best. A long game: rest your crew well, and don't waste energy on squares you don't need."},
	{"title": "Three Flags", "tip": "Three rivals. You don't need more than half the chests, only more than anyone can catch. Watch the scoreboard and slow down the leader.", "seed": 38846, "goal": "chests", "length": 1, "rivals": 3, "difficulty": 1,
		"crew": 12, "rival_crew": 11, "drilled": 5,
		"story": "Word of the Star Chart has spread. Now the Buccaneers want it too. Three rival crews on one island: you only have to finish ahead of them all."},
	{"title": "BlackPatch's Hideout", "tip": "Ordinary chests won't win this one. Get the Star Chart from under the gold X; if the pirates dig it first, capture the carrier.", "seed": 70519, "goal": "chart", "length": 1, "rivals": 2, "difficulty": 2,
		"crew": 12, "rival_crew": 11, "drilled": 5,
		"story": "BlackPatch buried the Star Chart here, under the gold X. Dig it up and get it aboard your ship. Ordinary chests won't win this island for you. If the pirates dig it up first, take it back from them: capture the carrier and it's yours."},
	{"title": "By the Stars", "tip": "You know the whole island from the start. Plan the shortest routes to the X's before you move anyone.", "seed": 55180, "goal": "chests", "length": 2, "rivals": 2, "difficulty": 2,
		"crew": 13, "rival_crew": 13, "drilled": 6, "charted": true,
		"story": "With the Star Chart back, Vega has mapped this whole island before you land. You know every hill and wood from the first turn. The enemy, though, you still have to find."},
	{"title": "The Admiral's Gauntlet", "tip": "Everyone else lands first, and the storm saps your crew. Dig close to home and fight only where you're strongest.", "seed": 81277, "goal": "chests", "length": 2, "rivals": 3, "difficulty": 2,
		"crew": 14, "rival_crew": 13, "drilled": 7, "storm": true, "pirates_first": true,
		"story": "Every rival crew is waiting at the last island before Treasure Island, and the weather is against you. They land first. Get through this, and the way is open."},
	{"title": "Treasure Island", "tip": "Every crew's best is here. Use everything: the map, Vega, escorts for carriers, and rested fighters.", "seed": 99001, "goal": "chests", "length": 2, "rivals": 3, "difficulty": 2,
		"crew": 15, "rival_crew": 15, "drilled": 8, "charted": true,
		"story": "Treasure Island, at last. The Star Chart shows every inch of it, but BlackPatch, the Corsairs and the Buccaneers have followed you here with their best crews. This is the one that counts."},
]

static func count() -> int:
	return CHAPTERS.size()

## The difficulty levels of the campaign, each with its own progress:
## Normal (the islands as written), Hard (computer crews a level harder, each
## rival crew 2 bigger and drilled 2 more times, a fifth guard at Gallows
## Rock) and Extreme (every computer crew Hard, rival crews 4 bigger and
## drilled 4 more, the pirates first on every island, six guards). All three
## are open from the start; your crew is the same in all of them.
const LEVEL_NAMES := ["Normal", "Hard", "Extreme"]
const LEVEL_BLURBS := [
	"The islands as written.",
	"Rivals play harder, with bigger, better-drilled crews.",
	"The hardest rivals, the biggest crews, and they always move first.",
]
static var level := 0

## Island `i` as it plays at the current level.
static func chapter(i: int) -> Dictionary:
	var c: Dictionary = CHAPTERS[clampi(i, 0, CHAPTERS.size() - 1)]
	if level <= 0:
		return c
	c = c.duplicate()
	var more := 2 if level == 1 else 4
	c.difficulty = mini(int(c.difficulty) + 1, 2) if level == 1 else 2
	c.rival_crew = mini(int(c.rival_crew) + more, GameConfig.MAX_TEAM_SIZE)
	c.drilled = int(c.drilled) + more
	if int(c.get("guards", 0)) > 0:
		c.guards = int(c.guards) + (1 if level == 1 else 2)
	if level >= 2:
		c.pirates_first = true
	return c

## "Island 7: Gallows Rock".
static func heading(i: int) -> String:
	return "Island %d: %s" % [i + 1, chapter(i).title]

## A pointer for the island: how its rules play.
static func tip(i: int) -> String:
	return str(chapter(i).get("tip", ""))

static func goal_text(i: int) -> String:
	match str(chapter(i).goal):
		"rescue":
			return "Free Vega and get her aboard your ship."
		"chart":
			return "Get the Star Chart (under the gold X) aboard your ship."
	return "Get more chests aboard than any rival can."

## The island's rules in a line each, for the briefing.
static func rules(i: int) -> Array[String]:
	var c := chapter(i)
	var out: Array[String] = []
	var crews := ["the Pirates", "the Pirates and the Corsairs", "the Pirates, the Corsairs and the Buccaneers"]
	out.append("Against %s (%s), %d sailors each%s." % [crews[int(c.rivals) - 1], GameConfig.DIFFICULTY_NAMES[int(c.difficulty)].to_lower(),
		int(c.rival_crew), (", drilled %d time%s each" % [int(c.drilled), "" if int(c.drilled) == 1 else "s"]) if int(c.drilled) > 0 else ""])
	out.append("A %s%s island. You land %d sailors%s." % ["long and narrow, " if float(c.get("stretch", 1.0)) > 1.0 else "",
		TerrainGrid.LENGTH_NAMES[int(c.length)].to_lower(), party_size(i),
		", plus Vega" if vega_sails(i) else ""])
	if int(c.get("guards", 0)) > 0:
		out.append("Guarded: a stockade with one gate, %d of BlackPatch's best inside, and an ambush on the way. You can't free her while a guard is beside her." % int(c.guards))
		out.append("Outpost: your sailors resting beside it get double energy.")
	if c.get("storm", false):
		out.append("Storm: your crew get back a quarter less energy each turn (the pirates rest as usual), so they fight weaker when tired.")
	if c.get("pirates_first", false):
		out.append("The pirates move first.")
	if c.get("charted", false):
		out.append("Charted: the whole island is mapped from the start.")
	return out

## How many of your crew land: the island's number, or your whole crew if
## it has grown past that (every recruit gets a place), at most 16. Vega
## isn't counted: she comes as well.
static func party_size(i: int) -> int:
	var mine := GameConfig.crew.filter(func(d: Dictionary) -> bool: return str(d.get("special", "")) == "").size()
	return clampi(maxi(int(chapter(i).crew), mine), 1, GameConfig.MAX_TEAM_SIZE)

## Vega sails with you on every island after the one you freed her on.
static func vega_sails(i: int) -> bool:
	return i > RESCUE and won(RESCUE)

# --- progress ------------------------------------------------------------------

static func data() -> Dictionary:
	if _loaded_from != path:
		_loaded_from = path
		_data = {"won": [[], [], []], "captain": false, "records": {}, "done": []}
		var cfg := ConfigFile.new()
		if cfg.load(path) == OK:
			var w: Variant = cfg.get_value("campaign", "won", [])
			# Before the levels, "won" was one list: that's Normal's.
			if w is Array and (w.is_empty() or not w[0] is Array):
				w = [w, [], []]
			if w is Array:
				for lv in mini(w.size(), 3):
					if w[lv] is Array:
						_data.won[lv] = w[lv].filter(func(v: Variant) -> bool: return (v is int or v is float) and int(v) >= 0 and int(v) < CHAPTERS.size()).map(func(v: Variant) -> int: return int(v))
			var dn: Variant = cfg.get_value("campaign", "done", [])
			if dn is Array:
				_data.done = dn.filter(func(v: Variant) -> bool: return (v is int or v is float) and int(v) >= 0 and int(v) < 3).map(func(v: Variant) -> int: return int(v))
			level = clampi(int(cfg.get_value("campaign", "level", 0)), 0, 2)
			_data.captain = bool(cfg.get_value("campaign", "captain", false))
			var r: Variant = cfg.get_value("campaign", "records", {})
			if r is Dictionary:
				_data.records = r
	return _data

static func save() -> void:
	var d := data()
	var cfg := ConfigFile.new()
	cfg.set_value("campaign", "won", d.won)
	cfg.set_value("campaign", "done", d.done)
	cfg.set_value("campaign", "level", level)
	cfg.set_value("campaign", "captain", d.captain)
	cfg.set_value("campaign", "records", d.records)
	cfg.save(path)

static func won(i: int) -> bool:
	return data().won[level].has(i)

static func won_count() -> int:
	return data().won[level].size()

## Every island of level `lv` won.
static func level_done(lv: int) -> bool:
	return data().done.has(lv)

## Chooses the level to play (the campaign screen's tabs).
static func set_level(lv: int) -> void:
	data()
	level = clampi(lv, 0, 2)
	save()

## The furthest island you may sail to: the first one not yet won.
static func next_open() -> int:
	for i in CHAPTERS.size():
		if not won(i):
			return i
	return CHAPTERS.size() - 1

static func unlocked(i: int) -> bool:
	return i >= 0 and i < CHAPTERS.size() and (i == 0 or won(i - 1) or won(i))

## Island `i` is won. Winning the last one makes you a Captain. Returns true
## the first time the campaign is finished (the ending is due).
static func win(i: int) -> bool:
	var d := data()
	if not d.won[level].has(i):
		d.won[level].append(i)
	var first: bool = i == FINAL and not d.done.has(level)
	if i == FINAL:
		d.captain = true
		if not d.done.has(level):
			d.done.append(level)
	save()
	return first

static func is_captain() -> bool:
	return bool(data().captain)

## Adds a finished campaign game's numbers to each sailor's record, by name.
static func add_records(people: Array) -> void:
	var d := data()
	for p in people:
		var name := str(p.get("name", ""))
		if name == "":
			continue
		var r: Dictionary = d.records.get(name, {"found": 0, "aboard": 0, "captures": 0, "islands": 0})
		var t: Dictionary = p.get("tally", {})
		for key in ["found", "aboard", "captures"]:
			r[key] = int(r.get(key, 0)) + int(t.get(key, 0))
		r.islands = int(r.get("islands", 0)) + 1
		d.records[name] = r
	save()

static func record(name: String) -> Dictionary:
	return data().records.get(name, {})

## Start the islands over (Start Over on the campaign screen). A Captain
## stays a Captain unless `all` (the tests).
static func reset(all := false) -> void:
	var d := data()
	if all:
		_data = {"won": [[], [], []], "captain": false, "records": {}, "done": []}
		level = 0
	else:
		d.won[level] = [] # this level starts over; the others, and a Captain, stay
	_loaded_from = path
	save()

## Where the captive is held: open meadow 4-7 squares from the pirates' ship,
## clear of where anyone landed, that the NAVS can reach from their ship.
## The same square every time for the same island.
static func captive_cell(g: TerrainGrid, people: Array) -> Vector2i:
	var taken := {}
	for p in people:
		taken[p.cell] = true
	var ship: Vector2i = g.pirate_ship
	var best := Vector2i(-1, -1)
	var best_score := INF
	for y in g.height:
		for x in g.width:
			var cell := Vector2i(x, y)
			var d: int = maxi(absi(cell.x - ship.x), absi(cell.y - ship.y))
			if d < 4 or d > 7 or taken.has(cell) or not g.is_meadow(cell):
				continue
			var score := absf(d - 5.5) * 10.0 + cell.x * 0.001 + cell.y * 0.00001
			if score < best_score and not g.find_path(g.nav_ship, cell).is_empty():
				best_score = score
				best = cell
	return best if best.x >= 0 else g.landing_cells(ship, 12)[11]

## Gallows Rock's layout, the same every time for the same island: Vega's
## post (open meadow 5-9 squares from the pirates' ship, room for guards
## round it, no X or buried chest near the stockade), the gate in its fence
## (the ring square cheapest to reach from the NAVS' ship), an outpost of
## your own about 40% of the way there, and three ambush spots off the route
## beyond it. {captive, gate, outpost, ambush: [cells]}; {} if there's no room.
static func rescue_layout(g: TerrainGrid) -> Dictionary:
	var from_home := g.move_costs(g.nav_ship)
	var ship := g.pirate_ship
	var best := {}
	var best_score := INF
	for y in range(3, g.height - 3):
		for x in range(3, g.width - 3):
			var c := Vector2i(x, y)
			var d: int = maxi(absi(c.x - ship.x), absi(c.y - ship.y))
			if d < 5 or d > 9 or not g.is_meadow(c):
				continue
			var near_x := false
			for m in g.markers:
				if maxi(absi(m.x - c.x), absi(m.y - c.y)) <= 4:
					near_x = true
			if near_x:
				continue
			var room := 0
			for n in g.neighbours(c):
				room += 1
			if room < 6:
				continue
			var gate := Vector2i(-1, -1)
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if maxi(absi(dx), absi(dy)) != 2 or (absi(dx) == 2 and absi(dy) == 2):
						continue # not the corners: a gate needs a square inside it
					var r := c + Vector2i(dx, dy)
					var inner := c + Vector2i(signi(dx) if absi(dx) == 2 else 0, signi(dy) if absi(dy) == 2 else 0)
					if g.is_walkable(r) and g.is_walkable(inner) and from_home.has(r) \
							and (gate.x < 0 or float(from_home[r]) < float(from_home[gate])):
						gate = r
			if gate.x < 0:
				continue
			var score := absf(d - 7.0) * 10.0 + c.x * 0.001 + c.y * 0.00001
			if score < best_score:
				best_score = score
				best = {"captive": c, "gate": gate}
	if best.is_empty():
		return {}
	var probe := TerrainGrid.new(g.island_seed, g.length, g.teams, g.stretch)
	probe.build_pen(best.captive, best.gate)
	var route := probe.find_path(g.nav_ship, best.gate)
	if route.size() < 6:
		return {}
	best["outpost"] = route[int(route.size() * 0.4)]
	var ambush: Array[Vector2i] = []
	for f in [0.62, 0.72, 0.82]:
		var on: Vector2i = route[mini(int(route.size() * f), route.size() - 2)]
		var ahead: Vector2i = route[mini(int(route.size() * f) + 1, route.size() - 1)]
		var side := Vector2i(-(ahead - on).y, (ahead - on).x)
		if side == Vector2i.ZERO:
			side = Vector2i(1, 0)
		for k in [2, -2, 3, -3, 1, -1]:
			var spot: Vector2i = on + side * k
			if probe.is_walkable(spot) and not ambush.has(spot) and spot != best.outpost:
				ambush.append(spot)
				break
	best["ambush"] = ambush
	return best

## Vega as she is when you first find her: a navigator (she wears a Scout's
## telescope) with skills no recruit starts with. Coaching can take her to
## 100 in anything.
static func make_vega() -> CharacterStats:
	var st := CharacterStats.make(CharacterStats.Kind.SCOUT, VEGA)
	st.special = SPECIAL_VEGA
	st.class_name_ = "Navigator"
	st.speed = 70.0
	st.stamina = 80.0
	st.stealth = 80.0
	st.swordfighting = 60.0
	st.vision = 100.0
	st.digging = 50.0
	st.team_spirit = 80.0
	st.confidence = 40.0
	st.coachable = true # she learns fast, and pushes herself
	st.self_motivated = true
	return st
