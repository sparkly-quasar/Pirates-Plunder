class_name Character
extends Node2D

## One team member: a view plus the state the authority owns. It decides
## nothing — GameServer sets energy, drives digging, and calls move_to().
##
## Appearance follows the original exactly (DESIGN_REFERENCE.md §2): energy is
## readable straight off the sprite, in four tiers.
##   > 75  standing, arms moving
##   50-75 standing, still
##   25-50 standing but head down (tired)
##   < 25  sitting on the ground
## Stance changes the posture too: running leans into a stride, crawling goes flat.

const TILE := 32

enum Stance { STANDING, RUNNING, CRAWLING }
## Up to four crews share an island. NAVS and PIRATES are the classic pair;
## the CORSAIRS and BUCCANEERS join in three- and four-crew games.
enum Team { NAVS, PIRATES, CORSAIRS, BUCCANEERS }
const MAX_TEAMS := 4

## Per crew: shirt, hat, hat band, and a lighter shade for text and the maps.
## Pirates keep their black hat with a bone-white band (DESIGN_REFERENCE.md §10);
## each crew's hat differs as well as its shirt, so the crews stay apart for
## players who find some of the colours hard to tell apart.
const SHIRTS := [Color(0.16, 0.20, 0.75), Color(0.74, 0.14, 0.12), Color(0.88, 0.66, 0.10), Color(0.13, 0.52, 0.27)]
const HATS := [Color(0.09, 0.11, 0.30), Color(0.08, 0.06, 0.06), Color(0.42, 0.16, 0.06), Color(0.88, 0.86, 0.78)]
const BANDS := [Color(0.93, 0.95, 1.0), Color(0.92, 0.88, 0.80), Color(0.10, 0.08, 0.06), Color(0.13, 0.40, 0.20)]
const UI_COLOURS := [Color(0.55, 0.7, 1.0), Color(1.0, 0.5, 0.45), Color(1.0, 0.82, 0.35), Color(0.5, 0.9, 0.55)]
## The flag each crew's ship flies, and the colour of its ship on the maps.
const FLAGS := [Color(0.25, 0.5, 0.95), Color(0.85, 0.22, 0.2), Color(0.95, 0.74, 0.15), Color(0.2, 0.72, 0.36)]

static func ui_colour(t: int) -> Color:
	return UI_COLOURS[clampi(t, 0, MAX_TEAMS - 1)]

static func flag_colour(t: int) -> Color:
	return FLAGS[clampi(t, 0, MAX_TEAMS - 1)]

static func hat_colour(t: int) -> Color:
	return HATS[clampi(t, 0, MAX_TEAMS - 1)]

static func band_colour(t: int) -> Color:
	return BANDS[clampi(t, 0, MAX_TEAMS - 1)]

var stats: CharacterStats
var cell: Vector2i
var team: Team = Team.NAVS
var id := 0                                 # index in GameServer.characters, same on every peer
const VEGA_GOLD := Color(0.86, 0.66, 0.16)
var team_color := Color(0.16, 0.20, 0.75)   # NAVS blue; each crew has its own (SHIRTS)
var hat_color := Color(0.09, 0.11, 0.30)
var hat_stripe := Color(0.93, 0.95, 1.0)

## Taken in a sword fight: off the island for the rest of the expedition.
var captured := false
## Locked in a duel — drawn facing the opponent with blade raised.
var fighting := false
## 1 faces right, -1 faces left. Only fights turn people round.
var facing := 1.0

var energy := 0.0
var carrying := false
var bare := false                           # a picture (the ending): no combat bar
var captive := false                        # held prisoner on a campaign island: tied to a post
var chart := false                           # the chest in their arms is the Star Chart (campaign)
var stance: Stance = Stance.STANDING

## Per-character march orders, stepped by the authority.
var path: Array[Vector2i] = []
var step_timer := 0.0

var digging := false
var dig_cell: Vector2i
var dig_elapsed := 0.0
var dig_progress := 0.0

var anim := 0.0
var moving := false

var _tween: Tween

func setup(start_cell: Vector2i, character_stats: CharacterStats, side: Team = Team.NAVS) -> void:
	stats = character_stats
	cell = start_cell
	team = side
	var t := clampi(int(side), 0, MAX_TEAMS - 1)
	team_color = SHIRTS[t]
	hat_color = HATS[t]
	hat_stripe = BANDS[t]
	if stats != null and stats.special == Campaign.SPECIAL_VEGA:
		team_color = VEGA_GOLD # the fleet's finest navigator, in gold
		hat_stripe = Color(1.0, 0.86, 0.35)
	energy = CharacterStats.MAX_ENERGY
	position = cell_to_pos(start_cell)

func _process(delta: float) -> void:
	anim += delta
	queue_redraw()

func move_to(target: Vector2i) -> void:
	cell = target
	moving = true
	if _tween and _tween.is_running():
		_tween.kill()
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE)
	_tween.tween_property(self, "position", cell_to_pos(target), minf(stats.step_time() * 0.8, 0.25))
	_tween.finished.connect(_on_step_done)

# A method, not a lambda: if the scene changes mid-step, Godot drops the
# connection with the character instead of calling into a freed one.
func _on_step_done() -> void:
	moving = not path.is_empty()

func begin_dig(at_cell: Vector2i) -> void:
	digging = true
	dig_cell = at_cell
	dig_elapsed = 0.0
	dig_progress = 0.0

func set_carrying(value: bool) -> void:
	carrying = value
	queue_redraw()

func combat_strength() -> float:
	return stats.combat_strength(energy) if stats else 0.0

## How far this person can currently see. Standing sees four times as far as
## running or crawling (DESIGN_REFERENCE.md §3).
func vision_points() -> float:
	if stats == null:
		return 0.0
	var factor := 1.0 if stance == Stance.STANDING and not moving else 0.25
	return stats.vision * factor

## 0 = fresh, 3 = exhausted. Drives which posture is drawn.
func fatigue_tier() -> int:
	if energy >= 75.0:
		return 0
	if energy >= 50.0:
		return 1
	if energy >= 25.0:
		return 2
	return 3

static func cell_to_pos(c: Vector2i) -> Vector2:
	return Vector2(c.x * TILE + TILE / 2.0, c.y * TILE + TILE / 2.0)

# --- drawing ---------------------------------------------------------------
#
# Limbs are jointed: each arm and leg is an upper and a lower segment hinged at
# elbow/knee, so they actually articulate as the character runs, digs or sits.
# Angles are radians, 0 = right, +Y = down (Godot's convention).

const SKIN := Color(0.97, 0.82, 0.66)
const TROUSER := Color(0.90, 0.88, 0.80)
const BOOT := Color(0.20, 0.13, 0.09)
const INK := Color(0.05, 0.05, 0.11)

## Draws a two-segment limb and returns where it ends (the hand or foot).
func _limb(origin: Vector2, a1: float, l1: float, a2: float, l2: float,
		col: Color, w: float) -> Vector2:
	var joint := origin + Vector2(cos(a1), sin(a1)) * l1
	var tip := joint + Vector2(cos(a2), sin(a2)) * l2
	draw_line(origin, joint, col, w)
	draw_line(joint, tip, col, w)
	draw_circle(joint, w * 0.5, col) # knee/elbow keeps the joint solid
	return tip

func _draw() -> void:
	draw_rect(Rect2(-8, 9, 16, 4), Color(0, 0, 0, 0.22)) # ground shadow
	if captive and captured:
		_draw_post()
	# Mirror the figure to face an opponent; the combat bar stays on the left.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(facing, 1.0))
	var tier := fatigue_tier()
	if stance == Stance.CRAWLING:
		_draw_crawling()
	elif tier == 3:
		_draw_sitting()
	else:
		_draw_upright(tier)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if captive and captured:
		for y in [-2.0, 3.0]:
			draw_line(Vector2(-7, y), Vector2(8, y + 1.0), Color(0.80, 0.68, 0.42), 1.6) # the rope
		return
	if not bare:
		_draw_combat_bar()

## The stake a captive is tied to.
func _draw_post() -> void:
	draw_rect(Rect2(5.0, -16.0, 3.5, 27.0), Color(0.40, 0.26, 0.12))
	draw_rect(Rect2(5.0, -16.0, 3.5, 27.0), INK, false, 1.0)

func _draw_upright(tier: int) -> void:
	var running := stance == Stance.RUNNING or moving
	# A rested Runner jogs on the spot, so you can tell them at a glance.
	var jogging := not running and not fighting and tier <= 1 and stats != null and stats.kind == CharacterStats.Kind.RUNNER
	# Gait: a full swing when running, a small idle sway only at top energy.
	var swing := 0.0
	if running:
		swing = sin(anim * 11.0)
	elif jogging:
		swing = sin(anim * 9.0) * 0.8
	elif fighting:
		swing = sin(anim * 7.0) * 0.3
	elif tier == 0:
		swing = sin(anim * 2.6) * 0.25
	var slump := 0.0 if tier <= 1 else (2.0 if tier == 2 else 4.0)
	if jogging:
		slump = -absf(sin(anim * 9.0)) * 1.2 # a little bounce with each step
	var lean := 2.0 if running else 0.0
	var limbs_running := running or jogging

	# Proportions: head ~ -13, torso -9..+1, legs +1..+11. Shoulders and hips sit
	# OUTSIDE the torso silhouette so the limbs actually read.
	var hip_y := 1.0 + slump
	var sh_y := -7.0 + slump

	# Back limbs first, darker, so the figure has depth.
	_draw_leg(Vector2(-2.5 + lean * 0.5, hip_y), -swing, limbs_running, TROUSER.darkened(0.28), BOOT.lightened(0.08))
	_draw_arm(Vector2(-5.5 + lean, sh_y), -swing, limbs_running, team_color.darkened(0.35), -1.0)

	_draw_torso(slump, lean)

	# Front limbs. A Scout's near arm is up, holding the telescope to the eye.
	_draw_leg(Vector2(2.5 + lean * 0.5, hip_y), swing, limbs_running, TROUSER, BOOT)
	var spying := not fighting and stats != null and stats.kind == CharacterStats.Kind.SCOUT
	var hand := Vector2.ZERO
	if not spying:
		hand = _draw_arm(Vector2(5.5 + lean, sh_y), swing, limbs_running, team_color.darkened(0.10), 1.0)

	_draw_head(slump, lean, tier)
	if fighting:
		_draw_fight_blade(hand)
	elif spying:
		_draw_telescope(Vector2(5.5 + lean, sh_y), slump, lean, tier)
	else:
		_draw_class_prop(hand, slump, lean, tier)
	if carrying:
		_draw_held_chest(slump)
		_draw_carry_badge(-27.0 + slump)

func _draw_leg(hip: Vector2, swing: float, running: bool, cloth: Color, boot: Color) -> void:
	var amp := 0.5 if running else 0.08
	var thigh := PI / 2.0 + swing * amp
	var shin := PI / 2.0 + swing * amp * 0.4 + (0.4 if running and swing < 0.0 else 0.0)
	var foot := _limb(hip, thigh, 5.0, shin, 5.0, cloth, 3.2)
	draw_rect(Rect2(foot.x - 2.2, foot.y - 0.5, 5.0, 2.8), boot)

## `side` is -1 for the far arm, +1 for the near one, so both angle outward
## from the body instead of vanishing behind it.
func _draw_arm(shoulder: Vector2, swing: float, running: bool, cloth: Color, side: float) -> Vector2:
	var amp := 0.7 if running else 0.14
	var upper := PI / 2.0 - swing * amp - side * 0.22
	var lower := upper + side * (0.55 if running else 0.22)
	var hand := _limb(shoulder, upper, 4.5, lower, 4.2, cloth, 2.9)
	draw_circle(hand, 1.9, SKIN)
	return hand

func _draw_torso(slump: float, lean: float) -> void:
	# Narrow enough that the arms clear it on both sides.
	var body := PackedVector2Array([
		Vector2(-4.5 + lean, -9 + slump), Vector2(4.5 + lean, -9 + slump),
		Vector2(5.0, 1 + slump), Vector2(-5.0, 1 + slump),
	])
	draw_colored_polygon(body, team_color)
	draw_polyline(body + PackedVector2Array([body[0]]), INK, 1.0)
	draw_rect(Rect2(-5.0, -0.6 + slump, 10, 1.8), Color(0.14, 0.10, 0.07)) # belt
	draw_rect(Rect2(-1.1, -0.6 + slump, 2.2, 1.8), Color(0.82, 0.68, 0.26)) # buckle

## In a duel everyone draws steel: a blade raised up and forward, so two
## fighters on neighbouring squares cross swords between them.
func _draw_fight_blade(hand: Vector2) -> void:
	var tip := hand + Vector2(12.0, -10.0 + sin(anim * 9.0) * 2.0)
	draw_line(hand + Vector2(-1.5, 1.5), hand + Vector2(1.5, -1.5), Color(0.72, 0.60, 0.28), 3.0)
	draw_line(hand, tip, Color(0.92, 0.94, 0.98), 2.2)
	draw_line(hand, tip, Color(0.55, 0.58, 0.66, 0.6), 1.0)

func _draw_head(slump: float, lean: float, tier: int) -> void:
	var hat := hat_color
	var hx := lean
	var hy := -13.0 + slump + (1.5 if tier >= 2 else 0.0) # head drops when tired
	draw_circle(Vector2(hx, hy), 4.2, SKIN)
	draw_arc(Vector2(hx, hy), 4.2, 0, TAU, 16, INK, 1.0)
	# Tricorne: crown, wide brim, pale band.
	draw_rect(Rect2(hx - 3.2, hy - 7.0, 6.4, 3.6), hat)
	draw_rect(Rect2(hx - 6.0, hy - 4.2, 12, 2.4), hat)
	draw_rect(Rect2(hx - 3.2, hy - 4.3, 6.4, 1.3), hat_stripe)

## The prop that identifies the class, held in the near hand.
func _draw_class_prop(hand: Vector2, slump: float, lean: float, _tier: int) -> void:
	if stats == null:
		return
	match stats.kind:
		CharacterStats.Kind.DIGGER:
			# A spade: a wooden shaft with a D-grip above the hand, and a
			# pointed steel blade that bites the ground while digging.
			var bite := absf(sin(anim * 9.0)) * 3.5 if digging else 0.0
			var top := hand + Vector2(-1.5, -6.0 + bite)
			var neck := hand + Vector2(2.2, 7.5 + bite)
			var wood := Color(0.55, 0.37, 0.17)
			draw_line(top, neck, wood, 1.8) # shaft
			draw_line(top + Vector2(-2.0, 0.0), top + Vector2(2.0, 0.0), wood, 1.8) # D-grip
			draw_line(top + Vector2(-2.0, 0.0), top + Vector2(-1.2, 1.8), wood, 1.4)
			draw_line(top + Vector2(2.0, 0.0), top + Vector2(1.2, 1.8), wood, 1.4)
			var blade := PackedVector2Array([neck + Vector2(-2.8, 0.0), neck + Vector2(2.8, 0.0),
				neck + Vector2(2.4, 3.6), neck + Vector2(0.0, 5.6), neck + Vector2(-2.4, 3.6)])
			draw_colored_polygon(blade, Color(0.74, 0.76, 0.80))
			draw_polyline(blade + PackedVector2Array([blade[0]]), INK, 1.0)
			draw_circle(hand, 1.9, SKIN) # the hand round the shaft
		CharacterStats.Kind.SWORDSMAN:
			# Blade drawn, angled up and back over the shoulder.
			draw_line(hand + Vector2(-2, 0), hand + Vector2(2.5, 0), Color(0.72, 0.60, 0.28), 3.0)
			draw_line(hand, hand + Vector2(5, -13), Color(0.92, 0.94, 0.98), 2.4)
			draw_line(hand, hand + Vector2(5, -13), Color(0.55, 0.58, 0.66, 0.6), 1.0)
		CharacterStats.Kind.FIGHTER:
			# A short sword held forward and up: plainly smaller than the
			# Swordsman's blade.
			var tip := hand + Vector2(5.5, -6.5)
			draw_line(hand + Vector2(-1.6, -1.2), hand + Vector2(1.4, 1.4), Color(0.72, 0.60, 0.28), 2.4) # guard
			draw_line(hand, tip, Color(0.88, 0.90, 0.95), 2.0)
			draw_line(hand, tip, Color(0.55, 0.58, 0.66, 0.6), 0.8)
			draw_circle(hand, 1.9, SKIN)
		CharacterStats.Kind.RUNNER:
			pass # no prop — the gait is the tell

## The Scout's near arm, raised so the hand holds the telescope up to the
## eye; the telescope points out ahead, brass with a wider far end.
func _draw_telescope(shoulder: Vector2, slump: float, lean: float, tier: int) -> void:
	var eye := Vector2(lean + 2.6, -13.0 + slump + (1.5 if tier >= 2 else 0.0))
	var grip := eye + Vector2(5.0, 0.6) # where the hand holds it
	var elbow := shoulder + Vector2(3.2, 2.2)
	var sleeve := team_color.darkened(0.10)
	draw_line(shoulder, elbow, sleeve, 2.9)
	draw_line(elbow, grip, sleeve, 2.7)
	var far := eye + Vector2(11.5, -1.6)
	draw_line(eye + Vector2(0.5, 0.0), eye + Vector2(6.0, -0.8), Color(0.60, 0.48, 0.22), 2.6) # eyepiece
	draw_line(eye + Vector2(6.0, -0.8), far, Color(0.74, 0.60, 0.26), 3.4)
	draw_circle(far + Vector2(0.4, 0.0), 2.0, Color(0.92, 0.82, 0.45))
	draw_circle(grip, 1.9, SKIN)

## Below 25 energy they sit on the ground, legs out front.
func _draw_sitting() -> void:
	var hip := Vector2(-1.0, 4.0)
	_limb(hip, -0.15, 6.0, 0.35, 5.5, TROUSER, 3.6)
	var foot := hip + Vector2(11.5, 0.5)
	draw_rect(Rect2(foot.x, foot.y - 1.0, 3.0, 3.5), BOOT)
	var body := PackedVector2Array([
		Vector2(-5, -3), Vector2(5, -3), Vector2(6, 5), Vector2(-6, 5)])
	draw_colored_polygon(body, team_color)
	draw_polyline(body + PackedVector2Array([body[0]]), INK, 1.0)
	_limb(Vector2(3.0, -2.0), 0.5, 4.0, 1.3, 3.5, team_color.darkened(0.12), 3.0)
	draw_circle(Vector2(0, -7.5), 4.6, SKIN)
	draw_rect(Rect2(-3.5, -13.0, 7, 4), hat_color)
	draw_rect(Rect2(-6.5, -10.0, 13, 2.6), hat_color)
	draw_rect(Rect2(-3.5, -10.1, 7, 1.4), hat_stripe)
	if carrying:
		_draw_held_chest(2.0)
		_draw_carry_badge(-20.0)

## Flat to the ground: hardest to see, dearest to move.
func _draw_crawling() -> void:
	var sway := sin(anim * 6.0) * 0.18 if moving else 0.0
	# Legs trailing behind, knees bent out.
	_limb(Vector2(-2.0, 4.0), PI - 0.25 + sway, 5.5, PI + 0.30, 5.0, TROUSER.darkened(0.15), 3.4)
	_limb(Vector2(-2.0, 6.0), PI + 0.20 - sway, 5.5, PI - 0.25, 5.0, TROUSER, 3.4)
	var body := PackedVector2Array([
		Vector2(-3, 1), Vector2(8, 0), Vector2(8, 7), Vector2(-3, 8)])
	draw_colored_polygon(body, team_color)
	draw_polyline(body + PackedVector2Array([body[0]]), INK, 1.0)
	# Forearms propping the body up.
	_limb(Vector2(7.0, 2.0), 0.5 + sway, 4.0, 1.45, 4.0, team_color.darkened(0.12), 3.0)
	draw_circle(Vector2(9.5, -1.0), 4.2, SKIN)
	draw_rect(Rect2(5.0, -6.0, 9, 3), hat_color)
	draw_rect(Rect2(5.0, -4.2, 9, 1.4), hat_stripe)
	if carrying:
		_draw_held_chest(6.0)
		_draw_carry_badge(-13.0)

func _draw_held_chest(slump: float) -> void:
	var r := Rect2(-7, -2 + slump, 14, 7)
	if chart:
		# The Star Chart: a rolled gold-edged scroll, glinting.
		draw_rect(r, Color(0.93, 0.86, 0.62))
		draw_rect(Rect2(r.position.x - 1.5, r.position.y - 0.5, 3, 8), Color(0.95, 0.78, 0.25))
		draw_rect(Rect2(r.end.x - 1.5, r.position.y - 0.5, 3, 8), Color(0.95, 0.78, 0.25))
		draw_line(Vector2(r.position.x + 3, r.position.y + 3.5), Vector2(r.end.x - 3, r.position.y + 3.5), Color(0.35, 0.45, 0.75), 1.0)
		draw_rect(r, INK, false, 1.0)
		var glint := 0.5 + 0.5 * sin(anim * 5.0)
		draw_circle(Vector2(r.end.x, r.position.y - 2), 1.2 + glint, Color(1.0, 0.95, 0.6, 0.8))
		return
	draw_rect(r, Color(0.55, 0.35, 0.12))
	draw_rect(Rect2(r.position.x, r.position.y, 14, 2.5), Color(0.88, 0.70, 0.26))
	draw_rect(r, INK, false, 1.0)

## A gold chest floating over a carrier's head, on a dark disc so it reads
## against any crew's shirt: the chest in their arms alone was easy to miss.
func _draw_carry_badge(y: float) -> void:
	var c := Vector2(0, y + sin(anim * 3.0) * 1.2)
	draw_circle(c, 7.5, Color(0, 0, 0, 0.65))
	draw_arc(c, 7.5, 0, TAU, 20, Color(1.0, 0.85, 0.30), 1.4)
	var r := Rect2(c.x - 4.5, c.y - 2.5, 9, 6)
	draw_rect(r, Color(0.62, 0.40, 0.14))
	draw_rect(Rect2(r.position, Vector2(9, 2.2)), Color(1.0, 0.82, 0.30))
	draw_rect(Rect2(c.x - 0.8, c.y - 0.5, 1.6, 2.0), Color(1.0, 0.92, 0.50))

## The original's combat bar: a vertical bar immediately LEFT of the person.
## The FRAME's height is their combat strength when fully rested; the green
## fill is what they have right now.
func _draw_combat_bar() -> void:
	if stats == null:
		return
	var maxcs: float = stats.max_combat_strength()
	var h: float = clampf(6.0 + maxcs * 0.28, 6.0, 34.0)
	var x := -14.0
	var bottom := 8.0
	draw_rect(Rect2(x - 1, bottom - h - 1, 5, h + 2), Color(0, 0, 0, 0.7))
	var ratio: float = clampf(combat_strength() / maxf(maxcs, 0.001), 0.0, 1.0)
	if ratio > 0.0:
		draw_rect(Rect2(x, bottom - h * ratio, 3, h * ratio), Color(0.24, 0.85, 0.30))
