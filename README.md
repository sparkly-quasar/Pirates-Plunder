<p align="center"><img src="godot/icon.png" width="160" alt="Pirates Plunder icon"></p>

# Pirates Plunder

A turn-based treasure hunt for one to four players. Your crew of NAVS lands on
an island hidden in fog, digs for the chests buried beside the red X's, and
races to get them aboard ship before the PIRATES (and, with more players, the
CORSAIRS and BUCCANEERS) do. Run into an opponent and
it's a sword fight. Win, and you coach your crew for the next expedition.

Inspired by the 1996 PC game *Richard Carr's Treasure Island*. Built with
[Godot 4](https://godotengine.org).

## Download and play

Get the latest build from the
[Releases page](https://github.com/sparkly-quasar/pirates-plunder/releases).

- **Mac:** download `PiratesPlunder-macos.dmg`, open it, and drag
  **Pirates Plunder** onto **Applications**. The app isn't signed by Apple yet,
  so the first time, right-click it and choose **Open**.
- **Windows:** download `PiratesPlunder-windows.exe` and run it. Windows may
  warn about an unrecognised app: choose **More info**, then **Run anyway**.

## Ways to play

The main menu asks how you want to play: **Single Player** (against the
computer, or practising alone), **Multiplayer** (on a server, friend to
friend, or sharing one computer) or **Settings** (your name, the volume and
the layout). Each opens its own page; **Back** or **Esc** returns.

- **Single Player:** race one to three computer crews. Choose Easy, Normal or
  Hard. Your crew keeps its coaching and names from game to game. Each win
  brings a new recruit of the class you choose, and coaching works one person
  at a time: everyone gets one try at a skill or an attitude.
- **Players Sharing One Computer:** two to four crews, passing the mouse between
  turns. A screen hides the board while you swap. Any crew can be given to the
  computer instead.
- **Play Direct** (on the Multiplayer page; it opens **Host a Game** and **Join a Game**): up to three friends join over the same Wi-Fi,
  or over the internet with [Tailscale](https://tailscale.com/download). Seats
  nobody fills can go to the computer, and if a friend drops out mid-game the
  computer takes over their crew. The Host and Join
  screens walk you through it. The short version: the host shares their
  computer with the friend in Tailscale, and the friend types the host's
  `100.x` address. Full steps are in
  [godot/README.md](godot/README.md#playing-online).
  If your friend has a different version, the older copy offers to download
  the newer one straight from the other player and update itself, Mac or
  Windows (from 0.6.1 on).
- **Play on a Server:** someone leaves a dedicated server running, at home or
  on a small rented machine. **Play on a Server** lists the servers on your
  Tailscale network (including ones friends have shared with you): start a
  game on a free one, choosing the crews and the island, and your friends
  join it from the same list. A server elsewhere can be typed in by address.
  An older copy updates itself from the server as it joins, or press
  **Check for Updates** on that screen to update before you start anything.
  Running one:
  [godot/SERVER.md](godot/SERVER.md).
- **Free-for-all or 2v2:** with four crews, play every crew for itself or two
  sides of two. Partners share what they see, can't fight each other, pass
  each other chests, and their chests count together.
- **Your names, online:** in an ordinary online game (Play Direct or a
  server) your sailors land with the names from **Your Crew**, class by
  class, but everyone still starts with fresh skills. If someone else in the
  game already has a name, or your crew is bigger than Your Crew, the rest
  get the usual names. (A Battle Royale brings Your Crew whole, skills too.)
- **Chat** in online games: to everyone, or in 2v2 just to your side (press
  T in the game).
- **Online matches save** after every game. **Continue Online Match** picks
  a campaign up again, and each friend gets their own crew back.
- **Lost your connection?** Your game reconnects by itself. Playing alone on
  a server, your game is saved the moment you drop, and you're put straight
  back into it (or **Continue** it later from the server list). With
  friends, the game pauses for two minutes; then they choose: give your crew
  to the computer (you can take it back), keep waiting, or save the game for
  later, when it shows up in everyone's list.
- **On a phone, or in any web browser:** a server hands out the game itself.
  On a phone, with the Tailscale app on, open the server's **https://**
  address (whoever runs it sets that up with `tailscale serve`, for example
  `https://<machine>.<tailnet>.ts.net:10000/`) and play alongside the Mac
  and Windows copies. Browsers only run the game over https, except on the
  server's own machine (`http://localhost:24682/`). On a phone it's
  laid out for the screen held sideways: tap to select and move, drag to
  look around, pinch to zoom, and big buttons for the rest. To keep it on
  your home screen, use **Share → Add to Home Screen** (iPhone, Safari) or
  the menu's **Add to Home screen** (Android, Chrome): it gets the game's
  icon and name. See
  [godot/SERVER.md](godot/SERVER.md#players-in-a-web-browser-and-on-phones).
- **Campaign: The Star Chart** (Single Player). Captain BlackPatch's pirates
  stole the Star Chart and captured Vega, the fleet's best navigator. Fifteen
  islands in order, each the same for everyone, with its own rules: storms,
  head starts, two and three rival crews, and rivals that get better drilled
  as you go. On island 7 you free Vega (walk someone up beside her, then get
  her aboard your ship); after that she sails with you, a Navigator with
  skills no recruit starts with. On island 12 the Star Chart is buried under
  a gold X; later islands start fully mapped. Win Treasure Island for the
  ending and the **Golden Rooster**: your ship flies it from then on, in
  single player and in every online game.
- **Hall of Fame:** each server keeps every player's lifetime record there
  (games, wins, Battle Royale titles, chests aboard, captures); press **Hall
  of Fame** beside a server in Play on a Server. Your crew's sailors keep
  careers of their own, on **Your Crew**.
- **Battle Royale** (Multiplayer): every crew for itself on a big island,
  each player bringing the crew they've trained in single player, whole and
  uncapped (no crew yet: ten fresh recruits). A short match of 1, 3 or 5
  rounds; the most rounds won takes it. Vega sails only in the final round,
  unless whoever sets it up lets her sail every round. Start one on a server
  (choose Battle Royale in its new-game settings) or host one yourself.
- **Tutorial** (Single Player, in place of Practice Alone): a guided island
  that walks a new player through selecting and moving, stances, ending the
  turn, digging, carrying and handing over a chest, the menu and a sword
  fight, in mouse-and-keys or touch words, moving on as each step is done.

Every game can be **Short**, **Medium** or **Long**: a bigger island with more
chests (3, 5 or 7 for two crews). More crews get a much bigger island and more
chests: 5, 8 or 11 for three crews, and 7, 11 or 15 for four, on an island
about twice the size, with a ship on each side and the X's laid out so no crew
starts closer to the treasure than the others. Press **Esc** in a game to pause, change the volume, or
**Save Game** into one of three slots (then keep playing or quit). **Continue**
on the main menu picks up the newest save; **Saved Games** lists all three, to
continue or delete. **Single Player → Your Crew** shows everyone you've been
training: their skills, how far coaching can take them, and their confidence.
Your crew is kept automatically after every game; it doesn't need a save slot.

On a Mac or Windows the game opens in a big window the first time, and after
that the way you left it: the same size and place, or full screen.

## How to play

- Click one of your crew, then click where they should go. Every square costs
  energy, and energy only comes back at the start of your turn.
- **1** stand (sees furthest), **2** run, **3** crawl (hardest to spot).
- The view stays where you put it: drag (or right-drag), the arrow keys, the
  wheel, or a click on the mini-map move it, and **C** jumps to whoever is
  selected.
- Multiplayer games can have a turn limit (chosen when the game is set up:
  none to 5 minutes; servers start at 3). A clock beside the Menu button
  shows whose turn it is and the time left; when it runs out the turn
  passes on.
- **Space**, or double-click a person, digs where they stand. Chests are always
  buried in open meadow, next to a red X.
- Carry a chest to your ship. To hand it to someone, select them and
  double-click the carrier: they walk over and ask for it. With the carrier
  selected, double-clicking the carrier hands it to a team-mate right beside
  them. A single click on anyone of yours, carrier or not, just selects them.
- Walk into an opponent, or click one, to fight. Each side secretly picks a
  cautious or aggressive move; the loser is captured.
- Capture a chest-carrier and you take their chest. If your hands are already
  full it drops on the ground: anyone with empty hands can walk onto it and
  pick it up.
- **Enter** ends your turn. Get more than half the chests aboard, or capture
  every opponent, to win. With three or four crews you win once nobody can
  catch you: when no rival could pass your total even if every chest still on
  the island went their way. A scoreboard shows who's leading. A crew that's
  all captured is out; the last crew standing wins.

## For developers

The game lives in [`godot/`](godot/): open it in Godot 4.7. Design notes are in
[`DESIGN_REFERENCE.md`](DESIGN_REFERENCE.md), and the code layout and test commands are in
[`godot/README.md`](godot/README.md). `godot/tools/package.sh` builds the Mac
disk image and the Windows exe.

## A note on the sounds

Pirates Plunder is a fan-made homage to Richard Carr's *Treasure Island*
(CarrSoft, 1996). The sound effects are clips taken from that
original game, and they belong to their creators. They're here as a tribute,
not as my own work, and nothing is charged for this game.

If the original developer, or whoever holds the rights, would like the clips
removed, I'm happy to do that straight away. Please open an issue on this
repository and I'll take them out. All of the game's audio goes through one
file ([`godot/scripts/audio_manifest.gd`](godot/scripts/audio_manifest.gd)),
so replacing them is quick. See
[`godot/PLACEHOLDER_ASSETS.md`](godot/PLACEHOLDER_ASSETS.md).

## License

The game's code, art and text are under the [MIT License](LICENSE): use,
change and share them freely, keeping the copyright notice. The sounds and
music from the original 1996 game aren't covered by it (see the note on the sounds
above, and the end of [`LICENSE`](LICENSE)).
