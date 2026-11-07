# Running a Pirates Plunder server

A **dedicated server** is a copy of the game with no crew of its own, left
running somewhere players can reach. It runs the same rules as a hosted game,
and every crew (the NAVS included) is a player online or the computer.
Nobody has to keep their own computer on to host.

**Finding it.** Players choose **Play on a Server**. The game asks Tailscale
which of their machines are online (including machines friends have shared
with them) and asks each one whether it runs a server. Every server it finds
is listed with what it's doing. A server that isn't on their tailnet can be
typed in on that screen (`host` or `host:port`), or joined under **Join a
Game** like a friend's computer.

The question goes to the status port (UDP 24681). A machine that doesn't
answer there within two seconds is also asked over TCP on the same port
number (where browsers ask, so `web-port` must be on). Docker Desktop on a
Mac once stopped forwarding a server's UDP 24681 while its other ports
kept working; a server found that way is listed with "answering over TCP
only", and can still be joined. Restarting its container brings UDP back.

It runs one match at a time:

1. **Free.** Nobody has started a game. The first player to pick the server
   and choose **Start a Game** sets it up: how many crews (up to
   `most-crews`), how many are for players (the computer sails the rest),
   the island and the crew size, and with four crews free-for-all or 2v2.
   They sail the NAVS and **lead** the game.
2. **Lobby.** Others pick the server and **Join**. They're seated in turn
   order (NAVS, Pirates, Corsairs, Buccaneers) and each chooses a crew. The
   game sets sail once every seat has a player who has chosen, or when the
   leader presses **Set Sail** (once everyone there has chosen), with the
   computer in the empty seats. If the leader leaves first, the next player
   leads. If everyone leaves, the server is free again.
3. **Match.** It plays game after game, with coaching between games, as any
   online match does. If a player leaves, the computer takes over their crew;
   if their connection drops, the game waits for them first (see below).
   Nobody new can join a match that has already started.
4. **When every player has gone**, the game is saved for them and the server
   is free again. Each player's server list offers their saved games to
   **Continue** (see Saved games, below).

With `lobby=always` it works as 0.7.0 did instead: a lobby with the server's
own settings is always open, and it sets sail once every seat is taken, or
`start-after` seconds after `min-players` are ready.

**Everyone ends up on the server's version.** A copy with an older version
that connects downloads the server's version from it, updates itself,
restarts and rejoins, with no clicks needed. (Copies from before 0.6.1
can't, and need one manual download.)

The server stops one stalled player from holding everyone up. It has time
limits for choosing a crew, for loading the island and between games, and an
optional limit per turn. Pauses also end after a set time. It also checks
every message and sends away a copy that floods it with messages.

Players need **version 0.8.0 or later** for the server list and for starting
games. A copy from 0.6.1 or 0.7.0 can still connect by address under **Join a
Game**, and it updates itself to the server's version straight away.

## Build the server (on your Mac)

`tools/package.sh` builds the server together with the downloads:

```
build/PiratesPlunder-macos.dmg
build/PiratesPlunder-windows.exe
build/PiratesPlunder-server-linux.tar.gz   = build/server/, packed:
    PiratesPlunder-server.x86_64     the server: one file, no graphics or sounds
    downloads/<version>/             this version's Mac and Windows downloads,
                                     which it hands to older copies
    Dockerfile, docker-compose.yml   to run it with Docker
    pirates-plunder.service          to run it with systemd instead
    SERVER.md, VERSION
```

The server is the same game, exported from the same project as a Godot
*dedicated server* (the **Linux Server** export preset). The rules can't
drift apart, and the server and the downloads it hands out are always the
same build. It needs Godot's export templates, which include Linux.

## Try it on your own computer

From the `godot/` folder, with Godot 4.7 installed:

```sh
godot --headless --path . -- --server
```

Without `--headless` it opens a window that shows the log. If you've run
`tools/package.sh`, it also finds `build/server/downloads` and can update
older copies. Then start the
game normally (or on a second computer), choose **Multiplayer**, **Play
Direct**, **Join a Game** and type
choose **Play on a Server**: it lists the server as **This computer**. To
check the whole thing, run `tools/lobby_test.sh` (a server and three test
players starting, joining and leading games, reporting `LOBBY_TEST: ALL
PASS` or what failed) and `tools/server_test.sh` (the same with
`lobby=always`, and four players).

## Settings

Give settings after the `--`, as `--name=value`. You can also set them as
environment variables named `PP_` plus the name in capitals, with
underscores for dashes (`--turn-seconds=180` is `PP_TURN_SECONDS=180`). That
suits Docker. A value on the command line wins over the environment.

| Setting | Default | What it does |
|---|---|---|
| `port` | 24680 | UDP port to listen on. |
| `bind` | (all) | Listen on one address only: an IP, or a host name to look up. |
| `name` | (none) | The server's name in players' server lists. Without one they see the machine's Tailscale name, or the address they typed. |
| `web-port` | 0 | TCP port where copies of the game running in a web browser connect, over WebSockets. 0 means the same number as `port` (24680, on TCP); -1 means no browsers. |
| `page-port` | 0 | TCP port that hands out the game for web browsers: open `http://<server's address>:<port>/` (phones need HTTPS in front: see HTTPS with Tailscale). 0 means the game's port + 2 (24682); -1 means don't. |
| `web-files` | (beside the server) | The folder with the web version of the game. Empty means the `web` folder that `tools/package.sh` puts beside the server. |
| `status-port` | 0 | UDP port that answers players' server lists, and the TCP port that answers browsers' (when `web-port` is on). 0 means the game's port + 1 (24681); -1 means don't answer (it can still be joined by address). |
| `lobby` | players | `players`: whoever picks the server starts a game and chooses its settings, and the rest join it. `always`: a lobby with the settings below is always open (how 0.7.0 worked). |
| `most-crews` | 4 | With `lobby=players`, the most crews a game may have, 2 to 4. |
| `crews` | 2 | Crews on the island, 2 to 4. With `lobby=players`, what a new game starts from. |
| `partner` | 0 | With 4 crews, 2v2: the crew that teams up with the NAVS (1 Pirates, 2 Corsairs, 3 Buccaneers). 0 means free-for-all. With `lobby=players`, what a new game starts from (the player starting it chooses). |
| `seats` | 0 | `lobby=always`: how many crews players can take, counted from the NAVS. The rest are the computer's. 0 means all of them. |
| `min-players` | 2 | `lobby=always`: players who must have chosen a crew before the `start-after` countdown begins. |
| `start-after` | 60 | `lobby=always`: seconds to wait for more players once `min-players` are ready. After that, empty seats go to the computer. 0 waits for every seat. |
| `length` | medium | `short`, `medium` or `long`: island size and number of chests. With `lobby=players`, what a new game starts from. |
| `crew-size` | 10 | People per crew, 1 to 16. Players choose exactly this many. With `lobby=players`, what a new game starts from. |
| `difficulty` | normal | `easy`, `normal` or `hard`, for the computer's crews. With `lobby=players`, what a new game starts from. |
| `turn-seconds` | 0 | Longest a player's turn can last. When time runs out, an unanswered fight is settled (the attacker backs off, the defender defends cautiously) and the turn passes on. Players are warned at 30 and 10 seconds. 0 means no limit. |
| `pause` | true | Whether players may pause. |
| `pause-seconds` | 120 | Longest a pause can last before the game carries on. 0 means no limit. |
| `choose-seconds` | 300 | How long a player has to choose a crew in the lobby. |
| `join-seconds` | 120 | How long a copy can stay connected without a seat (a wrong version, for example), unless it is downloading an update from the server. |
| `load-seconds` | 90 | How long everyone has to load the island. The computer replaces anyone slower. |
| `rejoin-seconds` | 120 | When a player loses their connection or leaves mid-game, the others are asked at once what to do (carry on with the computer sailing that crew, wait, end the game with nothing kept, or save it for later), and the game waits, paused, for this long. If nobody answers by then they're asked once more, and 30 seconds later the computer takes over by itself. 0 means the computer takes over their crew at once. |
| `ready-seconds` | 300 | Time between games. After that the next island starts even if someone is still coaching, and their unspent sessions carry over. 0 means wait for everyone. |
| `downloads` | (beside it) | A folder of release downloads, so older copies can update themselves from the server. By default, the `downloads` folder next to the server, which `package.sh` fills. See below. |
| `saves` | user://server-saves | The folder for saved games (see Saved games, below); `-` keeps none. Run from source, `user://` is Godot's data folder for the game (on Linux `~/.local/share/godot/app_userdata/Pirates Plunder/`). |
| `save-days` | 30 | Saved games older than this many days are deleted. 0 keeps them until each of their players has three newer ones. |
| `auto-update` | true | Keep the server on the newest version by itself: it looks in the game's public releases on GitHub every `update-hours` (and as soon as a newer copy tries to join), downloads a newer server package, checks it against the release's fingerprints, and once nobody is connected, restarts into it with the same settings. Needs the server started by `run.sh`, as the Docker image and `pirates-plunder.service` do. `false` stays on this version. See How updating works. |
| `update-hours` | 1 | How often auto-update looks for a newer version. |
| `updates` | (in saves) | Where auto-update keeps the versions it downloads (about 330 MB each; it keeps only the one it's running). By default `updates` inside the saves folder, so Docker's volume keeps it. |
| `tick` | 30 | Frames per second. The game is turn-based, so 30 is plenty and keeps CPU use low. |
| `once` | false | Quit when the first match ends instead of opening a new lobby. The tests use this. |

Some examples:

```sh
# Players start the games, three minutes a turn, listed as "Homeserver":
godot --headless --path . -- --server --turn-seconds=180 --name=Homeserver
# Always open: two players against two computer crews, starting as soon as both are ready:
godot --headless --path . -- --server --lobby=always --crews=4 --seats=2
# Always open: one player at a time against the computer, on a second port:
godot --headless --path . -- --server --port=24682 --lobby=always --seats=1 --min-players=1
```

## Put it on a server

Copy `build/PiratesPlunder-server-linux.tar.gz` to the machine
(`scp build/PiratesPlunder-server-linux.tar.gz you@your-vps:`), unpack it,
and run it one of these ways.

**With Docker** (the package's own `Dockerfile` and `docker-compose.yml`,
with settings at the top):

```sh
tar -xzf PiratesPlunder-server-linux.tar.gz && cd server
docker compose up -d --build     # start (to update, see below)
docker compose logs -f           # who joins, seats, results, who's updating
```

Compose keeps campaigns in a Docker volume, so they survive updates.

The server is an **x86_64** program. On an ARM machine (an Apple Silicon
Mac, say) Docker has to build and run an amd64 image, under emulation. The
package's `docker-compose.yml` says so (`platform: linux/amd64`) from
0.13.1 on. With an older compose file, build with
`DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose up -d --build`;
otherwise you get an arm64 image and the server restarts over and over
(Rosetta's "failed to open elf" in the log).

The server **updates itself** from the game's public releases (see How
updating works). To update it by hand instead (or to pick up a changed
`Dockerfile` or `docker-compose.yml`), put the new package in a fresh `server` folder rather than
unpacking it over the old one. Unpacking over it leaves every older
version's `downloads/<version>/` behind (about 300 MB each), and the image
copies them all in. From the folder that holds `server`:

```sh
mv server server-old                          # keep it until the new one runs
tar -xzf PiratesPlunder-server-linux.tar.gz   # a fresh server/
diff server-old/docker-compose.yml server/docker-compose.yml  # put back settings you changed
cd server && docker compose up -d --build
docker compose logs --tail 20                 # the new version, and "Keeps saved games"
rm -rf ../server-old                          # once it's running
```

Keep the folder's name `server`. Compose names the saves volume after the
folder (`server_saves`), so a folder with another name would start with no
saved games.

**With systemd**, no Docker: follow the steps at the top of
`pirates-plunder.service`.

**By hand**, to try it: `./run.sh --crews=4` (or
`./PiratesPlunder-server.x86_64 --headless -- --crews=4`, which doesn't
update itself).

**Updating by hand** means a new package unpacked in place of the old one
(with Docker, see above: a fresh folder, not over the old one), and a
restart. Usually there's no need: the server updates itself.

### Straight from the source, without a Mac build

`server/Dockerfile.source` in the repository builds an image that downloads
Godot (and checks its checksum) and runs the project from source:
`docker build -f server/Dockerfile.source -t pirates-plunder-server .` from
the repository root. It has no downloads to hand out unless you mount a
folder and set `PP_DOWNLOADS`, so older copies are told which version to
get instead of being updated.

### More than one game at once

Each server runs one match. For more, run more containers on different
ports, for example `-p 24682:24680/udp -p 24683:24681/udp` for a second one
(the second port is for server lists). On your tailnet only the usual port
pair is looked for, so players type `address:24682` on the Play on a Server
screen. A later version could add rooms, meaning one address with a list of
open games.

## Where to host it

The game uses **UDP** (Godot's ENet), so the host must accept UDP traffic.
Services that only forward web traffic (Heroku and its kind) won't work.

- **A small VPS** (Hetzner, DigitalOcean, Linode, Vultr: about $5 a month)
  is the simplest choice (step by step, with HTTPS for phones: [A public
  server, step by step](#a-public-server-step-by-step)). Install Docker, run the commands above, and open
  the ports in the firewall: `sudo ufw allow 24680:24681/udp` (and
  `sudo ufw allow 24680:24682/tcp` for players in a web browser). Some providers also
  have their own firewall in the web console. Players type the VPS's IP
  address, or a domain name pointed at it. One small machine handles many
  games, because each is turn-based and idle most of the time.
- **Fly.io** supports UDP, but your app must listen on Fly's special address:
  set `PP_BIND=fly-global-services` and give the app a dedicated IPv4 address.
  This route is untested.
- **Your own computer**, or one at home, works well for friends with
  Tailscale: **share the machine** with each friend (Tailscale admin console,
  Machines, the ... beside it, Share) and it shows up in their server list.
  Docker on a Mac or Windows machine works too. Without Tailscale, forward
  UDP 24680 and 24681 on your router.

Players type the address as `host` or `host:port`, and a domain name works
as well as an IP address.

## A public server, step by step

For a server anyone on the internet can play on, not only friends on your
tailnet. About half an hour, and about $5 a month for the machine.

**Before you share the address widely**, know what an open server means
today:

- **Anyone with the address can join** and start games. There are no
  accounts or passwords, players choose their own names, and there's no
  kick or ban yet.
- **Chat isn't moderated**, and desktop traffic isn't encrypted (browser
  players behind HTTPS are).
- **A modified copy could see through the fog**: the server sends every
  sailor's position and each copy hides what its crew can't see.
- **Older copies update themselves from your server**, about 110 to 210 MB
  each, which counts against the machine's bandwidth allowance.

That's fine for a community of people you're glad to play with. It's worth
knowing before posting the address somewhere busy.

**1. A machine.** Any small Linux VPS (Hetzner, DigitalOcean, Linode,
Vultr) with an **x86_64** processor; 1 GB of memory is plenty. These steps
assume Ubuntu. For phone and browser players you also need a **domain
name** pointed at the machine (an A record, say `play.example.com`):
browsers only run the game on an https page, and a certificate needs a name.

**2. Docker.** Logged in to the machine:

```sh
curl -fsSL https://get.docker.com | sudo sh
```

**3. The server.** Download the latest release, check it against its
fingerprint, and unpack it:

```sh
curl -LO https://github.com/sparkly-quasar/Pirates-Plunder/releases/latest/download/PiratesPlunder-server-linux.tar.gz
curl -LO https://github.com/sparkly-quasar/Pirates-Plunder/releases/latest/download/SHA256SUMS.txt
sha256sum --ignore-missing -c SHA256SUMS.txt     # should say: OK
tar -xzf PiratesPlunder-server-linux.tar.gz && cd server
```

**4. Its name and settings.** Open `docker-compose.yml` and give it a name
for players' server lists (`PP_NAME: "Your Server"`; without one they see
its address). The other settings are explained beside them and in
[Settings](#settings). If you'll set up HTTPS (step 7), also change the
three `/tcp` lines under `ports` so only Caddy can reach them:

```yaml
      - "127.0.0.1:24680:24680/tcp"
      - "127.0.0.1:24681:24681/tcp"
      - "127.0.0.1:24682:24682/tcp"
```

(Ports Docker publishes skip the firewall, so this is what keeps them
private.)

**5. Start it.**

```sh
sudo docker compose up -d --build
sudo docker compose logs --tail 20     # its version, its name, and the ports it listens on
```

It starts again by itself after a reboot, and keeps saved games and the
Hall of Fame in a Docker volume.

**6. Open the game's ports.** Desktop players connect over UDP:

```sh
sudo ufw allow OpenSSH
sudo ufw allow 24680:24681/udp
sudo ufw enable
```

Some providers also have a firewall of their own in their web console:
open UDP 24680 and 24681 there too. Desktop players can now choose **Play
on a Server** and type `play.example.com` (or the machine's IP address).

**7. HTTPS for phones and browsers.** Install Caddy
([caddyserver.com/docs/install](https://caddyserver.com/docs/install)),
then put the package's `Caddyfile` in place with your domain name in it:

```sh
sudo cp Caddyfile /etc/caddy/Caddyfile
sudo sed -i 's/play.example.com/YOUR.DOMAIN/' /etc/caddy/Caddyfile
sudo ufw allow 80,443/tcp
sudo systemctl reload caddy
```

Caddy gets the certificate by itself. Players open
**`https://YOUR.DOMAIN/`** on a phone or in any browser, and play alongside
the desktop copies. (`tools/caddy_test.sh` checks this Caddyfile with the
browser test.)

**8. Updating** happens by itself: the server checks GitHub every hour and
switches to a new version while nobody is playing (see [How updating
works](#how-updating-works)). Players' copies catch up from it the next
time they connect. The only time you need to do anything is when a release
note says the Docker setup itself changed: then download the new package as
in step 3 and follow [the update steps above](#put-it-on-a-server).

**9. Tell people.** Share the address. A server outside their tailnet
isn't listed by itself; players type it once under **Play on a Server**.

## How the server list asks

The question is one UDP packet of 512 bytes to the status port (`PPQ1` and
padding). The answer, `PPS1` and a short JSON object (version, name, what
it's doing, who's there), is always smaller than the question, and an address
gets at most five answers a second, so a server can't be used to flood
anyone. A server that's busy or out of reach simply doesn't appear.

## Getting back in after a dropped connection

A player is recognised by a random id their copy of the game keeps (in a
browser, in that browser's storage on that device), not by their address.
Their game tries to reconnect by itself for two minutes whenever the
connection drops partway through a match.

**Playing alone** (against the computer, or the last player left): the
moment their connection drops, the game is **saved for them** and the server
is free for others. If their game reconnects, the server opens it again and
they're straight back where they were. If not, their server list offers it
under **Your saved games here: Continue** (once the server is free).

**With other players**: the game **pauses**, and everyone sees "Waiting for
them to come back" counting down from `rejoin-seconds` (2 minutes). If they
come back, play carries on where it stood. If not, everyone still playing is
asked, and whoever answers first decides:

- **Give their crew to the computer.** Play carries on. If they come back
  later, they take their crew back (mid-game they land on the island as it
  stands; between games they go to the coaching). The list offers **Rejoin
  Your Crew**.
- **Keep waiting**, another `rejoin-seconds`.
- **Save the game for later.** Everyone is sent to the server list, where
  the game is in each player's saved games. Whoever continues it leads it;
  the others join and come back into their own crews, and the leader can set
  sail without anyone who doesn't.

If their old connection is still hanging on when they reconnect, the new one
takes over from it. Players who leave on purpose (back to the menu) aren't
waited for: the computer takes their crew at once. Player-hosted games (Play
Direct) work the same way; saving for later there saves to the host's
**Continue Online Match**.

## Players in a web browser, and on phones

The server hands out the game for web browsers itself, on TCP `page-port`
(24682): open **`http://<the server's address>:24682/`** and the game loads,
already pointed at that server. That works on the server's own machine
(`http://localhost:24682/`), but **a phone or another computer needs
HTTPS**: browsers only run the game on a secure page, and otherwise show
"Secure Context - Check web server configuration (use HTTPS)". Hold the
phone sideways. Safari's **Share > Add to Home Screen** makes it an icon.

### HTTPS with Tailscale (for phones)

`tailscale serve` gives the server's machine a real HTTPS certificate for
its Tailscale name, reachable only from your tailnet. Run on the server's
machine (Tailscale allows HTTPS ports 443, 8443 and 10000; take a free one,
`tailscale serve status` shows what's in use):

```sh
tailscale serve --bg --https=10000 http://127.0.0.1:24682
tailscale serve --bg --https=10000 --set-path /ws http://127.0.0.1:24680
tailscale serve --bg --https=10000 --set-path /status http://127.0.0.1:24681
```

Then on the phone, with the Tailscale app switched on, open
**`https://<machine>.<tailnet>.ts.net:10000/`** (`tailscale status` and
the admin console show the name). The page fetches the game from `/`, and
on https connects through `/ws` and `/status` on the same address, as
WebSockets. To check the WebSocket paths by hand, use HTTP/1.1:
`curl -s -o /dev/null -w "%{http_code}\n" --http1.1 --max-time 5 -H
"Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13"
-H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" https://<name>:10000/ws`
should print 101. Without `--http1.1`, curl picks HTTP/2 over https and
`tailscale serve` answers 502, though browsers connect fine. The setting survives restarts; `tailscale serve --https=10000
off` removes it. The page in the 0.10.0 package (and older) still follows
the `?server=` that `/` adds, which can't work on https; with those, open
`/index.html` instead of `/`.

Browser players play alongside the Mac and Windows copies, in the same
lobby and match. A browser can't use the desktop game's connection (ENet
over UDP), so it connects over WebSockets on TCP `web-port` (24680) and asks
what the server is doing over a WebSocket to the status port (24681).

On a phone or tablet (a touch screen without a mouse) the game lays itself
out for the screen held sideways, and tall screens scroll with a finger. On
the island: **tap** one of your crew, then where to go; **drag** to look
around; **pinch** to zoom; **double-tap** one of yours to dig. A bar of
buttons along the bottom does what the keys do: Stand, Run, Crawl, Dig,
Next, Centre, zoom, Chat and **End Turn**. Add `?touch=1` to the address to
try the phone layout on a computer (`?touch=0` to turn it off).

The web version is the **Web** export preset (single-threaded, so it needs
no special headers and runs on iPhones); `tools/package.sh` builds it into
`web/` beside the server, with the big files also gzipped (about 11 MB to
download instead of 40). Run from source, the server finds it in
`godot/build/server/web/` once you've exported it there.

The server itself speaks plain HTTP. On the open internet, put it behind a
web server with HTTPS (Caddy, say) set up like the `tailscale serve`
commands above: `/` to the page port, and `/ws` and `/status` passed
through as WebSockets to the web and status ports.

`tools/web_test.sh` checks a browser-style player (over WebSockets) and a
desktop player (over ENet) starting, joining and playing a game together on
the real server.

## Hall of Fame

The server keeps a lifetime record for each player who finishes a game
there, by the random id their copy keeps: games, wins, Battle Royale titles,
chests got aboard and captures, in `hall_of_fame.cfg` in the saves folder
(with Docker, in the saves volume; without `--saves`, in the server's
`user://`). Players see the top of it, with their own row, under **Hall of
Fame** in their server list (its own small question on the status port).
Only players still sailing their crew when a game ends are counted. Delete
the file to start it afresh.

## Turn limits

`turn-seconds` (default 180; `PP_TURN_SECONDS` in Docker) is the turn limit
a new game starts with. A player starting a game can pick another (none, 1,
2, 3 or 5 minutes), and games in an always-open lobby use this one. Each
player's screen shows a clock; when it runs out the turn passes on, and an
unanswered fight or hand-off is settled first. The clock waits while crews
come ashore and while the game is paused.

## Battle Royale

A player starting a game picks **Battle Royale** in its settings: every crew
for itself, 1, 3 or 5 rounds, and whether Vega may sail every round (else
only in the final one). Each player brings the crew they've trained in
single player; the server checks every crew against the coaching limits
before it lands (`GameConfig.sanitize_crew`), so a tampered copy can't bring
super-sailors. Computer crews in it are fresh, at the crew size chosen. A
minute after the last round the server thanks everyone and opens up again.
`tools/royale_test.sh` checks one on the real server and one hosted directly.

## How updating works

**The server keeps itself up to date** (`auto-update`, on by default).
Every hour, and as soon as a copy newer than the server tries to join, it
asks the game's public releases on GitHub for the latest version. If
there's a newer one, it downloads the server package, checks it against the
release's `SHA256SUMS.txt`, and unpacks it into `saves/updates/<version>/`.
It waits until nobody is connected and no match is running, then restarts
into the new version with the same settings. A match in progress is never
interrupted, and the new package carries that version's Mac and Windows
downloads and web version, so players then catch up from the server as
before. The log says each step (`Auto-update: ...`).

This works through `run.sh`, which starts the server and switches to the
new version when it asks. The Docker image and `pirates-plunder.service`
both start the server that way. A restart starts the version the package came with,
which switches at once to the newest one already downloaded.

**In Docker the container restarts** for an update: the server stops, Docker
starts the container again, and `run.sh` starts the new version, with
every port set up afresh. (This came from a suspicion that swapping the
server inside a running container broke Docker Desktop's forwarding of UDP
24681. It didn't: that port once failed during a run with no update. But a
fresh container for each version does no harm.) So the container needs a restart policy: `restart: unless-stopped` in `docker-compose.yml`
(already there), or `--restart unless-stopped` with `docker run`. An image
built from a package before 0.15.4 has the old `run.sh`, so it keeps
swapping inside the container (and auto-update can't change the image
itself): build it once from a 0.15.4 or newer package, in a fresh folder
as under Put it on a server, and later updates restart the container. If a new
version fails to start, the server doesn't switch to it again and carries
on with the version it has. To stay on one version, set `auto-update=false`
(`PP_AUTO_UPDATE: "false"`).

**Check for Updates** on the main menu asks the game's public releases on
GitHub for the latest version. If it's newer, it offers to update: the game
downloads this computer's file from the release (the Mac app zipped, or the
Windows exe), checks it against the release's `SHA256SUMS.txt`, installs it
and restarts. If GitHub can't be reached, it asks the servers on your
tailnet instead. On a computer it can't update by itself (Linux, say), it
offers the releases page.

**Check for Updates** on the Play on a Server screen asks the servers it
finds for their version and, if one is newer, updates from it straight
away (connecting only for that, not to play), then comes back to the list.
With nothing newer it says you're up to date, and names any server that's
older than you.

A copy with a different version can't play on the server. If it's older and
the server has the downloads for its computer, the copy fetches them over
the same connection (checking every byte), installs them in place of itself,
restarts and rejoins. On a server this starts by itself; between two
players' own copies it's still a button. A copy that's newer than the server,
or one the server has no download for, is told which version it needs and
disconnected.

The downloads live in a folder named after the version, so a server can
never hand out the wrong build:

```
downloads/0.7.0/PiratesPlunder-mac.zip
downloads/0.7.0/PiratesPlunder-windows.exe
```

`package.sh` puts them there. To use another folder, set `downloads`.

## Saved games

The server keeps every match in the `saves` folder (`PP_SAVES`), one file
each (`<id>.cfg`): its score and coached crews, the game in progress, and
who sailed which crew. It saves whenever the turn passes, after every game,
and when everyone has gone, so a restart or an update loses almost nothing.

A saved game belongs to the players who played it. Each player's server list
shows their own (up to three, newest first, with when and who: "Game 2,
turn 5, with Ann and Ben"), and any of them can **Continue** one while the
server is free; the others come back into their own crews. A reopened saved
game waits for the players who sailed it: their crews are kept for them
(nobody else can take one, and the computer doesn't fill them), and it sets
sail once they're all back. **Delete** (press
it twice to be sure) takes one off that player's list, at any time: if the
others who played it still have it, it stays for them (the computer would
sail the crew of whoever deleted it), and when the last of them deletes it,
the file goes. Only someone who played a game can delete it. The server keeps
each player's three most recent saved games and deletes older ones, and any
older than `save-days`. To clear them all, stop the server and empty the
folder. A `campaign.cfg` from before 0.10 is kept as one more saved game.

The server checks at start that it can write there. If it can't, the log
says "Couldn't write to ... for saved games, so none are kept." **With
Docker**, the server runs as the user `pirate` (uid 10001). In packages
after 0.10.0 the image's saves folder belongs to `pirate`, so a new `saves`
volume does too. But a volume made by 0.10.0 or older belongs to root, and Docker doesn't
change a volume's owner once it has made it. Give it to `pirate` once (the
volume is named after the folder Compose runs in, `server_saves` from
`server/`; `docker volume ls` lists them):

```sh
docker run --rm -v server_saves:/s debian:bookworm-slim chown 10001:10001 /s
docker compose restart
```

Hosting from the game works the same way: an online match saves itself
after every game (and the host can Save and Quit partway through one), and
**Continue Online Match** (main menu, Multiplayer) hosts it again for the same
friends.

## What it doesn't do yet

- **Encryption.** Traffic is not encrypted, chat included. That's fine among
  friends; before strangers or accounts, ENet's DTLS first.
- **Cheat-proofing.** Each player's copy is sent every person's position and
  only hides opponents it can't see, so a modified copy could reveal them.
  That's fine among friends. Before the server is open to strangers, the
  server should stop sending what a crew can't see.
- **Rooms, spectators, and joining a match in progress.** One game and one
  campaign per server; run more servers on other ports for more.
- **Kicking, banning or moderating chat** on a public server.
