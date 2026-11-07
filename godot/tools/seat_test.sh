#!/bin/bash
# A saved game reopened waits for the players who sailed it: on the real
# server, Ann continues a game she played with Ben; Cat (not in it) is turned
# away; Ann can't set sail without Ben; Ben joins, gets his crew back, and the
# game sets sail. See tools/seat_driver.gd.
# Run from anywhere:  godot/tools/seat_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24661
work=$(mktemp -d)
fail=0
check() { if eval "$1"; then echo "  [PASS] $2"; else echo "  [FAIL] $2"; fail=1; fi; }
drive() { timeout 90 "$GODOT" --headless --path . -s res://tools/seat_driver.gd -- "$@" 2>&1 | grep "^SEAT:"; }

mkdir -p "$work/saves"
id=$(timeout 60 "$GODOT" --headless --path . -s res://tools/forget_driver.gd -- make "$work/saves" 2>&1 | sed -n 's/^MADE: //p')
check '[ -n "$id" ]' "a saved game of Ann's and Ben's is on the server"
"$GODOT" --headless --path . -- --server --port=$PORT --web-port=-1 --status-port=-1 --auto-update=false \
	--load-seconds=30 --saves="$work/saves" > "$work/server.txt" 2>&1 &
server=$!
sleep 3

drive continue $PORT "$id" --player-id=ann-id --player-name=Ann > "$work/ann.txt" &
ann=$!
sleep 6
cat_said=$(drive join $PORT --player-id=cat-id --player-name=Cat)
check '[[ "$cat_said" == *"waiting for the players who sailed it"* ]]' "Cat, who wasn't in it, is turned away ($cat_said)"
sleep 2
drive join $PORT --player-id=ben-id --player-name=Ben > "$work/ben.txt"
wait $ann
check 'grep -q "in, as crew 0" "$work/ann.txt"' "Ann continues it, in her own crew"
check 'grep -q "asked to set sail alone; sailed: false; waiting for: Ben" "$work/ann.txt"' "Ann can't set sail without Ben; the lobby says it's waiting for him ($(grep 'alone' "$work/ann.txt"))"
check 'grep -q "in, as crew 1" "$work/ben.txt"' "Ben comes back into his own crew"
check 'grep -q "sailed once they were back: true" "$work/ann.txt" && grep -q "sailed: true" "$work/ben.txt"' "and once he's back, the game sets sail"
check 'grep -q "the saved game waits for Ben" "$work/server.txt"' "the server's log says it waited for Ben"

kill $server 2>/dev/null; wait $server 2>/dev/null
if [ $fail -eq 0 ]; then rm -rf "$work"; echo "SEAT_TEST: ALL PASS"; else echo "(logs in $work)"; echo "SEAT_TEST: FAIL"; exit 1; fi
