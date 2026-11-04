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
# Run from anywhere:  godot/tools/server_update_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24673
GAME=24674
work=$(mktemp -d)
project=$(pwd)
fail=0
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
check '[ ! -f "$RAN_MARK" ] && grep -q "Free: waiting" "$work/three.txt"' "3: a version that never started isn't used again; the old one carries on"

# 4. Not through run.sh: it says so, and stays put.
python3 tools/fake_github.py $PORT "$work/site" v99.0.0 &
github=$!
sleep 1
rm -rf "$updates"
PP_TEST_RELEASES=http://127.0.0.1:$PORT timeout 15 "$work/old/PiratesPlunder-server.x86_64" --headless -- $settings > "$work/four.txt" 2>&1
check 'grep -q "Version 99.0.0 is out" "$work/four.txt" && [ ! -d "$updates/99.0.0" ]' "4: without run.sh it only says a newer version is out"
kill $github 2>/dev/null; wait $github 2>/dev/null

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
