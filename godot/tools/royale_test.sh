#!/bin/bash
# The Battle Royale test: the real server and two players (Ann starts a
# Battle Royale and brings a trained crew; Bo brings none), on localhost. See
# tools/net_royale_driver.gd for what each player checks.
# Run from anywhere:  godot/tools/royale_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24697
logs=$(mktemp -d)

# A Hall of Fame from earlier games, for Bo to ask for.
mkdir -p "$logs/saves"
cat > "$logs/saves/hall_of_fame.cfg" <<'HALL'
[someone]
name="Champ"
games=8
wins=5
titles=2
aboard=12
captures=4
at=0

[royale-bo]
name="Bo"
games=3
wins=1
titles=0
aboard=2
captures=1
at=0
HALL

"$GODOT" --headless --path . -- --server --port=$PORT --once --crews=2 --most-crews=4 \
	--load-seconds=30 --downloads="$logs/no-downloads" --saves="$logs/saves" > "$logs/server.txt" 2>&1 &
server=$!
sleep 3 # let it start listening

player() { "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$@"; }
player royale-ann --player-name=Ann --player-id=royale-ann > "$logs/royale-ann.txt" 2>&1 &
a=$!
sleep 2 # Ann starts the game; Bo finds it in the list
player royale-bo --player-name=Bo --player-id=royale-bo > "$logs/royale-bo.txt" 2>&1 &
b=$!

fail=0
for pid in $a $b; do
	wait "$pid" || fail=1
done

# With --once the server stops by itself once every player has left.
for _ in $(seq 30); do
	kill -0 "$server" 2>/dev/null || break
	sleep 1
done
if kill -0 "$server" 2>/dev/null; then
	echo "  [FAIL] the server didn't shut down after the match"
	kill "$server"
	fail=1
else
	wait "$server" || { echo "  [FAIL] the server exited with an error"; fail=1; }
fi

# A Battle Royale hosted by a player (Play Direct), no server.
player royale-host --player-name=Hal --player-id=royale-hal > "$logs/royale-host.txt" 2>&1 &
h=$!
sleep 3
player royale-guest --player-name=Gus --player-id=royale-gus > "$logs/royale-guest.txt" 2>&1 &
g=$!
for pid in $h $g; do
	wait "$pid" || fail=1
done

for who in royale-ann royale-bo royale-host royale-guest; do
	grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR|ERROR:' "$logs/$who.txt"
done
echo "--- server log ---"
grep -vE '^\s*$' "$logs/server.txt"
echo "(full logs in $logs)"
if [ $fail -eq 0 ]; then echo "ROYALE_TEST: ALL PASS"; else echo "ROYALE_TEST: FAIL"; fi
exit $fail
