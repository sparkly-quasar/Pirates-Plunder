#!/bin/bash
# The public server's web front: the browser test (tools/web_test.sh) with
# the browser-style player going through Caddy, set up as the package's
# Caddyfile (server/Caddyfile) says, on plain http on this machine: the game
# at /ws and the server's status at /status, as WebSockets. Needs caddy.
# Run from anywhere:  godot/tools/caddy_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
command -v caddy > /dev/null || { echo "CADDY_TEST: SKIPPED (no caddy)"; exit 0; }
dir=$(mktemp -d)
# The package's Caddyfile, on http://127.0.0.1:8099 and the browser test's ports.
sed -e 's#^play.example.com {#http://127.0.0.1:8099 {#' -e 's/24680/24689/; s/24681/24690/; s/24682/24691/' \
	../server/Caddyfile > "$dir/Caddyfile"
grep -q "127.0.0.1:24690" "$dir/Caddyfile" || { echo "CADDY_TEST: FAIL (Caddyfile not as expected)"; exit 1; }
caddy run --config "$dir/Caddyfile" --adapter caddyfile > "$dir/caddy.txt" 2>&1 &
c=$!
sleep 2
VIA=ws://127.0.0.1:8099 bash tools/web_test.sh
result=$?
kill $c 2>/dev/null
wait $c 2>/dev/null
rm -rf "$dir"
if [ $result -eq 0 ]; then echo "CADDY_TEST: PASS"; else echo "CADDY_TEST: FAIL"; exit 1; fi
