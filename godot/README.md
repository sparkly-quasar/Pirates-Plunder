# Pirates Plunder — Godot project

A fresh remake of *Richard Carr's Treasure Island* (1996) with person-vs-person
multiplayer. Built in **Godot 4** (GDScript).

## Run it
1. Install Godot 4: <https://godotengine.org/download> (or `brew install --cask godot`).
2. Open Godot → **Import** → pick this folder's `project.godot`.
3. Press **Play** (F5).

## Servers on your tailnet, games players start (v0.8.0)
- **Play on a Server** (main menu) lists the servers this computer can reach.
  `ServerFinder` asks Tailscale for the online machines (`tailscale status
  --json`, which includes machines shared with you) and asks each one on the
  server's status port (game port + 1, 24681) what it's doing: free, a game
  being set up, or a game under way. Addresses can be typed in too.
- **Games players start**: on a free server, Start a Game chooses the crews
  (up to the server's `most-crews`), how many are for players, the island,
  crew size and difficulty. That player sails the NAVS and leads: once
  everyone in the lobby has chosen, **Set Sail** gives the open seats to the
  computer. The next player leads if they leave; an empty lobby frees the
  server. Others **Join** from the list. `lobby=always` keeps 0.7.0's
  always-open lobby. See [SERVER.md](SERVER.md).
- The menu's online choices are now **Play Direct** (Host / Join, friend to
  friend, as before) and **Play on a Server**.
- **Free-for-all or 2v2.** With four crews, whoever sets up the game (setup
  screen, or Start a Game on a server) picks free-for-all or two sides of two,
  and which crew partners the NAVS. Partners share sight, don't fight (they
  walk round each other), can hand each other chests and load them on either
  ship, and their chests add up for the win (`GameServer.sides`,
  `allies()`, `side_delivered()`). Computer crews play 2v2 too.
- **Chat** in online games, the host's lobby, the crew screen and coaching:
  to everyone, or in 2v2 to your side. T starts typing in a game. Lines go
  through the host or server, which passes them on (`Net.say()`).
- Players have a name (on the Play on a Server screen), shown in lobbies,
  chat, server lists and the server's log. Protocol 8.
- **Fixed:** computer crews could stall a game for good: a sailor who had
  loaded a chest stayed standing on the ship, or an idle one stood in a
  one-square pass, and since routes go round team-mates the next carrier
  never got home. They now step off the ship, and out of a carrier's way.

## A dedicated server, online saves, clearer fights (v0.7.0)
- **An always-on server** that anyone who can reach its address can join,
  no Tailscale needed. `tools/package.sh` now also builds it: a Linux
  dedicated-server export with this version's Mac and Windows downloads
  beside it, so any older copy that connects updates itself to the server's
  version without a click. Try it from source with
  `godot --headless --path . -- --server`. Full guide, every setting, and
  hosting notes: [SERVER.md](SERVER.md).
- **Online matches save.** The host's match saves itself after every game,
  and Save and Quit works partway through one. **Continue Online Match**
  hosts it again, and each friend is put back in their own crew (each copy
  keeps a random id, `GameConfig.player_id()`, sent in the hello). With
  `--saves=<folder>` a server keeps a campaign the same way.
- **Fights:** an energy advantage now *lowers* the tie chance
  (`Combat.tie_chance`). It used to raise it, so an exhausted defender tied
  90% of the time and could hold off a fresh Swordsman indefinitely. The
  fight panel shows the tie odds as well as the odds if it isn't a tie.
- **Seeing what's going on:** a carrier has a gold chest badge over their
  head (and a gold ring on the mini-map); an opponent who slips out of sight
  leaves a faded "last seen" marker for two rounds; and the readout shows
  what each person gets back per turn (`Energy 40 (+25 a turn)`).
- It's a host with **no crew of its own**: every crew, the NAVS included, is
  a player online or the computer (`GameConfig.Mode.SERVER`; `Net.first_seat()`
  is 0 there). One match at a time; when everyone has left, a fresh lobby
  opens on a new island (`scripts/dedicated_server.gd`).
- **Kept moving for strangers:** time limits for choosing a crew, loading,
  between games and (optionally) each turn; pauses that run out; a message
  rate limit; and copies with another version told why and sent away, or
  offered the right version from a downloads folder.
- **Told why:** a host or server that turns someone away (full, under way,
  wrong version, too slow) now says so first, over the updater's raw packets
  (`{"t": "bye"}`, which older copies ignore), and the Join screen shows it.
- Protocol 7. Hosting from the game itself works exactly as before.

## Up to four crews (v0.6.0)
- **Two to four crews:** NAVS (blue), PIRATES (red), CORSAIRS (gold) and
  BUCCANEERS (green, with a pale hat). The setup screen picks how many and, when
  sharing a computer or hosting, whether each crew past the NAVS is a person or
  the computer. Single player takes one to three computer crews.
- **Bigger islands, more chests:** three crews get an island 1.25x wider and
  taller, four crews 1.45x (about 2.1x the land). Chests: 5 / 8 / 11 for three
  crews and 7 / 11 / 15 for four (Short / Medium / Long). Ships land on bearings
  round the coast (four: one per side), and of six candidate layouts of X's the
  one that treats every ship most evenly is kept (`TerrainGrid._fairness`).
  Two-crew islands are generated exactly as before.
- **Winning:** with two crews, more than half the chests, as ever. With more,
  you win once nobody can catch you — more chests aboard than any rival could
  reach even if every chest still out went their way (the same rule, stated
  generally; `GameServer._check_victory`). A crew that's all captured is out of
  the turn order; last crew standing wins; level leaders with every chest
  aboard is a draw. The HUD says how many you need, and a scoreboard (top right)
  shows every crew's chests, who's still ashore, and whose move it is.
- **Turn order** NAVS, Pirates, Corsairs, Buccaneers. In a match the crew that
  moves first rotates from game to game.
- **Online:** up to three guests; the host assigns each a crew, waits for every
  friend's seat, and can start early with the computer in the empty seats. Each
  guest gets snapshots of their own crew's view (fog only when it changed). A
  friend who drops out mid-game is replaced by the computer. Protocol 6.
- **Computer crews** watch the leading rival's ship and take riskier fights
  against the leader. In a match they coach their crew straight away.

## Milestone 2: two players, sword fights, computer pirates
- **Menu:** Single Player (against computer pirates), Two Players One Computer,
  Host a Game, Join a Game, Practice Alone (no pirates).
- **Computer pirates** (`scripts/computer_player.gd`): play through the same
  intents a person sends and see only what the pirates see. Carriers head home,
  opponents worth fighting get attacked (chest-carriers at worse odds), likely
  squares by the X's get dug, and the best swordfighter keeps watch near the
  NAVS' ship. Travellers keep energy in reserve; their turn runs faster while
  you can't see them.
- **NAVS (blue) vs PIRATES (red)**, taking turns. Each side has its own fog,
  ship and score; first to load more than half the chests wins — or capture
  every opponent.
- **Click one of yours, then a destination.** Routes take the cheapest way in
  energy, and the straightest of those. 1/2/3 stand/run/crawl, Space (or
  double-click a person) digs, Enter ends your turn, Tab cycles your people,
  wheel zooms, M menu. The mini-map (bottom right) shows the island; click or
  drag on it to look somewhere else.
- **Hand over a chest:** with a carrier selected, click a team-mate beside them;
  they ask "You want me to carry the treasure?" — Y/N or the buttons.
- **Crews** of 10 by default (two of each class), up to 16.
- **Single player difficulty** (Easy / Normal / Hard) and a **saved crew**: win
  against the computer and a **recruit** joins (you pick the class and, if you
  like, the name), then everyone is **coached one at a time**: one try each,
  at a skill (+2/+5/+10 by the skill's starting rating, up to 40/70/100; team
  spirit +20 to 100) or an attitude (Coachable, Self-Motivated). A try takes
  25%, plus 25% for each attitude. "Coach the rest for me" picks for anyone
  left. They keep it all for the next game (`user://crew.cfg`), and a crew
  grown past ten lands whole.
- **Two-player matches** (one computer or online): crews carry from game to
  game, and after each one every crew coaches every person once, win or lose
  (a tab per crew on a shared computer). They start fresh with every new
  match. Online, a guest sends its whole plan and the host rolls it.
- **Game length:** Short / Medium / Long = 40x30 / 52x38 / 66x48 islands with
  3 / 5 / 7 chests.
- **In-game menu** (Esc or the Menu button): pause, volume, save and quit
  (games on one computer; Continue on the main menu), leave.
- **Sword fights:** walk into an opponent (or click them) and both stop. Each side
  secretly picks a cautious (20 energy) or aggressive (25) attack/defence; the
  attacker may back off instead. Rules from `../DESIGN_REFERENCE.md` §4: tie odds
  by choice, energy gap and terrain; otherwise combat strength decides who
  captures whom. A carrier can't attack, defends at half, and loses the chest:
  the winner takes it, or if their hands are full it drops to the ground for the
  next person with empty hands to walk onto and pick up (no digging).
  The defender has 20 seconds to answer before defending cautiously.
- **Opponents are only shown while one of your people can see them** — vision
  against stealth, so a crawling Scout gets close unseen.
- **Networked play:** the host plays the NAVS and runs the rules; the guest's
  clicks go to the host as intents and the host streams back snapshots (ENet,
  UDP port 24680). Same Wi-Fi works as is; over the internet both players run
  **Tailscale** and the guest types the host's `100.x` address.

## Playing online
The game doesn't search for hosts. The guest types the host's address, which
the Host screen shows. On the same Wi-Fi that's all it takes. Over the
internet, both players use **Tailscale**, and having it running isn't enough:
Tailscale only connects devices that can see each other, and two friends'
accounts can't until the host shares their computer.

1. Both install Tailscale (https://tailscale.com/download) and sign in, each
   with their own account.
2. The host opens the Tailscale admin console → **Machines** → the **⋯** beside
   their computer → **Share**, and sends the invite link. Sharing is free on all
   plans, and the friend can reach only that one computer.
3. The friend opens the link and accepts. The host's computer appears in their
   Tailscale menu.
4. The friend types the host's `100.x.y.z` address into **Join a Game**
   (Multiplayer → Play Direct).

A shared computer can't start connections to the friend, only receive them.
That's fine here: the guest always connects to the host, on UDP port 24680. If
the host has edited their Tailscale access rules (ACLs), those rules must let
the friend in; the default rules do. The Host and Join screens walk through
these steps, with buttons that open Tailscale's download page, admin console and
sharing guide.

### A friend on a different version
From 0.6.1 on, everyone's copy compares versions when they connect
(`scripts/updater.gd`). If they differ, the older copy is offered the newer
one: **Get Version X From Your Friend**. It downloads straight from the friend
over the same connection, is checked byte for byte (SHA-256), replaces the old
copy, restarts, and a guest rejoins the same address on its own. If the old app
can't be replaced (say it was run straight off the disk image), the new one is
left in Downloads instead.

Mac and Windows both work in either direction, because every download carries
both: the Mac app has the Windows exe inside, and the Windows exe has the Mac
app (zipped) inside. A Mac serves other Macs by zipping its own app; a Windows
copy serves Windows by sending its own exe. These messages travel as raw
packets, not RPCs, and must never change shape, since they have to work
between any two versions. Copies from before 0.6.1 don't take part: they get
the old handshake, and have to be updated by hand once.

## Building the downloads
```
./tools/package.sh      # build/PiratesPlunder-macos.dmg, build/PiratesPlunder-windows.exe,
                        # build/PiratesPlunder-server-linux.tar.gz and build/SHA256SUMS.txt
                        # (the version comes from config/version in project.godot)
python3 tools/make_icon.py   # redraws icon.png and icon.ico, if the icon changes
```
A Mac app is a folder, so GitHub can only offer it packed: the .dmg is the
usual Mac way (open it, drag the app to Applications). The Windows exe already
has the game data inside it, so it's uploaded as is. Each carries the other
computer's version for friends to update from (see above), so the script
exports three times: a plain Windows exe into `dist/windows/`, the Mac app
with that inside (also zipped into `dist/mac/`), then the Windows exe with the
zipped Mac app inside. `dist/` is build output and isn't committed.

A fourth export builds **the server** (the "Linux Server" preset): one Linux
file, packed with this version's Mac and Windows downloads so it can update
older copies, plus its Docker, Compose and systemd files (from `../server/`).
See [SERVER.md](SERVER.md). The script checks up front that Godot's Linux
export template is installed, checks every file each export should make, and
stops with the reason if anything is missing, so a release can't go out
without its server. Attach all four files in `build/` to the release.

## Tests
```
godot --headless --path . res://tools/SmokeTest.tscn          # rules, fights, turns, mirror, computer, 3-4 crews
godot --headless --path . res://tools/NetTest.tscn -- --role=host &
godot --headless --path . res://tools/NetTest.tscn -- --role=guest   # two real processes
for r in crews-host crews-pirates crews-corsairs; do godot --headless --path . res://tools/NetTest.tscn -- --role=$r & done   # four crews, three processes
godot --headless --path . res://tools/NetTest.tscn -- --role=update-host &
godot --headless --path . res://tools/NetTest.tscn -- --role=update-guest --pretend-version=0.0.1   # versions: download and check
godot --headless --path . res://tools/NetTest.tscn -- --role=legacy-guest   # then a pre-0.6.1 copy, same host
tools/server_test.sh   # the real dedicated server (--server, lobby=always) and four players: seats, turn clock, take-over, refusals
tools/lobby_test.sh    # a server where players start games, and three players: server list, start, join, lead, hand-over, refusals
godot --headless --path . res://tools/NetTest.tscn -- --role=lobby-scan   # what this computer finds through Tailscale (by hand)
tools/web_test.sh      # a browser (WebSockets) and a desktop copy (ENet) on one server: status, start, join, chat, turns
tools/caddy_test.sh    # the same, with the browser going through Caddy set up as server/Caddyfile (needs caddy)
tools/release_update_test.sh   # Check for Updates from the public releases, against a stand-in for GitHub: download, fingerprint, the API's limit
tools/server_update_test.sh    # the server's auto-update through run.sh, against a stand-in for GitHub: fetch, switch, restart, a bad version, no run.sh
tools/rejoin_test.sh   # dropped connections: back into your crew (mid-game, a hanging connection, from the server list), the server waiting, then giving up
tools/resume_test.sh   # a saved online match, three crews: saved after a game, continued; saved partway through, continued
```

## Layout
```
scripts/
  main.gd            bootstrap: builds world + every crew, HUD, fight panel, scoreboard
  game_server.gd     THE AUTHORITY — all rules (moves, digging, fights, turns, win)
  combat.gd          the duel maths as pure functions (tie odds, spotting)
  computer_player.gd a computer crew: orders and fight choices via intents
  net.gd             autoload; ENet host/join (WebSockets from a browser), lobby handshake, game traffic
  dual_peer.gd       a server's connection: desktop copies over ENet and browsers over WebSockets at once
  dedicated_server.gd  --server: the always-on server's lobby, clocks and log (SERVER.md)
  web_status.gd      on a server: answers browsers' server lists over WebSockets
  server_idle.gd     what a server shows between matches (its log, when it has a window)
  server_finder.gd   finds servers: Tailscale's machines, the status question and answer (in a browser: the page's own server)
  server_browser.gd  Play on a Server: the list, starting a game, joining one
  server_lobby_box.gd  on a server: who's in which seat, and the leader's Set Sail
  chat_box.gd        chat in online games, lobbies and coaching (to everyone, or your 2v2 side)
  updater.gd         version hello, updating a friend's copy, and "bye" (why you were sent away)
  player_controller.gd  mouse/keyboard -> intents (never touches state directly)
  character.gd       a team member: sits on a cell, glides, draws itself
  terrain_grid.gd    the island map data + queries (walkable? vision? )
  world_view.gd      draws the terrain
  overlay_view.gd    holes, capture markers, the clash, selection + orders
  fog_view.gd        draws the viewing team's fog + X / ship markers
  menu.gd / setup.gd / lobby.gd   the screens before the island
  results.gd         after a game: who won, each sailor's record, star of the game
  coaching.gd        between games: a recruit, then coaching; also the Your Crew page
  coach_panel.gd     one crew's coaching, a person at a time; skill_bar.gd draws a skill
  minimap.gd         the whole island in the corner; click to look there
  game_menu.gd       Esc menu: pause, volume, save and quit, leave
  game_config.gd     autoload; mode, island seed, crews and who sails them, rosters, matches
  audio_manager.gd   autoload; the only thing that plays sound
  audio_manifest.gd  event -> file map (swap assets here)
assets/audio/sfx/    extracted WAV placeholders
```

## Why so much is built in code (not .tscn scenes)
M1 favours hand-authorable, reviewable text over binary-ish scene files. M2's
networking didn't need packed scenes after all: both machines build identical
rosters from the same config, so a person's index is their id everywhere, and
the host sends plain snapshots rather than using `MultiplayerSpawner`.

Each release's notes are in `release-notes/`.
