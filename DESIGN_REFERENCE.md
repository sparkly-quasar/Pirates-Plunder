# Design Reference — how the original games work

Everything we've been able to learn about the mechanics of Richard Carr's games,
gathered so we can rebuild them faithfully. **Mechanics and numbers are facts, not
copyrightable expression** — but the original's *art, audio and text* are, so this
file records rules, never assets.

**Sources**
- `carrsoft.com/TI/*` — Treasure Island overview + annotated screenshots.
- `carrsoft.com/pb/help/*` — **Pirate Battles**' full help section (42 pages).
  Far more detailed than the TI pages, and the same engine family.
- The user's own recollection of playing.
- **Gameplay footage of Treasure Island** (a 27-minute YouTube recording, the
  user's copy, watched as stills on 2026-11-02): team picking, coaching,
  two expeditions and their results. See §11.

> ⚠️ **Two games, two turn models.** *Treasure Island* is billed as
> "Simultaneous Strategy" — real time, pausable, each side moving one person at a
> time. *Pirate Battles* is explicitly **turn-based**: you move everyone, then
> press "Start New Turn", and energy is restored per turn by each person's
> stamina. Most of the detail below comes from Pirate Battles. **Which model
> Pirates Plunder uses is an open decision** — see "Open questions".

---

## 1. The five classes

Attribute grid (Poor / Average / Excellent). Note the fifth class is called
**Digger** in Pirate Battles and **Trapper** in Treasure Island — same role.

| | Fighter | Runner | Scout | Swordsman | Digger |
|---|---|---|---|---|---|
| Speed | Average | **Excellent** | Average | Poor | Poor |
| Stamina | Average | **Excellent** | Average | Poor | Average |
| Stealth | Average | Average | **Excellent** | Average | Poor |
| Swordfighting | Average | Poor | Poor | **Excellent** | Poor |
| Vision | Average | Poor | **Excellent** | Average | Poor |
| Digging | Average | Average | Average | Average | **Excellent** |

**The rating scale is multiplicative, not linear:**
- Poor = 25% of Excellent = 50% of Average
- Average = 50% of Excellent = 2× Poor
- Excellent = 2× Average = 4× Poor

What each attribute means:
- **Speed** — Excellent covers 4 squares in the time Poor covers 1 (at equal energy).
- **Stamina** — recovery rate. Excellent regains 4× the energy per minute of Poor.
- **Swordfighting** — base combat strength. Excellent is 4× Poor.
- **Vision** — how far you see *terrain* and *opponents*. Heavily modified by stance.
- **Stealth** — how hard you are to see. Heavily modified by stance.
- **Digging** — energy per dig: **Digger 12**, everyone else **35**.

**Not tied to class:**
- **Team Spirit** — 20 to 100. Starts at 20; coachable 4× at +20 each. Acts as an
  energy *floor* for combat: energy can't count as lower than TeamSpirit/5, so a
  high value makes an exhausted player far harder to capture.
- **Confidence** — raised by digging up a chest (+10 or +20) and by winning fights.

---

## 2. Energy — the spine of the game

### Movement cost per square
| Terrain | Running | Crawling |
|---|---|---|
| Easy | 2 | 6 |
| Moderate | 4 | 12 |
| Difficult | 6 | 18 |

Crawling costs 3× running. (Pirate Battles moves in *Running* or *Crawling*
stances — there is no separate "walk".)

### Action costs
| Action | Cost |
|---|---|
| Dig | 35 (Digger: 12) |
| Cautious attack or defend | 20 |
| Aggressive attack or defend | 25 |
| Enter digging stance | 36 (Digger: 12), begins digging at once |
| Change stance (otherwise) | free |

You need **at least 25 energy to attack**. Max energy is 100. In turn-based play
each person regains energy equal to their **stamina** at the start of each turn;
excess above 100 is wasted (the UI can flag this with a yellow diamond).

### Energy is visible on the sprite — exact tiers
| Energy | Appearance |
|---|---|
| > 75 | Standing, **arms moving** (animated) |
| 50–75 | Standing, arms still |
| 25–50 | Standing but **looking down** — visibly tired |
| < 25 | **Sitting down** |

---

## 3. Stances

| Stance | Vision | Stealth |
|---|---|---|
| Standing | 100% (best) | 50% |
| Running | 25% | 12% (worst) |
| Crawling | 25% | 100% (best) |

Standing sees 4× further than running or crawling. Crawling is 8× stealthier than
running. Chosen by double-clicking a person to open a Stance dialog (stand / run /
crawl / dig).

**Treasure Island does have Walk** (footage, 21:40): its Stance dialog offers
Dig, Stand, Crawl, Run and **Walk**, plus an **Alert Range** setting. So the
"no walk" above is Pirate Battles only, and our walk/run is closer to Treasure
Island than we thought.

---

## 4. Combat

Fights **capture**, never kill. Three outcomes: you capture them, they capture you,
or a **tie** (both come out weaker). The winner gains **confidence**.

### Combat Strength — the exact formula
```
T  = TeamSpirit / 5
ET = max(Energy, T)                  # energy floored by team spirit
C  = Confidence / 10
CombatStrength = ( SwordFight + C + (SwordFight * C / 100) ) * ET / 100
```
So combat strength is swordfighting, lifted by confidence, scaled by energy — with
team spirit setting a floor under the energy term. For combat, energy is never
treated as below 1.

### Tie probability
- Both cautious, similar energy, clear terrain → **90%** tie
- Both aggressive, similar energy, clear terrain → **10%** tie
- One cautious vs one aggressive → **60%** tie
- An energy advantage shifts it: 10% per ~100% more energy (50–99% more → 10%,
  100–199% → 20%, 200–299% → 30%, …). The pages don't say which way. **Built
  (0.7.0) as lowering the tie chance**: the fresher fighter is likelier to
  settle it, which fits "wear opponents down" and "finish off weakened
  opponents" below. (Before 0.7.0 it raised it, so an exhausted defender
  tied 90% of the time whatever anyone chose.)
- **Clamped to 10%–90%.**
- Rough terrain raises tie chance: **+20%** in bush/beach/wood edge/palm/level
  ridge, **+40%** in river/swamp/mud/forest.

### Tactics the help calls out
- Wear opponents down with **cautious** attacks; only go **aggressive** at ~70%+
  odds of winning.
- Finish off weakened opponents before fresh ones — otherwise the tired ones recover.
- Don't attack a group piecemeal; move a cluster up, then engage.
- Retreat into rough terrain to avoid capture.

### Capture markers
A capture leaves a **sword stuck in the ground with a hat on it** — red hat where a
pirate was taken, blue where a nav was.

---

## 5. Terrain

| Move cost | Terrain |
|---|---|
| Easy (1×) | Meadow / clear |
| Moderate (2×) | Bushes, palm trees, hilltops, beach, outer pines |
| Difficult (3×) | Swamp, mud, rivers, hill edges, inner pines |
| Impossible | Lake, ocean |

| Vision cost | Terrain |
|---|---|
| Clear | Meadow, beach, river, mud, lake, ocean |
| Medium (8×) | Bushes, palms, hilltops, outer pines |
| Difficult (16×) | Swamp, hill edges, inner pines |

- Opponents **1 square away are always visible**; opponents *running* 2 squares
  away are always visible.
- Standing on a **hill** adds **+33% visibility**.

---

## 6. Treasure chests

- Chests are buried in **clear/meadow terrain adjacent to a red X**, and there is
  **exactly one chest per red X** — in one of the 8 surrounding squares.
- **Carrying a chest**: speed **halved**, movement energy **doubled**. One chest per
  person. It can't be put down — only handed to a team-mate or loaded onto a ship.
- A carrier **cannot attack**, can be attacked, and **defends at half combat
  strength**. Losing means losing the chest.
- **Transfer** by moving the carrier onto a team-mate; **deliver** by moving onto
  your ship. Once aboard, a chest is permanently safe.
- Digging up a chest gives: **1 ruby (75%) or 2 (25%)**, **+10/+20 confidence**, and
  an immediate **+6 to one chosen skill**.
- Ships: the nav ship flies **3 blue flags**; the pirate ship has **2 red flags and
  a pirate flag**.

---

## 7. Rubies & mercenaries

Rubies can't be captured. Spend one at any time for a **mercenary who serves for the
current expedition only**, appearing near your ship. Unspent rubies carry to later
expeditions and score points at the end.

---

## 8. Expeditions, coaching, scoring

- A campaign of **20 expeditions**, each its own island; you **add one new person to
  the team before each**. Every island has 3 nav and 3 pirate start positions (9
  combinations).
- Expedition 1 is a **boot camp with no chests** — the objective is to capture all
  the pirates. Later islands hold 3, 5, 7, or 9 chests; some hide the X locations
  from the overhead map; one has 50% visibility.
- **Coaching between expeditions**: 90% success chance per attempt (Pirate Battles;
  Treasure Island works differently, one try per person, see §11).

| Rating | Start | Max | Gain per success |
|---|---|---|---|
| Poor | 15 | 40 | +3 |
| Average | 30 | 70 | +6 |
| Excellent | 60 | 100 | +10 |

- **Scoring** (0 if you lose): 3000 for the win; ±100 per capture; ±100 per ruby
  held; ±300 per chest dug up; ±600 per chest on a ship; ±300 per chest carried.
  Then ×2/×3 for a Silver/Gold cup, then ×2/×4/×8 for the opponent's difficulty.
  Digging chests up yourself is worth more than stealing them.
- **Difficulty tiers** (C / B / JV / Varsity) adjust nav count (+6, +3, 0, −2),
  pirate energy (50%, 66%, 100%, 100%), pirate speed, and who moves first.

---

## 9. Interface

- **Left-click** a person to select; **double-click** opens the stance dialog;
  **click-and-hold** on the map walks them there (they path to it even off-screen).
- **Right-click** opens the **global map** and pauses; right-drag scrolls.
- The game pauses on: opening the map, finding a chest, loading a chest, and after
  combat. Pirates wait while paused.
- **Global map**: whole island, black where unexplored, both ships, the red X's,
  blue squares = navs, red = pirates, and a rectangle cursor selecting the view.
- **Yellow squares** mark the **last pirate seen moving** (bold = most recent,
  thin = second most recent; empty if they were captured or slipped away).
- Audio cues: you hear opponents moving/digging **only if one of your people can see
  them**, with spoken warnings when it happens off-screen.
- Key commands: `C` centre on current nav, `D` player panel, `G` grid, `L` last
  pirate seen, `N` next nav, `P` pause, `S` team status, `T` team list, `V` inspect
  under cursor, `Space` map + pause.

---

## 10. Art direction (observed from the original's sprites)

- **NAVS: blue shirt + blue/white striped tricorne. PIRATES: red.** Both wear
  cream/white trousers and dark boots, with a drop shadow.
- Class read at a glance: Scout holds a **telescope** to the eye; Digger carries a
  **shovel/pick**; Swordsman has a **drawn sword**; Runner is plain and mid-stride;
  Fighter has an arm raised.
- A duel draws the two combatants **facing each other with blades crossed**.
- Terrain is **noisy/speckled**, not flat — a yellow-green stippled meadow with a
  visible grid, dark clumped bushes, grey rock.
- The **combat bar** sits immediately left of each person: the *frame* height is
  their max combat strength, the *green fill* is their current value.

---

## Open questions for the user

1. **Turn-based or simultaneous?** Pirate Battles is turn-based ("Start New Turn");
   Treasure Island is real-time-with-pause. Turn-based is markedly easier to make
   fair over a network and is the better fit for PvP; real-time is closer to the
   Treasure Island feel. **This shapes M2.**
2. ~~**Walk vs run vs crawl.**~~ Answered by the footage: Treasure Island has
   Walk (§3). Pirate Battles is the one without it.
3. **How much of the meta layer** (expeditions, coaching, rubies, scoring, difficulty
   tiers) do we want, versus a single sharp PvP match?

---

## 11. What the Treasure Island footage shows (2026-11-02)

Facts read off the screen; no art, audio or text taken. Times are into the video.

**Crews are big.** The team is picked by class from **14 available**
(0:20–1:00: e.g. 4 Fighters, 1 Runner, 1 Scout, 7 Swordsmen, 1 Trapper). Before
each expedition **one person is added**, by class, with the option to name them
(1:05, 6:20). The results screens say "Navs had 15 players" (game 1) and 16
(game 2). The pirates had **6** in the first expedition (a boot camp: capture
them all, no chests, 5 minutes) and **11** in expedition 3; the text says the
size of your team varies with which pirate team you face.

**Coaching is one person at a time** (1:20–2:10, 6:40–7:40). A dialog steps
through the crew (#1 to #15). Each person gets **one try**, at one of:
- a skill: Speed, Stamina, Stealth, Swordfighting, Vision,
- Team Spirit ("Commitment"), always +20,
- an attitude they lack: **Coachable** or **Self-Motivated**.

The odds shown are **75%** for people who are both Coachable and Self-Motivated
and **50%** for people who are Coachable but not Self-Motivated (every case on
screen). The results list also shows someone who "didn't achieve coachability",
so not everyone starts Coachable; what the odds are for them isn't shown. The
gain depends on the skill's level: **+2 at 15, +5 at 30 (and 35), +10 at 60**.
"Coach entire team for me" picks for you. All the results are listed together
at the end ("SWORDFIGHTING improved (5 + 30 = 35)", "SELF-MOTIVATION achieved",
"didn't improve at stamina").

**Coaching happens before the first expedition too**, straight after picking
the team.

**In-game "Bonus Development"** (13:00): after a successful action a person gets
to pick one skill to raise by 5 to 10 at once. (Not built.)

**Cups by time**: expedition 1, Gold within 1 minute, Silver 2, Bronze 5;
expedition 3 (3 of 5 chests): Gold 7, Silver 10, Bronze 20 minutes.

**Digging needs 35 energy to start** (23:20: "Need 35 Energy to start digging").

### What Pirates Plunder took from this (the user's choices, 2026-11-02)
- Crews of **10 by default, up to 16** (the original's 14 would make our turns
  long).
- Coaching **one try per person**, as above. Our odds where the footage is
  silent: 25%, plus 25% for each attitude (so 75% / 50% / 25%). Everyone's
  starting attitudes come from their name, so every computer agrees: about 4 in
  5 start Coachable and half Self-Motivated. Gains +2 / +5 / +10 go by the
  class's starting rating (Poor / Average / Excellent), with the caps from §8
  (40 / 70 / 100). Digging is coachable too (the original folds it into the
  Trapper).
- In a match **every crew coaches everyone after every game**, win or lose.
- Single player: **one recruit per win**, of the class you pick.
