#!/bin/bash
# The Play on a Server list against two real servers: one as usual, and one
# whose UDP status port is held by a socket that never answers (as Docker
# Desktop's broken forwarding left a server once). The list finds the first
# over UDP and the second over TCP. See tools/net_finder_driver.gd.
# Run from anywhere:  godot/tools/finder_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
UDP_PORT=24702
TCP_PORT=24704
logs=$(mktemp -d)

# The black hole: holds UDP 24705, the second server's status port, and drops
# everything sent to 127.0.0.1 there. (On a Mac the server's own dual-stack
# socket can still bind beside it; packets to 127.0.0.1 go to this one.)
python3 -I -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('0.0.0.0', $((TCP_PORT + 1))))
while True: s.recv(2048)
" &
hole=$!
sleep 1

"$GODOT" --headless --path . -- --server --port=$UDP_PORT --saves="$logs/saves-a" > "$logs/server-udp.txt" 2>&1 &
server_a=$!
"$GODOT" --headless --path . -- --server --port=$TCP_PORT --saves="$logs/saves-b" > "$logs/server-tcp.txt" 2>&1 &
server_b=$!
sleep 3 # let them start listening

player() { "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$@"; }
fail=0
player finder-udp > "$logs/finder-udp.txt" 2>&1 || fail=1
player finder-tcp > "$logs/finder-tcp.txt" 2>&1 || fail=1

kill "$server_a" "$server_b" "$hole" 2>/dev/null
wait "$server_a" "$server_b" "$hole" 2>/dev/null

for who in finder-udp finder-tcp; do
	grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR|ERROR:' "$logs/$who.txt"
done
echo "(full logs in $logs)"
if [ $fail -eq 0 ]; then echo "FINDER_TEST: ALL PASS"; else echo "FINDER_TEST: FAIL"; fi
exit $fail
