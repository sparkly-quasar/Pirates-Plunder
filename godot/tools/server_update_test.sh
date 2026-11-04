#!/bin/bash
# The dedicated server's auto-update, against a stand-in for GitHub (tools/
# fake_github.py) with a newer "server package" whose server only writes down
# that it ran:
#  1. Started by run.sh, a server posing as an old version finds the newer
#     release, downloads it, checks it, unpacks it, and with nobody playing
#     hands over: run.sh starts the new one with the same settings.
#  2. Restarted (GitHub out of reach), it hands over at once to the version
#     it already has.
#  3. A version that never got going after a handover isn't used again.
#  4. Not started by run.sh, it only says a newer version is out.
#  5-7. As in Docker (PP_RESTART_TO_UPDATE=1): run.sh stops instead of
#     switching inside the container; the restart (run.sh again) starts the
#     new version; one that doesn't get going sends the next start back to
#     the image's own version.
# Run from anywhere:  godot/tools/server_update_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24673
GAME=24674
work=$(mktemp -d)
project=$(pwd)
fail=0
# macOS has no timeout(1).
command -v timeout > /dev/null || timeout() { perl -e 'alarm shift; exec @ARGV or die' "$@"; }
# A run cut short by timeout can leave run.sh's server running: stop it.
leftovers() { pkill -f -- "--port=$GAME" 2>/dev/null; sleep 1; }
check() { if eval "$1"; then echo "  [PASS] $2"; else echo "  [FAIL] $2"; fail=1; fi; }

# The old server: this project, posing as version 0.0.1, started through run.sh.
mkdir -p "$work/old"
cp ../server/run.sh "$work/old/"
cat > "$work/old/PiratesPlunder-server.x86_64" <<SH
#!/bin/sh
exec "$(command -v "$GODOT")" --path "$project" "\$@"
SH
chmod +x "$work/old/PiratesPlunder-server.x86_64"

# The new release: a server package whose "server" writes down how it was started.
mkdir -p "$work/pkg/server" "$work/site"
cat > "$work/pkg/server/PiratesPlunder-server.x86_64" <<'SH'
#!/bin/sh
echo "$@" > "$RAN_MARK"
[ -n "${FAIL_START:-}" ] && exit 1
touch "$(dirname "$0")/../STARTED"
exit 0
SH
chmod +x "$work/pkg/server/PiratesPlunder-server.x86_64"
echo 99.0.0 > "$work/pkg/server/VERSION"
tar -czf "$work/site/PiratesPlunder-server-linux.tar.gz" -C "$work/pkg" server
(cd "$work/site" && sha256sum PiratesPlunder-server-linux.tar.gz > SHA256SUMS.txt)
python3 tools/fake_github.py $PORT "$work/site" v99.0.0 &
github=$!
sleep 1

export RAN_MARK="$work/ran.txt"
settings="--server --port=$GAME --web-port=-1 --status-port=-1 --saves=$work/saves --pretend-version=0.0.1"
updates="$work/saves/updates"

# 1. Finds it, fetches it, switches to it.
PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 90 "$work/old/run.sh" $settings > "$work/one.txt" 2>&1
check '[ -f "$RAN_MARK" ] && grep -q -- "--port=$GAME" "$RAN_MARK"' "1: run.sh started the new version, with the same settings"
check 'grep -q "version 99.0.0 is out; downloading it" "$work/one.txt"' "1: the server found the newer release and downloaded it"
check '[ -f "$updates/99.0.0/READY" ] && [ -f "$updates/99.0.0/HANDED_OVER" ] && [ -x "$updates/99.0.0/server/PiratesPlunder-server.x86_64" ]' "1: unpacked into the updates folder, checked and marked"
check '! ls "$updates/downloading/"*.tar.gz > /dev/null 2>&1' "1: the download itself is tidied away"

# 2. A restart, with GitHub out of reach: straight to the version it has.
kill $github 2>/dev/null; wait $github 2>/dev/null
rm -f "$RAN_MARK"
PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 60 "$work/old/run.sh" $settings > "$work/two.txt" 2>&1
check '[ -f "$RAN_MARK" ]' "2: restarted, it switched to the version already downloaded"
check 'grep -q "already downloaded" "$work/two.txt" && ! grep -q "downloading it" "$work/two.txt"' "2: without downloading it again"

# 3. A version that was handed to and never got going is left alone.
rm -f "$RAN_MARK" "$updates/99.0.0/STARTED"
PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 15 "$work/old/run.sh" $settings > "$work/three.txt" 2>&1
leftovers
check '[ ! -f "$RAN_MARK" ] && grep -q "Free: waiting" "$work/three.txt"' "3: a version that never started isn't used again; the old one carries on"

# 4. Not through run.sh: it says so, and stays put.
python3 tools/fake_github.py $PORT "$work/site" v99.0.0 &
github=$!
sleep 1
rm -rf "$updates"
PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 15 "$work/old/PiratesPlunder-server.x86_64" --headless -- $settings > "$work/four.txt" 2>&1
leftovers
check 'grep -q "Version 99.0.0 is out" "$work/four.txt" && [ ! -d "$updates/99.0.0" ]' "4: without run.sh it only says a newer version is out"
kill $github 2>/dev/null; wait $github 2>/dev/null

# 5. As in Docker: finds it, fetches it, and stops for the container to restart.
python3 tools/fake_github.py $PORT "$work/site" v99.0.0 &
github=$!
sleep 1
rm -rf "$updates"
rm -f "$RAN_MARK"
export PP_RESTART_TO_UPDATE=1 PP_LAUNCHER="$work/next-server"
PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 90 "$work/old/run.sh" $settings > "$work/five.txt" 2>&1
code=$?
check '[ $code -eq 75 ] && [ ! -f "$RAN_MARK" ]' "5: in Docker, run.sh stops (code 75) instead of switching inside the container (got $code)"
check '[ "$(cat "$PP_LAUNCHER")" = "$updates/99.0.0/server/PiratesPlunder-server.x86_64" ]' "5: and leaves the new version's path for the restart"
check 'grep -q "for Docker to restart the container into version 99.0.0" "$work/five.txt"' "5: the log says the container will restart"
kill $github 2>/dev/null; wait $github 2>/dev/null

# 6. The restart: run.sh starts the new version straight away.
PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 30 "$work/old/run.sh" $settings > "$work/six.txt" 2>&1
check '[ -f "$RAN_MARK" ] && grep -q -- "--port=$GAME" "$RAN_MARK" && [ -f "$updates/99.0.0/STARTED" ]' "6: after the restart, run.sh starts the new version, with the same settings"
check '! grep -q "Free: waiting" "$work/six.txt"' "6: without starting the old version first"

# 7. A new version that doesn't get going: the next start is the image's own.
rm -f "$RAN_MARK" "$updates/99.0.0/STARTED"
FAIL_START=1 PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 30 "$work/old/run.sh" $settings > "$work/seven.txt" 2>&1
check '[ -f "$RAN_MARK" ] && [ ! -s "$PP_LAUNCHER" ]' "7: a new version that didn't start is forgotten"
rm -f "$RAN_MARK"
PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 15 "$work/old/run.sh" $settings > "$work/seven-b.txt" 2>&1
leftovers
check '[ ! -f "$RAN_MARK" ] && grep -q "Free: waiting" "$work/seven-b.txt"' "7: the next start runs the image's own version, which doesn't pick it again"
unset PP_RESTART_TO_UPDATE PP_LAUNCHER

echo "== what the server said, the first time:"
grep -E "Auto-update|Starting the new" "$work/one.txt" | sed 's/^/   /'
if [ $fail -eq 0 ]; then
	rm -rf "$work"
	echo "SERVER_UPDATE_TEST: ALL PASS"
else
	echo "(logs in $work)"
	echo "SERVER_UPDATE_TEST: FAIL"
	exit 1
fi
