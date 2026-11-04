#!/bin/bash
# The browser test: the real server and two players on this machine over
# localhost, one connecting the way a copy in a web browser does (WebSockets,
# for the game and for the server's status) and one the way the desktop game
# does (ENet and UDP). See tools/net_web_driver.gd for what each checks.
# Run from anywhere:  godot/tools/web_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24689
logs=$(mktemp -d)

"$GODOT" --headless --path . -- --server --port=$PORT --once \
	--load-seconds=30 --downloads="$logs/no-downloads" --saves="$logs/saves" > "$logs/server.txt" 2>&1 &
server=$!
sleep 3 # let it start listening

player() { "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$@"; }
player web-wendy --player-name=Wendy --player-id=web-wendy > "$logs/web-wendy.txt" 2>&1 &
w=$!
player web-dan --player-name=Dan --player-id=web-dan > "$logs/web-dan.txt" 2>&1 &
d=$!

fail=0
for pid in $w $d; do
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

for who in web-wendy web-dan; do
	grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR|ERROR:' "$logs/$who.txt"
done
echo "--- server log ---"
grep -vE '^\s*$' "$logs/server.txt"
echo "(full logs in $logs)"
if [ $fail -eq 0 ]; then echo "WEB_TEST: ALL PASS"; else echo "WEB_TEST: FAIL"; fi
exit $fail
