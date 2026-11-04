#!/bin/bash
# Check for Updates on the Play on a Server screen, against the real server:
# a copy posing as an older version fetches the server's version (a dry run,
# nothing installed), one on the same version and one posing as newer are
# told they're up to date. See tools/net_check_update_driver.gd.
# Run from anywhere:  godot/tools/check_update_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24677
logs=$(mktemp -d)
version=$(sed -n 's/^config\/version="\(.*\)"/\1/p' project.godot)

# Stand-in downloads for the server's version, for both computers.
mkdir -p "$logs/downloads/$version"
head -c 300000 /dev/urandom > "$logs/downloads/$version/PiratesPlunder-mac.zip"
head -c 200000 /dev/urandom > "$logs/downloads/$version/PiratesPlunder-windows.exe"

"$GODOT" --headless --path . -- --server --port=$PORT --web-port=-1 \
	--downloads="$logs/downloads" --saves="$logs/saves" > "$logs/server.txt" 2>&1 &
server=$!
sleep 3 # let it start listening

player() { "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$@"; }
fail=0
player check-old --pretend-version=0.0.1 > "$logs/check-old.txt" 2>&1 || fail=1
player check-same > "$logs/check-same.txt" 2>&1 || fail=1
player check-newer --pretend-version=99.0.0 > "$logs/check-newer.txt" 2>&1 || fail=1

kill "$server" 2>/dev/null
wait "$server" 2>/dev/null

for who in check-old check-same check-newer; do
	grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR|ERROR:' "$logs/$who.txt"
done
echo "--- server log ---"
grep -vE '^\s*$' "$logs/server.txt"
echo "(full logs in $logs)"
if [ $fail -eq 0 ]; then echo "CHECK_UPDATE_TEST: ALL PASS"; else echo "CHECK_UPDATE_TEST: FAIL"; fi
exit $fail
