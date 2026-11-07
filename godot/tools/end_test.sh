#!/bin/bash
# End the Game: the real server and two players. Ann's connection goes; Ben
# is asked at once and ends the game: he's sent away, and nothing is saved.
# See tools/net_end_driver.gd.
# Run from anywhere:  godot/tools/end_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24663
logs=$(mktemp -d)
"$GODOT" --headless --path . -- --server --port=$PORT --web-port=-1 --rejoin-seconds=30 --auto-update=false \
	--load-seconds=30 --downloads="$logs/no-downloads" --saves="$logs/saves" > "$logs/server.txt" 2>&1 &
server=$!
sleep 3
player() { timeout 160 "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$@"; }
player end-ann --player-name=Ann --player-id=end-ann > "$logs/end-ann.txt" 2>&1 &
a=$!
player end-ben --player-name=Ben --player-id=end-ben > "$logs/end-ben.txt" 2>&1 &
b=$!
fail=0
for pid in $a $b; do wait "$pid" || fail=1; done
kill "$server" 2>/dev/null; wait "$server" 2>/dev/null
expect() {
	if grep -qF "$1" "$logs/server.txt"; then echo "  [PASS] server: $2"
	else echo "  [FAIL] server: $2 (no \"$1\" in its log)"; fail=1; fi
}
expect "Ben ended the game." "Ben ends the game"
expect "Match over: its players ended it" "and the match is over"
if ls "$logs/saves"/*.cfg > /dev/null 2>&1; then echo "  [FAIL] server: a saved game was kept"; fail=1; else echo "  [PASS] server: no saved game kept"; fi
for who in end-ann end-ben; do grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR' "$logs/$who.txt"; done
if [ $fail -eq 0 ]; then rm -rf "$logs"; echo "END_TEST: ALL PASS"; else echo "(logs in $logs)"; echo "END_TEST: FAIL"; exit 1; fi
