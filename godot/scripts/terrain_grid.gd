class_name TerrainGrid
extends RefCounted

## The island's terrain. Pure data + queries (no rendering).
##
## Terrain does two jobs, exactly as in the original (DESIGN_REFERENCE.md §5):
##  1. it costs ENERGY to move through — easy / moderate / difficult, and
##  2. it costs VISION POINTS to see through — clear / medium (8x) / difficult
##     (16x), which is why a scout can see across a meadow but not into a swamp.

enum { WATER, MEADOW, SAND, BUSH, TREES, SWAMP, HILL, FENCE } ## FENCE: a stockade (campaign), never generated

# Islands are big: you can't see the whole thing at a comfortable zoom, and
# crossing one costs most of a full tank of energy.
## How long a game runs: the island's size and how many chests it holds (the
## original's islands held 3, 5, 7 or 9).
enum Length { SHORT, MEDIUM, LONG }
const LENGTH_NAMES := ["Short", "Medium", "Long"]
const SIZES: Array[Vector2i] = [Vector2i(40, 30), Vector2i(52, 38), Vector2i(66, 48)]
const CHESTS := [3, 5, 7]
const MARKER_SPACING := [14, 12, 13] # squares apart (walking distance) the X's try to keep

## More crews need more room and more treasure. A three-crew island is a
## quarter wider and taller than a two-crew one (about 1.6x the land), a
## four-crew island nearly half again (about 2.1x the land). Indexed by crews.
const TEAM_SCALE := [1.0, 1.0, 1.0, 1.25, 1.45]
## Extra chests per crew beyond two, by game length: a medium game holds 5
## chests for two crews, 8 for three and 11 for four.
const EXTRA_CHESTS_PER_TEAM := [2, 3, 4]
## Where each crew's ship lands, as a compass bearing from the island's middle
## (degrees, 0 = east, 90 = south since y grows downward). Two crews face each
## other north and south; three sit evenly round the coast; four take a side each.
const SHIP_BEARINGS := {3: [90.0, 210.0, 330.0], 4: [90.0, 270.0, 180.0, 0.0]}
## With three or four crews, how many candidate layouts of X's are tried, the
## fairest kept (see _fairness), and how far an X must stay from every ship.
const MARKER_LAYOUT_TRIES := 6
const MARKER_SHIP_GAP := 8

static func island_size(length_: int, teams_: int = 2) -> Vector2i:
	var base: Vector2i = SIZES[clampi(length_, 0, 2)]
	var k: float = TEAM_SCALE[clampi(teams_, 0, TEAM_SCALE.size() - 1)]
	return Vector2i(roundi(base.x * k), roundi(base.y * k))

static func chest_count(length_: int, teams_: int = 2) -> int:
	var l := clampi(length_, 0, 2)
	return int(CHESTS[l]) + maxi(0, teams_ - 2) * int(EXTRA_CHESTS_PER_TEAM[l])

## Energy to enter a square while RUNNING; crawling costs 3x.
## TREES and BUSH are absent: vegetation is solid, so you go around it.
const RUN_COST := {
	MEADOW: 2.0, SAND: 4.0, HILL: 4.0, SWAMP: 6.0,
}
## Vision points spent crossing a square. Clear is cheap; woods and swamp are
## nearly opaque.
const SIGHT_COST := {
	MEADOW: 4.0, SAND: 4.0, HILL: 4.0, WATER: 4.0, BUSH: 32.0, TREES: 64.0, SWAMP: 64.0, FENCE: 16.0,
}

## Tie-breaks for find_path between routes of equal energy: prefer the shorter
## route on the ground, then the one hugging the straight line. Summed over any
## route on the island both stay under 2, the cheapest square, so they never
## outweigh energy.
const PATH_LENGTH_WEIGHT := 0.01
## Choosing a route, every step also counts this much on top of its energy, so
## the shorter way wins when it's only a little dearer: across a couple of
## squares of sand (or over a hill) rather than a long way round on grass.
## A step is a step, diagonal or not (it costs the same energy).
## Grass is still preferred when the way round is about as short. (It only
## steers the choice: walking still costs each square's energy.)
const ROUTE_STEP_WEIGHT := 2.0
const PATH_LINE_WEIGHT := 0.0003

const ORTHO: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var cells: Array = []  # cells[y][x] -> tile type
var island_seed := 0
var length: Length = Length.MEDIUM
## How many crews the island is built for (2-4): sets its size, its chests and
## how many ships land. Practice alone uses a two-crew island.
var teams := 2
var width := 52
var height := 38

## Generated placements, chosen to suit whatever island came out. One ship per
## crew, indexed by Character.Team.
var ships: Array[Vector2i] = []
var markers: Array[Vector2i] = []

var nav_ship: Vector2i:
	get:
		return ships[0] if ships.size() > 0 else Vector2i.ZERO
var pirate_ship: Vector2i:
	get:
		return ships[1] if ships.size() > 1 else Vector2i.ZERO

## `stretch_` makes the island longer north to south (the way between two
## crews' ships): a campaign island can ask for it (Gallows Rock).
var stretch := 1.0

func _init(seed_value := 0, length_: Length = Length.MEDIUM, teams_ := 2, stretch_ := 1.0) -> void:
	length = length_
	teams = clampi(teams_, 2, Character.MAX_TEAMS)
	stretch = clampf(stretch_, 1.0, 2.0)
	var dims := island_size(length, teams)
	width = dims.x
	height = roundi(dims.y * stretch)
	generate(seed_value)

func chests() -> int:
	return chest_count(length, teams)

## Builds an organic island from a seed. The SAME seed always produces the SAME
## island, which is what lets two networked players share a map by exchanging a
## single number.
func generate(seed_value: int) -> void:
	island_seed = seed_value
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var shape := FastNoiseLite.new()
	shape.seed = seed_value
	shape.noise_type = FastNoiseLite.TYPE_SIMPLEX
	shape.frequency = rng.randf_range(0.10, 0.17)
	var detail := FastNoiseLite.new()
	detail.seed = seed_value + 1337
	detail.frequency = rng.randf_range(0.13, 0.24)
	var wet := FastNoiseLite.new()
	wet.seed = seed_value + 991
	wet.frequency = rng.randf_range(0.12, 0.20)

	# How much of the grid is land, and how round or ragged the coast is —
	# these are what make one island feel small and tight, another sprawling.
	var fullness := rng.randf_range(0.46, 0.66)
	var squish := rng.randf_range(0.85, 1.30)

	cells.clear()
	for y in height:
		var row := []
		for x in width:
			row.append(WATER if not _is_land(x, y, shape, fullness, squish) else MEADOW)
		cells.append(row)

	_keep_largest_landmass()
	_paint_features(detail, wet)
	_paint_beaches()
	_ensure_meadow(rng)
	# Vegetation is solid now, so being on the same landmass is no longer
	# enough — the WALKABLE ground has to be one piece, or treasure ends up
	# fenced off. Cut paths through the thickets rather than deleting pockets,
	# which would throw away good ground.
	_connect_walkable()
	_place_landmarks(rng)

func _is_land(x: int, y: int, shape: FastNoiseLite, fullness: float, squish: float) -> bool:
	# A radial falloff (so the middle is land and the rim is sea) pushed around
	# by noise, which is what gives bays, capes and a ragged coast.
	var nx := (x + 0.5) / float(width) * 2.0 - 1.0
	var ny := (y + 0.5) / float(height) * 2.0 - 1.0
	var d: float = sqrt(nx * nx + ny * ny * squish)
	var n: float = shape.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
	return (n * 0.55 + (1.0 - d) * 0.80) > (1.0 - fullness)

## Islets are pretty but strand treasure, so keep only the biggest landmass.
func _keep_largest_landmass() -> void:
	var seen := {}
	var best: Array[Vector2i] = []
	for y in height:
		for x in width:
			var start := Vector2i(x, y)
			if cells[y][x] == WATER or seen.has(start):
				continue
			var group: Array[Vector2i] = []
			var queue: Array[Vector2i] = [start]
			seen[start] = true
			var head := 0
			while head < queue.size():
				var cur: Vector2i = queue[head]
				head += 1
				group.append(cur)
				for d in ORTHO:
					var n := cur + d
					if in_bounds(n) and not seen.has(n) and cells[n.y][n.x] != WATER:
						seen[n] = true
						queue.append(n)
			if group.size() > best.size():
				best = group
	var keep := {}
	for c in best:
		keep[c] = true
	for y in height:
		for x in width:
			if not keep.has(Vector2i(x, y)):
				cells[y][x] = WATER

## Woods, bush, swamp and hills, scattered by noise so each island has its own
## character — one heavily wooded, another open with a swampy middle.
func _paint_features(detail: FastNoiseLite, wet: FastNoiseLite) -> void:
	for y in height:
		for x in width:
			if cells[y][x] == WATER:
				continue
			var d: float = detail.get_noise_2d(float(x), float(y))
			var w: float = wet.get_noise_2d(float(x), float(y))
			# Vegetation blocks movement now, so there is much less of it — it
			# forms walls and thickets to route around, not a carpet.
			if d > 0.34:
				cells[y][x] = TREES
			elif d > 0.24:
				cells[y][x] = BUSH
			elif d > 0.13:
				cells[y][x] = HILL
			elif w > 0.42:
				cells[y][x] = SWAMP
			else:
				cells[y][x] = MEADOW

## Any land touching the sea becomes beach — that's where ships land.
func _paint_beaches() -> void:
	var coast: Array[Vector2i] = []
	for y in height:
		for x in width:
			if cells[y][x] == WATER:
				continue
			for d in ORTHO:
				var n := Vector2i(x, y) + d
				if not in_bounds(n) or cells[n.y][n.x] == WATER:
					coast.append(Vector2i(x, y))
					break
	for c in coast:
		cells[c.y][c.x] = SAND

## Treasure can only be buried in meadow, so guarantee there is enough of it.
func _ensure_meadow(rng: RandomNumberGenerator) -> void:
	var meadows := _cells_of(MEADOW).size()
	if meadows >= 60:
		return
	var candidates := _cells_of(BUSH) + _cells_of(TREES)
	_shuffle(candidates, rng)
	for c in candidates:
		if meadows >= 60:
			break
		cells[c.y][c.x] = MEADOW
		meadows += 1

## Makes the walkable ground one connected region by CARVING paths through
## vegetation where it fences a pocket off — so every square of open ground
## stays playable instead of being thrown away.
func _connect_walkable() -> void:
	var comps := _walkable_components()
	if comps.size() <= 1:
		return
	comps.sort_custom(func(a: Array, b: Array) -> bool: return a.size() > b.size())
	var main := {}
	for c in comps[0]:
		main[c] = true
	for i in range(1, comps.size()):
		_carve_to(comps[i][0], main)
		for c in comps[i]:
			main[c] = true

## Walks over ALL land (barriers included) from `from` until it reaches the
## main region, then clears the vegetation along that route.
func _carve_to(from: Vector2i, main: Dictionary) -> void:
	var came := {from: from}
	var queue: Array[Vector2i] = [from]
	var head := 0
	var hit := Vector2i(-1, -1)
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if main.has(cur):
			hit = cur
			break
		for d in ORTHO:
			var n: Vector2i = cur + d
			if in_bounds(n) and not came.has(n) and cells[n.y][n.x] != WATER:
				came[n] = cur
				queue.append(n)
	if hit.x < 0:
		return
	var node := hit
	while node != from:
		if not is_walkable(node):
			cells[node.y][node.x] = MEADOW
			main[node] = true
		node = came[node]

func _walkable_components() -> Array:
	var seen := {}
	var out: Array = []
	for y in height:
		for x in width:
			var start := Vector2i(x, y)
			if not is_walkable(start) or seen.has(start):
				continue
			var group: Array[Vector2i] = []
			var queue: Array[Vector2i] = [start]
			seen[start] = true
			var head := 0
			while head < queue.size():
				var cur: Vector2i = queue[head]
				head += 1
				group.append(cur)
				for n in neighbours(cur):
					if not seen.has(n):
						seen[n] = true
						queue.append(n)
			out.append(group)
	return out

## Ships on opposite coasts, and treasure markers spread across the interior.
func _place_landmarks(rng: RandomNumberGenerator) -> void:
	# A ship needs ROOM around it, or the team lands on a one-tile spit and
	# boxes itself in with nowhere to walk. Only consider beaches with a decent
	# amount of open land within a few steps.
	var beaches := _cells_of(SAND)
	var roomy: Array[Vector2i] = []
	for b in beaches:
		if _open_room(b, 3) >= 14:
			roomy.append(b)
	if roomy.is_empty():
		roomy = beaches
	ships.clear()
	if teams <= 2:
		# The classic pair, placed exactly as before so two-crew islands (and
		# saved games, which rebuild the island from its seed) don't change.
		roomy.sort_custom(func(a, b): return a.y > b.y)
		ships.append(roomy[0] if not roomy.is_empty() else Vector2i(width / 2, height - 3))
		roomy.sort_custom(func(a, b): return a.y < b.y)
		ships.append(roomy[0] if not roomy.is_empty() else Vector2i(width / 2, 2))
		_place_markers_classic(rng)
		return
	for bearing in SHIP_BEARINGS[teams]:
		ships.append(_ship_spot(roomy, float(bearing)))
	_place_markers_fair(rng)

## The X's for a two-crew island: random meadow, kept apart from each other.
func _place_markers_classic(rng: RandomNumberGenerator) -> void:
	markers.clear()
	var want := chests()
	var meadows := _cells_of(MEADOW)
	_shuffle(meadows, rng)
	for c in meadows:
		if markers.size() >= want:
			break
		# Needs a meadow neighbour to bury the chest in, and room from the others.
		if _meadow_neighbours(c).is_empty():
			continue
		var far := true
		for m in markers:
			if absi(m.x - c.x) + absi(m.y - c.y) < MARKER_SPACING[length]:
				far = false
				break
		if far and absi(c.y - ships[0].y) > 2:
			markers.append(c)
	_fill_markers(meadows, want)

## Relax the spacing if the island is too cramped to satisfy it.
func _fill_markers(meadows: Array[Vector2i], want: int) -> void:
	if markers.size() < want:
		for c in meadows:
			if markers.size() >= want:
				break
			if not markers.has(c) and not _meadow_neighbours(c).is_empty():
				markers.append(c)

## The beach furthest out along `bearing` from the island's middle, skipping
## any too close to a ship already placed.
func _ship_spot(roomy: Array[Vector2i], bearing: float) -> Vector2i:
	var mid := Vector2(width, height) / 2.0
	var dir := Vector2(cos(deg_to_rad(bearing)), sin(deg_to_rad(bearing)))
	var best := Vector2i(-1, -1)
	var best_score := -INF
	for b in roomy:
		var crowded := false
		for s in ships:
			if absi(s.x - b.x) + absi(s.y - b.y) < 12:
				crowded = true
				break
		if crowded:
			continue
		var off := Vector2(b) + Vector2(0.5, 0.5) - mid
		# Mostly how far out along the bearing; a little for staying on its line.
		var score := off.dot(dir) - absf(off.cross(dir)) * 0.35
		if score > best_score:
			best_score = score
			best = b
	if best.x < 0:
		var edge := mid + dir * (minf(width, height) / 2.0 - 3.0)
		best = Vector2i(clampi(int(edge.x), 1, width - 2), clampi(int(edge.y), 1, height - 2))
	return best

## The X's for three or four crews. Treasure that happens to land near one
## crew's ship decides the game before it starts, so several layouts are drawn
## and the one that treats every crew most evenly is kept.
func _place_markers_fair(rng: RandomNumberGenerator) -> void:
	var want := chests()
	var meadows := _cells_of(MEADOW)
	var from_ships: Array = []
	for s in ships:
		from_ships.append(move_costs(s))
	var best: Array[Vector2i] = []
	var best_score := INF
	for attempt in MARKER_LAYOUT_TRIES:
		_shuffle(meadows, rng)
		markers.clear()
		for c in meadows:
			if markers.size() >= want:
				break
			if _meadow_neighbours(c).is_empty():
				continue
			var ok := true
			for s in ships:
				if absi(s.x - c.x) + absi(s.y - c.y) < MARKER_SHIP_GAP:
					ok = false
					break
			if ok:
				for m in markers:
					if absi(m.x - c.x) + absi(m.y - c.y) < MARKER_SPACING[length]:
						ok = false
						break
			if ok:
				markers.append(c)
		_fill_markers(meadows, want)
		var score := _fairness(from_ships)
		if score < best_score:
			best_score = score
			best = markers.duplicate()
	markers = best

## How unevenly the X's sit between the ships: for each crew, the walking cost
## to its nearest few X's (as many as it would take to win outright), and the
## gap between the luckiest crew and the unluckiest. Lower is fairer.
func _fairness(from_ships: Array) -> float:
	var take := maxi(1, ceili(markers.size() / float(ships.size())) + 1)
	var lo := INF
	var hi := -INF
	for costs in from_ships:
		var d: Array[float] = []
		for m in markers:
			d.append(float(costs.get(m, 999.0)))
		d.sort()
		var sum := 0.0
		for i in mini(take, d.size()):
			sum += d[i]
		lo = minf(lo, sum)
		hi = maxf(hi, sum)
	return hi - lo

## How much open land is reachable within `radius` steps — used to avoid
## landing a team somewhere they can't spread out.
func _open_room(c: Vector2i, radius: int) -> int:
	var seen := {c: true}
	var frontier: Array[Vector2i] = [c]
	for i in radius:
		var nxt: Array[Vector2i] = []
		for cur in frontier:
			for n in neighbours(cur):
				if not seen.has(n):
					seen[n] = true
					nxt.append(n)
		frontier = nxt
	return seen.size()

## Array.shuffle() draws on Godot's GLOBAL rng, which would make the same seed
## produce different islands — and desync two networked players. Shuffle from
## the island's own rng instead.
func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi() % (i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

func _meadow_neighbours(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in neighbours(c):
		if tile_type(n) == MEADOW:
			out.append(n)
	return out

func _cells_of(tile: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in height:
		for x in width:
			if cells[y][x] == tile:
				out.append(Vector2i(x, y))
	return out

## Squares to land a team on, near `near`. Keeps the squares right round the
## ship clear (LANDING_CLEAR steps), so nobody stands in the way of a chest
## coming aboard, unless there's no room further out. Prefers OPEN ground and
## then checks that nobody ends up walled in by their own team-mates —
## otherwise a party can land in a chain along a narrow spit and be unable to
## move at all.
const LANDING_CLEAR := 2
func landing_cells(near: Vector2i, count: int) -> Array[Vector2i]:
	var pool: Array[Vector2i] = []
	var dist := {near: 0}
	var queue: Array[Vector2i] = [near]
	var head := 0
	while head < queue.size() and pool.size() < 70:
		var cur: Vector2i = queue[head]
		head += 1
		if cur != near:
			pool.append(cur)
		for n in neighbours(cur):
			if not dist.has(n):
				dist[n] = int(dist[cur]) + 1
				queue.append(n)
	pool.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var ca: bool = int(dist[a]) > LANDING_CLEAR
		var cb: bool = int(dist[b]) > LANDING_CLEAR
		if ca != cb:
			return ca # clear of the ship first
		var oa: int = neighbours(a).size()
		var ob: int = neighbours(b).size()
		if oa != ob:
			return oa > ob
		return int(dist[a]) < int(dist[b]))

	var chosen: Array[Vector2i] = []
	var taken := {}
	for c in pool:
		if chosen.size() >= count:
			break
		taken[c] = true
		chosen.append(c)

	# Swap out anyone with no free square to step into.
	for i in chosen.size():
		if _has_free_neighbour(chosen[i], taken):
			continue
		for alt in pool:
			if taken.has(alt) or not _has_free_neighbour(alt, taken):
				continue
			taken.erase(chosen[i])
			taken[alt] = true
			chosen[i] = alt
			break
	return chosen

func _has_free_neighbour(c: Vector2i, taken: Dictionary) -> bool:
	for n in neighbours(c):
		if not taken.has(n):
			return true
	return false

## A stockade round `center`: a ring of fence `radius` squares out (two for a
## captive's pen, three for a stronghold), open only at
## `gate`. Woods and water in the ring already keep people out.
func build_pen(center: Vector2i, gate: Vector2i, radius := 2) -> void:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if maxi(absi(dx), absi(dy)) != radius:
				continue
			var cell := center + Vector2i(dx, dy)
			if cell != gate and is_walkable(cell):
				cells[cell.y][cell.x] = FENCE

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < width and c.y < height

func tile_type(c: Vector2i) -> int:
	return cells[c.y][c.x]

## Vegetation is solid: you walk around woods and thickets, not through them.
## Cover for hiding is SWAMP and the lee of a HILL, both of which are walkable
## and expensive to see through.
func is_walkable(c: Vector2i) -> bool:
	if not in_bounds(c):
		return false
	var t: int = cells[c.y][c.x]
	return t != WATER and t != TREES and t != BUSH and t != FENCE

## Energy to step into this square in the given stance.
func move_cost(c: Vector2i, crawling: bool) -> float:
	if not is_walkable(c):
		return -1.0
	var base: float = RUN_COST.get(tile_type(c), 2.0)
	return base * (3.0 if crawling else 1.0) # crawling costs 3x

func sight_cost(c: Vector2i) -> float:
	return SIGHT_COST.get(tile_type(c), 4.0)

## Treasure is only ever buried in clear meadow, as in the original.
func is_meadow(c: Vector2i) -> bool:
	return in_bounds(c) and tile_type(c) == MEADOW

## The route someone walks from -> to, as a list of cells EXCLUDING the start.
## Cheapest first, counting each square's energy plus a little for every step
## (ROUTE_STEP_WEIGHT), so a short way over sand or a hill beats a long way
## round on grass. Among equally cheap routes, the one that stays closest to the
## straight line, so people walk where you'd expect instead of zig-zagging (on
## a grid there are dozens of routes with the same number of steps). `blocked`
## holds cells that are walkable terrain but occupied (people), so routes go
## AROUND them instead of stopping dead.
func find_path(from: Vector2i, to: Vector2i, blocked: Dictionary = {}) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if from == to or not is_walkable(to) or blocked.has(to):
		return result
	var line := Vector2(to - from)
	var line_len := maxf(line.length(), 0.001)
	var best := {from: 0.0}
	var came := {}
	var heap_cost: Array[float] = []
	var heap_cell: Array[Vector2i] = []
	_heap_push(heap_cost, heap_cell, 0.0, from)
	while not heap_cell.is_empty():
		var cur := _heap_pop(heap_cost, heap_cell)
		if cur == to:
			break
		for n in neighbours(cur):
			if blocked.has(n):
				continue
			# Energy, then a whisker for length and for straying off the line —
			# too small ever to outweigh a single square's energy.
			var off := absf(line.x * (n.y - from.y) - line.y * (n.x - from.x)) / line_len
			var step := 1.0 if (n.x == cur.x or n.y == cur.y) else 1.4142
			var cost: float = float(best[cur]) + move_cost(n, false) + ROUTE_STEP_WEIGHT + step * PATH_LENGTH_WEIGHT + off * PATH_LINE_WEIGHT
			if best.has(n) and float(best[n]) <= cost:
				continue
			best[n] = cost
			came[n] = cur
			# Every step counts at least 2 + ROUTE_STEP_WEIGHT, so that many per
			# step left never overestimates.
			var left: Vector2i = (to - n).abs()
			_heap_push(heap_cost, heap_cell, cost + (2.0 + ROUTE_STEP_WEIGHT) * maxi(left.x, left.y), n)
	if not came.has(to):
		return result
	var node := to
	while node != from:
		result.push_front(node)
		node = came[node]
	return result

func _heap_push(costs: Array[float], cells: Array[Vector2i], cost: float, cell: Vector2i) -> void:
	costs.append(cost)
	cells.append(cell)
	var i := costs.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if costs[parent] <= costs[i]:
			break
		_heap_swap(costs, cells, i, parent)
		i = parent

func _heap_pop(costs: Array[float], cells: Array[Vector2i]) -> Vector2i:
	var top := cells[0]
	var last := costs.size() - 1
	_heap_swap(costs, cells, 0, last)
	costs.resize(last)
	cells.resize(last)
	var i := 0
	while true:
		var smallest := i
		for child in [2 * i + 1, 2 * i + 2]:
			if child < last and costs[child] < costs[smallest]:
				smallest = child
		if smallest == i:
			break
		_heap_swap(costs, cells, i, smallest)
		i = smallest
	return top

func _heap_swap(costs: Array[float], cells: Array[Vector2i], a: int, b: int) -> void:
	var c := costs[a]
	costs[a] = costs[b]
	costs[b] = c
	var v := cells[a]
	cells[a] = cells[b]
	cells[b] = v

## The 8 walkable neighbours. Diagonals only when both adjacent orthogonals are
## open, so people can't slip through a corner gap.
func neighbours(c: Vector2i) -> Array[Vector2i]:
	# Whether each square of the 3x3 block round `c` can be walked on, read
	# once (this runs for every square of every route the computer weighs).
	var w := PackedByteArray()
	w.resize(9)
	for dy in 3:
		var y := c.y + dy - 1
		if y < 0 or y >= height:
			continue
		var row: Array = cells[y]
		for dx in 3:
			var x := c.x + dx - 1
			if x < 0 or x >= width:
				continue
			var t: int = row[x]
			w[dy * 3 + dx] = 1 if t != WATER and t != TREES and t != BUSH and t != FENCE else 0
	var out: Array[Vector2i] = []
	# Row by row, as before, so routes come out the same. A diagonal step
	# needs both squares beside it open (no cutting a corner).
	for i in [0, 1, 2, 3, 5, 6, 7, 8]:
		if w[i] == 0:
			continue
		var dx: int = i % 3 - 1
		var dy: int = int(i / 3) - 1
		if dx != 0 and dy != 0 and (w[4 + dx] == 0 or w[(1 + dy) * 3 + 1] == 0):
			continue
		out.append(Vector2i(c.x + dx, c.y + dy))
	return out

## Which cells someone at `from` can see, given a budget of vision points.
## Points are spent crossing terrain, so sight reaches far over meadow and dies
## quickly in woods — the original's model. Standing on a hill adds 33%.
func visible_from(from: Vector2i, vision_points: float) -> Array[Vector2i]:
	var budget := vision_points
	if in_bounds(from) and tile_type(from) == HILL:
		budget *= 1.33
	var seen: Array[Vector2i] = [from]
	# You can always see the squares you could reach out and touch, whatever
	# your eyesight or stance — otherwise a poor-sighted runner reveals nothing
	# at all and the fog never lifts.
	for d in _sight_neighbours(from):
		seen.append(d)
	var best := {from: 0.0}
	var marked := {from: true}
	for d in seen:
		marked[d] = true
	var queue: Array[Vector2i] = [from]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		var spent: float = best[cur]
		for n in _sight_neighbours(cur):
			var cost: float = spent + sight_cost(n)
			# You can always SEE the thing that stops your view — the wall of
			# trees in front of you is visible; it's what lies BEYOND it that
			# stays dark. Without this a wood never appears at all.
			if not marked.has(n):
				marked[n] = true
				seen.append(n)
			if cost > budget:
				continue
			if best.has(n) and best[n] <= cost:
				continue
			best[n] = cost
			queue.append(n)
	return seen

## The cheapest sight cost from `from` to every square within `budget`, for
## spotting people (as opposed to revealing terrain). Costs come back already
## divided by the hill bonus, so a caller compares them straight against a
## vision budget.
func sight_costs(from: Vector2i, budget: float) -> Dictionary:
	var hill := 1.33 if in_bounds(from) and tile_type(from) == HILL else 1.0
	var best := {from: 0.0}
	var queue: Array[Vector2i] = [from]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for n in _sight_neighbours(cur):
			var cost: float = float(best[cur]) + sight_cost(n) / hill
			if cost > budget or (best.has(n) and float(best[n]) <= cost):
				continue
			best[n] = cost
			queue.append(n)
	return best

## The cheapest energy, running, from `from` to every square it can reach —
## for the computer player, choosing where to go. `blocked` squares are walked
## around; `factor` scales every step (2.0 when carrying a chest).
## Cheapest first (Dijkstra, with a heap), so each square is settled once: the
## old first-come queue went back over the same squares again and again, and
## with a big island and a dozen computer sailors that made the game stutter.
func move_costs(from: Vector2i, blocked: Dictionary = {}, factor := 1.0) -> Dictionary:
	var best := {from: 0.0}
	var done := {}
	var heap_cost: Array[float] = []
	var heap_cell: Array[Vector2i] = []
	_heap_push(heap_cost, heap_cell, 0.0, from)
	while not heap_cell.is_empty():
		var at := heap_cost[0]
		var cur := _heap_pop(heap_cost, heap_cell)
		if done.has(cur) or at > float(best[cur]):
			continue # an older, dearer way here
		done[cur] = true
		for n in neighbours(cur):
			if blocked.has(n) or done.has(n):
				continue
			var cost: float = at + move_cost(n, false) * factor
			if best.has(n) and float(best[n]) <= cost:
				continue
			best[n] = cost
			_heap_push(heap_cost, heap_cell, cost, n)
	return best

## Sight ignores whether terrain is walkable — you can see across water.
func _sight_neighbours(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var n := c + Vector2i(dx, dy)
			if in_bounds(n):
				out.append(n)
	return out
