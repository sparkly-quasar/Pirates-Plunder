class_name Combat
extends RefCounted

## The sword-fight rules from DESIGN_REFERENCE.md §4, as pure functions so the
## numbers can be tested on their own. GameServer runs the duel itself.
##
## A fight starts when someone walks into an opponent. Both stop, and each side
## secretly picks CAUTIOUS or AGGRESSIVE (the attacker may instead back off).
## The choice costs energy and sets how likely the clash is to end in a tie;
## combat strength decides who wins when it doesn't. Fights capture, never kill.

enum Choice { CAUTIOUS, AGGRESSIVE, RETREAT }

## Seconds the defender has to answer before they defend cautiously anyway, so
## an idle opponent can't stall the attacker's turn for ever.
const DEFEND_TIMEOUT := 20.0
## Confidence gained by winning a fight.
const CONFIDENCE_FOR_WIN := 10.0

## How much harder each stance is to spot (§3): crawling is 8x stealthier than
## running, standing sits in between.
const STANCE_STEALTH := {
	Character.Stance.STANDING: 0.5,
	Character.Stance.RUNNING: 0.125,
	Character.Stance.CRAWLING: 1.0,
}
## Bounds on how far a viewer's sight reaches against a target. Never past
## 1.0: you can't spot someone standing on ground you can't see.
const MIN_SPOT_FACTOR := 0.25
const MAX_SPOT_FACTOR := 1.0

static func cost(choice: int) -> float:
	return CharacterStats.COST_AGGRESSIVE if choice == Choice.AGGRESSIVE else CharacterStats.COST_CAUTIOUS

## Chance the exchange ends in a tie (§4):
##   both cautious 90%, both aggressive 10%, mixed 60%;
##   -10% per ~100% energy advantage (50-99% more -> -10, 100-199% -> -20, ...);
##   + rough ground; clamped to 10%-90%.
## The reference only says an energy advantage "shifts" the odds. Until 0.7.0
## it raised them, which made an exhausted fighter all but uncatchable (a 90%
## tie whatever anyone chose). Lowering them fits the original's own advice:
## wear opponents down, then finish off the weakened ones.
static func tie_chance(attack: int, defend: int, attacker_energy: float,
		defender_energy: float, terrain: float) -> float:
	var p := 0.6
	if attack == defend:
		p = 0.9 if attack == Choice.CAUTIOUS else 0.1
	var hi := maxf(attacker_energy, defender_energy)
	var lo := maxf(minf(attacker_energy, defender_energy), 1.0)
	var more := hi / lo - 1.0
	if more >= 0.5:
		p -= 0.1 * (1.0 + floorf(more)) # the fresher fighter settles it
	p += terrain
	return clampf(p, 0.1, 0.9)

## Rough ground makes a clean win harder: +20% on beach and hilltops, +40% in
## swamp. The worse of the two fighters' squares counts.
static func terrain_bonus(grid: TerrainGrid, cells: Array) -> float:
	var best := 0.0
	for c in cells:
		match grid.tile_type(c):
			TerrainGrid.SWAMP:
				best = maxf(best, 0.4)
			TerrainGrid.SAND, TerrainGrid.HILL:
				best = maxf(best, 0.2)
	return best

## When it isn't a tie, the stronger fighter is proportionally likelier to win.
static func win_chance(attacker_strength: float, defender_strength: float) -> float:
	return attacker_strength / maxf(attacker_strength + defender_strength, 0.001)

## Plain-language odds for the fight panel.
static func odds_word(p: float) -> String:
	if p >= 0.7:
		return "good"
	if p >= 0.45:
		return "even"
	return "poor"

## How far a viewer's sight reaches against this target, as a multiple of their
## normal vision. Average stealth while standing = 1.0 (seen as far as you can
## see); a crawling Scout is only spotted at a quarter of that range.
static func spot_factor(target: Character) -> float:
	var stealth := target.stats.stealth / CharacterStats.AVERAGE * float(STANCE_STEALTH[target.stance])
	return clampf(0.5 / maxf(stealth, 0.01), MIN_SPOT_FACTOR, MAX_SPOT_FACTOR)
