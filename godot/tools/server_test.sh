#!/bin/bash
# The dedicated-server network test: the real server (started with --server,
# as it would be on a VPS) and four players, all on this machine over
# localhost, with the lobby always open (lobby=always, as in 0.7.0; see
# tools/lobby_test.sh for games players start). See
# tools/net_server_driver.gd for what each player checks.
# (An empty downloads folder, so the old-version player is turned away rather
# than offered an update even if tools/package.sh has built one.)
# Run from anywhere:  godot/tools/server_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24697
logs=$(mktemp -d)

"$GODOT" --headless --path . -- --server --port=$PORT --lobby=always --once --turn-seconds=10 \
	--start-after=0 --load-seconds=30 --downloads="$logs/no-downloads" --saves="$logs/saves" > "$logs/server.txt" 2>&1 &
server=$!
sleep 3 # let it start listening

player() { "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$@"; }
player server-navs --player-id=server-navs > "$logs/server-navs.txt" 2>&1 &
navs=$!
player server-pirates --player-id=server-pirates > "$logs/server-pirates.txt" 2>&1 &
pirates=$!
player server-old --pretend-version=0.0.1 --player-id=server-old > "$logs/server-old.txt" 2>&1 &
old=$!
player server-late --player-id=server-late > "$logs/server-late.txt" 2>&1 &
late=$!

fail=0
for pid in $navs $pirates $old $late; do
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

for who in server-navs server-pirates server-old server-late; do
	grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR|ERROR:' "$logs/$who.txt"
done
echo "--- server log ---"
grep -vE '^\s*$' "$logs/server.txt"
echo "(full logs in $logs)"
if [ $fail -eq 0 ]; then echo "SERVER_TEST: ALL PASS"; else echo "SERVER_TEST: FAIL"; fi
exit $fail
