#!/bin/bash
# The rejoin test: the real server (waiting 6s for a player who drops, saving
# games in a folder of its own) and two players on this machine over
# localhost, one over WebSockets as a browser and one over ENet. Their
# connections drop, hang and come back; the game waits, asks, is saved and
# continued. See tools/net_rejoin_driver.gd for what each checks; the
# server's log is checked here.
# Run from anywhere:  godot/tools/rejoin_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24685
logs=$(mktemp -d)

"$GODOT" --headless --path . -- --server --port=$PORT --rejoin-seconds=6 \
	--load-seconds=30 --downloads="$logs/no-downloads" --saves="$logs/saves" > "$logs/server.txt" 2>&1 &
server=$!
sleep 3 # let it start listening

player() { "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$@"; }
player rejoin-ann --player-name=Ann --player-id=rejoin-ann > "$logs/rejoin-ann.txt" 2>&1 &
a=$!
player rejoin-ben --player-name=Ben --player-id=rejoin-ben > "$logs/rejoin-ben.txt" 2>&1 &
b=$!

fail=0
for pid in $a $b; do
	wait "$pid" || fail=1
done
sleep 1
kill "$server" 2>/dev/null
wait "$server" 2>/dev/null

# What the server said along the way.
expect() {
	if grep -qF "$1" "$logs/server.txt"; then echo "  [PASS] server: $2"
	else echo "  [FAIL] server: $2 (no \"$1\" in its log)"; fail=1; fi
}
expect "The NAVS' player lost their connection; the game waits 6s for them to come back." "the game waits for Ann"
expect "Ann is back. Play on!" "and carries on when she's back"
expect "Nobody came back in time; asking the other players what to do." "it asks the others when she doesn't come back"
expect "Ben gave Ann's crew to the computer." "Ben gives her crew to the computer"
expect "The NAVS' player is back at the helm." "Ann takes it back"
expect "Ben chose to keep waiting for Ann." "Ben chooses to keep waiting"
expect "Ben saved the game for later, as" "then saves it for later"
expect "continues saved game" "Ann continues it from her list"
expect "The NAVS' player left; the computer sails their crew." "Ann leaving on purpose isn't waited for"
expect "for players who lost their connection to come back to" "Ben alone drops: the game is saved for him"
expect "is back, reopening saved game" "and reopened when his copy reconnects"
ls "$logs/saves"/*.cfg > /dev/null 2>&1 && echo "  [PASS] server: saved games are on disk" || { echo "  [FAIL] server: no saved games on disk"; fail=1; }

for who in rejoin-ann rejoin-ben; do
	grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR|ERROR:' "$logs/$who.txt" | grep -v "resources still in use"
done
echo "--- server log ---"
grep -vE '^\s*$' "$logs/server.txt"
echo "(full logs in $logs)"
if [ $fail -eq 0 ]; then echo "REJOIN_TEST: ALL PASS"; else echo "REJOIN_TEST: FAIL"; fi
exit $fail
