class_name CharacterStats
extends RefCounted

## A person's attributes, modelled on the original (see DESIGN_REFERENCE.md §1).
##
## Ratings are Poor / Average / Excellent, and the scale is MULTIPLICATIVE:
## Poor is 25% of Excellent and 50% of Average. The numbers below are the
## original's starting values from the coaching table, so coaching can later
## raise them toward their caps (Poor→40, Average→70, Excellent→100).

enum Kind { FIGHTER, RUNNER, SCOUT, SWORDSMAN, DIGGER }

const POOR := 15.0
const AVERAGE := 30.0
const EXCELLENT := 60.0

const MAX_ENERGY := 100.0  ## an average sailor's full tank (see max_energy())
## Energy tank per point of stamina above average: Vega (80) holds 130.
const TANK_PER_STAMINA := 0.6
const DIG_COST := 35.0        ## energy to dig...
const DIG_COST_DIGGER := 12.0 ## ...unless you're the Digger
const ATTACK_MIN_ENERGY := 25.0
const COST_CAUTIOUS := 20.0
const COST_AGGRESSIVE := 25.0
const MIN_DIG_COST := 8.0

## Coaching between games, as the original's footage shows it: each person
## gets ONE try per coaching round, at a skill or at an attitude. The odds are
## a quarter, plus a quarter for being Coachable and a quarter for being
## Self-Motivated (so 75% with both). How far a skill can go, and how fast,
## depends on where the class started it: Poor 15 -> 40 by 2, Average 30 -> 70
## by 5, Excellent 60 -> 100 by 10. Team spirit goes up 20 at a time, to 100.
const SKILLS := ["speed", "stamina", "stealth", "swordfighting", "vision", "digging"]
const SKILL_NAMES := {
	"speed": "Speed", "stamina": "Stamina", "stealth": "Stealth",
	"swordfighting": "Sword", "vision": "Vision", "digging": "Digging",
	"team_spirit": "Spirit",
}
## Everything a coaching try can aim at: the skills, spirit, then the attitudes.
const COACH_PICKS := ["speed", "stamina", "stealth", "swordfighting", "vision", "digging", "team_spirit",
	"coachable", "self_motivated"]
const ATTITUDES := ["coachable", "self_motivated"]
const ATTITUDE_NAMES := {"coachable": "Coachable", "self_motivated": "Self-Motivated"}
const COACH_BASE := 0.25
const COACH_PER_ATTITUDE := 0.25
const MAX_SKILL := 100.0
const TEAM_SPIRIT_STEP := 20.0

var kind := Kind.FIGHTER
var class_name_ := "Fighter"
var person_name := ""
## "" for everyone but a one-off sailor with their own rules: "vega", the
## navigator freed in the campaign (see Campaign). Kept with their saved stats.
var special := ""
## A sailor's lifetime record in your saved crew: games played, games won,
## chests found, chests got aboard and captures, over every single-player
## game (the campaign too) and Battle Royale they've sailed in. Bragging
## rights only. Kept with their saved stats.
var career := {}
const CAREER_KEYS := ["games", "wins", "found", "aboard", "captures"]

# --- the six class attributes ---
var speed := AVERAGE      ## how fast they cross a square (visual pace)
var stamina := AVERAGE    ## energy restored at the start of each turn
var stealth := AVERAGE    ## how hard they are to spot
var swordfighting := AVERAGE
var vision := AVERAGE     ## how far they see (spent as points, see TerrainGrid)
var digging := AVERAGE

# --- attributes not tied to class ---
var team_spirit := 20.0   ## 20..100; floors the energy term in combat
var confidence := 0.0     ## raised by digging chests and winning fights

# --- attitudes: they decide how well coaching takes ---
var coachable := true
var self_motivated := false

## Energy to dig: 35 for most, 12 for the Digger (§1). Coaching digging brings
## it down — 35 at Average or below, 12 at Excellent, on to 8 at the cap.
func dig_cost() -> float:
	if digging <= AVERAGE:
		return DIG_COST
	if digging <= EXCELLENT:
		return lerpf(DIG_COST, DIG_COST_DIGGER, (digging - AVERAGE) / (EXCELLENT - AVERAGE))
	return lerpf(DIG_COST_DIGGER, MIN_DIG_COST, (digging - EXCELLENT) / (MAX_SKILL - EXCELLENT))

## The original's formula, exactly (DESIGN_REFERENCE.md §4):
##   T = TeamSpirit/5;  ET = max(Energy, T);  C = Confidence/10
##   CS = (Sword + C + Sword*C/100) * ET/100
func combat_strength(energy: float) -> float:
	var t := team_spirit / 5.0
	# A bigger tank is for going further, not hitting harder: past 100, energy
	# doesn't add to a fight.
	var et: float = maxf(minf(energy, MAX_ENERGY), t)
	var c := confidence / 10.0
	return (swordfighting + c + swordfighting * c / 100.0) * et / 100.0

## The most energy this sailor can hold: 100, and more with stamina above
## average, so a sailor with great stamina goes further in a turn as well as
## resting quicker (Vega, stamina 80: 130; an Excellent 60: 118). Nobody
## holds less than 100.
func max_energy() -> float:
	return MAX_ENERGY + maxf(0.0, stamina - AVERAGE) * TANK_PER_STAMINA

## Combat strength when fully rested — sets the height of the bar's frame.
func max_combat_strength() -> float:
	return combat_strength(MAX_ENERGY)

## Seconds to cross one square. Faster (higher speed) = shorter. Excellent
## covers roughly four squares in the time Poor covers one.
func step_time() -> float:
	return clampf(0.55 * (AVERAGE / maxf(speed, 1.0)), 0.06, 0.9)

# --- coaching ---------------------------------------------------------------

## What this class starts with in `skill`.
func start_value(skill: String) -> float:
	if special == Campaign.SPECIAL_VEGA:
		return float(Campaign.make_vega().get(skill))
	return float(CharacterStats.make(kind).get(skill))

## Which recording of the spoken lines this sailor uses
## (AudioManifest.voiced): Vega has her own, higher voice; everyone else
## speaks in the original.
func voice() -> String:
	return "high" if special == Campaign.SPECIAL_VEGA else ""

## A pirate this sailor beats in a sword fight may come over to the NAVS
## rather than be captured (GameServer._defect_chance): Vega can talk them
## round.
func charismatic() -> bool:
	return special == Campaign.SPECIAL_VEGA

func coach_cap(skill: String) -> float:
	if skill == "team_spirit" or special != "":
		return MAX_SKILL
	var start := start_value(skill)
	return 40.0 if start <= POOR else (70.0 if start <= AVERAGE else MAX_SKILL)

func coach_step(skill: String) -> float:
	if skill == "team_spirit":
		return TEAM_SPIRIT_STEP
	var start := start_value(skill)
	return 2.0 if start <= POOR else (5.0 if start <= AVERAGE else 10.0)

## The chance that one coaching try takes: 25%, 50% or 75%.
func coach_chance() -> float:
	return COACH_BASE + (COACH_PER_ATTITUDE if coachable else 0.0) + (COACH_PER_ATTITUDE if self_motivated else 0.0)

## Whether a try at `pick` (a skill, spirit or an attitude) could do anything.
func can_coach(pick: String) -> bool:
	if pick in ATTITUDES:
		return not bool(get(pick))
	if not pick in COACH_PICKS:
		return false
	return float(get(pick)) < coach_cap(pick)

## One coaching try. Returns how much it raised the skill (1 for an attitude
## gained): 0 when it was already as far as it goes or the try didn't take.
func coach(pick: String, rng: RandomNumberGenerator) -> float:
	if not can_coach(pick) or rng.randf() >= coach_chance():
		return 0.0
	if pick in ATTITUDES:
		set(pick, true)
		return 1.0
	var before := float(get(pick))
	set(pick, minf(before + coach_step(pick), coach_cap(pick)))
	return float(get(pick)) - before

## What "coach everyone for me" picks: the attitudes first (they make every
## later try likelier), then the class's best skill while it can still grow,
## then spirit, then whatever is furthest from its limit. "" if nothing can.
func auto_pick() -> String:
	for a in ATTITUDES:
		if can_coach(a):
			return a
	var best := ""
	for skill in SKILLS:
		if can_coach(skill) and (best == "" or start_value(skill) > start_value(best)):
			best = skill
	if best != "" and start_value(best) > AVERAGE:
		return best
	if can_coach("team_spirit"):
		return "team_spirit"
	var room := 0.0
	for skill in SKILLS:
		if can_coach(skill) and coach_cap(skill) - float(get(skill)) > room:
			room = coach_cap(skill) - float(get(skill))
			best = skill
	return best

## "Speed +5" or "Self-Motivated": what a try at `pick` is for.
func pick_text(pick: String) -> String:
	if pick in ATTITUDES:
		return ATTITUDE_NAMES[pick]
	return "%s +%d" % [SKILL_NAMES.get(pick, pick), roundi(coach_step(pick))]

## A line for the coaching results: how a try at `pick` went.
func result_text(pick: String, gain: float, before: float) -> String:
	var who := "%s (%s)" % [person_name, class_name_]
	if pick in ATTITUDES:
		return ("%s became %s." % [who, ATTITUDE_NAMES[pick]]) if gain > 0.0 \
			else "%s didn't become %s this time." % [who, ATTITUDE_NAMES[pick]]
	var skill := str(SKILL_NAMES.get(pick, pick)).to_lower()
	return ("%s: %s up %d -> %d." % [who, skill, roundi(before), roundi(before + gain)]) if gain > 0.0 \
		else "%s: %s didn't improve this time." % [who, skill]

## Who starts Coachable and Self-Motivated is part of who they are, worked out
## from their name so every computer in a game agrees: most are Coachable,
## about half Self-Motivated. Saved from then on, so a rename doesn't change it.
func roll_attitudes() -> void:
	var h := absi(("%s/%d" % [person_name, kind]).hash())
	coachable = h % 5 != 0
	self_motivated = (h / 5) % 2 == 0

## A person as saved between games.
func to_dict() -> Dictionary:
	var d := {"kind": kind, "name": person_name, "team_spirit": team_spirit, "confidence": confidence,
		"coachable": coachable, "self_motivated": self_motivated}
	for skill in SKILLS:
		d[skill] = get(skill)
	if special != "":
		d["special"] = special
		d["class"] = class_name_
	if not career.is_empty():
		d["career"] = career.duplicate()
	return d

## One finished game added to the career: `tally` is GameServer.tally for
## them (found, aboard, captures), `won` whether their crew won.
func add_career(tally: Dictionary, won: bool) -> void:
	career["games"] = int(career.get("games", 0)) + 1
	career["wins"] = int(career.get("wins", 0)) + (1 if won else 0)
	for k in ["found", "aboard", "captures"]:
		career[k] = int(career.get(k, 0)) + maxi(0, int(tally.get(k, 0)))

## "12 games · 5 won · 9 chests aboard · 3 captures", or "" before any.
func career_text() -> String:
	var games := int(career.get("games", 0))
	if games <= 0:
		return ""
	return "%d game%s · %d won · %d chest%s aboard · %d capture%s" % [games, "" if games == 1 else "s",
		int(career.get("wins", 0)), int(career.get("aboard", 0)), "" if int(career.get("aboard", 0)) == 1 else "s",
		int(career.get("captures", 0)), "" if int(career.get("captures", 0)) == 1 else "s"]

func apply_saved(d: Dictionary) -> void:
	for key in SKILLS + ["team_spirit", "confidence"]:
		if d.has(key):
			set(key, float(d[key]))
	# Saved before attitudes existed: they keep the ones their name gave them.
	for key in ATTITUDES:
		if d.has(key):
			set(key, bool(d[key]))
	if str(d.get("special", "")) != "":
		special = str(d.special).left(16)
		class_name_ = str(d.get("class", class_name_)).left(16)
	var c: Variant = d.get("career")
	if c is Dictionary:
		career = {}
		for k in CAREER_KEYS:
			var v: Variant = c.get(k, 0)
			career[k] = maxi(0, int(v)) if (v is int or v is float) else 0

static func make(kind_: Kind, person: String = "") -> CharacterStats:
	var s := CharacterStats.new()
	s.kind = kind_
	s.person_name = person
	s.roll_attitudes()
	match kind_:
		Kind.FIGHTER:
			s.class_name_ = "Fighter" # average at everything
		Kind.RUNNER:
			s.class_name_ = "Runner"
			s.speed = EXCELLENT
			s.stamina = EXCELLENT
			s.swordfighting = POOR
			s.vision = POOR
		Kind.SCOUT:
			s.class_name_ = "Scout"
			s.stealth = EXCELLENT
			s.vision = EXCELLENT
			s.swordfighting = POOR
		Kind.SWORDSMAN:
			s.class_name_ = "Swordsman"
			s.swordfighting = EXCELLENT
			s.speed = POOR
			s.stamina = POOR
		Kind.DIGGER:
			s.class_name_ = "Digger"
			s.digging = EXCELLENT
			s.speed = POOR
			s.stealth = POOR
			s.swordfighting = POOR
			s.vision = POOR
	return s
