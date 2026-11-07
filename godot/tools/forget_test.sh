#!/bin/bash
# Deleting a saved game from a server's list (the server list's Delete), on
# the real dedicated server: a player who wasn't in it is refused; Ann
# deletes it from her list and Ben still has it; Ben deletes it and the file
# is gone. See tools/forget_driver.gd.
# Run from anywhere:  godot/tools/forget_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24665
work=$(mktemp -d)
fail=0
check() { if eval "$1"; then echo "  [PASS] $2"; else echo "  [FAIL] $2"; fail=1; fi; }
drive() { timeout 60 "$GODOT" --headless --path . -s res://tools/forget_driver.gd -- "$@" 2>&1; }

mkdir -p "$work/saves"
id=$(drive make "$work/saves" | sed -n 's/^MADE: //p')
check '[ -n "$id" ] && [ -f "$work/saves/$id.cfg" ]' "a saved game shared by Ann and Ben is on the server"

"$GODOT" --headless --path . -- --server --port=$PORT --web-port=-1 --status-port=-1 --auto-update=false \
	--saves="$work/saves" > "$work/server.txt" 2>&1 &
server=$!
sleep 3

cat=$(drive forget $PORT "$id" --player-id=cat-id | sed -n 's/^FORGET_SAID: //p')
check '[[ "$cat" == *"isn'"'"'t on this server"* ]] && [ -f "$work/saves/$id.cfg" ]' "someone who wasn't in it can't delete it ($cat)"
ann=$(drive forget $PORT "$id" --player-id=ann-id | sed -n 's/^FORGET_SAID: //p')
check '[[ "$ann" == *"others who played it still have it"* ]] && [ -f "$work/saves/$id.cfg" ]' "Ann deletes it from her list; it stays for Ben ($ann)"
ann2=$(drive forget $PORT "$id" --player-id=ann-id | sed -n 's/^FORGET_SAID: //p')
check '[[ "$ann2" == *"isn'"'"'t on this server"* ]]' "and it's no longer Ann's to delete"
ben=$(drive forget $PORT "$id" --player-id=ben-id | sed -n 's/^FORGET_SAID: //p')
check '[[ "$ben" == *"gone from this server"* ]] && [ ! -f "$work/saves/$id.cfg" ]' "Ben deletes it and it's gone for good ($ben)"
check 'grep -q "deleted saved game" "$work/server.txt"' "the server's log says so"

kill $server 2>/dev/null; wait $server 2>/dev/null
if [ $fail -eq 0 ]; then rm -rf "$work"; echo "FORGET_TEST: ALL PASS"; else echo "(logs in $work)"; echo "FORGET_TEST: FAIL"; exit 1; fi
