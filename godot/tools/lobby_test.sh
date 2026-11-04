#!/bin/bash
# The player-started-games test: the real server with lobby=players (the
# default) and three players, all on this machine over localhost. See
# tools/net_lobby_driver.gd for what each player checks.
# Run from anywhere:  godot/tools/lobby_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24693
logs=$(mktemp -d)

"$GODOT" --headless --path . -- --server --port=$PORT --once --crews=2 --most-crews=4 \
	--load-seconds=30 --downloads="$logs/no-downloads" --saves="$logs/saves" > "$logs/server.txt" 2>&1 &
server=$!
sleep 3 # let it start listening

player() { "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$@"; }
player lobby-a --player-name=Alice --player-id=lobby-alice > "$logs/lobby-a.txt" 2>&1 &
a=$!
player lobby-b --player-name=Bob --player-id=lobby-bob > "$logs/lobby-b.txt" 2>&1 &
b=$!
player lobby-c --player-name=Cara --player-id=lobby-cara > "$logs/lobby-c.txt" 2>&1 &
c=$!

fail=0
for pid in $a $b $c; do
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

for who in lobby-a lobby-b lobby-c; do
	grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR|ERROR:' "$logs/$who.txt"
done
echo "--- server log ---"
grep -vE '^\s*$' "$logs/server.txt"
echo "(full logs in $logs)"
if [ $fail -eq 0 ]; then echo "LOBBY_TEST: ALL PASS"; else echo "LOBBY_TEST: FAIL"; fi
exit $fail
