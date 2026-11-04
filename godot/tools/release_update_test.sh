#!/bin/bash
# Check for Updates from the public releases (ReleaseUpdate), against a
# stand-in for GitHub on this machine: the latest-release JSON, downloads
# behind a redirect (as GitHub's are), and SHA256SUMS.txt. A Mac and a
# Windows copy each download and check their file, also when the API's
# hourly limit is used up and only the releases page answers (a dry run, nothing
# installed); a file that doesn't match its fingerprint is thrown away.
# See tools/release_update_driver.gd.
# Run from anywhere:  godot/tools/release_update_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
PORT=24679
site=$(mktemp -d)

head -c 3000000 /dev/urandom > "$site/PiratesPlunder-mac.zip"
head -c 2000000 /dev/urandom > "$site/PiratesPlunder-windows.exe"
(cd "$site" && sha256sum PiratesPlunder-mac.zip PiratesPlunder-windows.exe > SHA256SUMS.txt)
python3 tools/fake_github.py $PORT "$site" v99.0.0 &
server=$!
sleep 1

here=http://127.0.0.1:$PORT
drive() { timeout 60 "$GODOT" --headless --path . -s res://tools/release_update_driver.gd -- \
	--page=$here/releases/latest --base=$here/releases/download/ "$@"; }
fail=0
drive --api=$here/api/latest --platform=macOS --expect=ok > "$site/mac.txt" 2>&1 || fail=1
drive --api=$here/api/latest --platform=Windows --expect=ok > "$site/win.txt" 2>&1 || fail=1
# The API's limit used up: the releases page's redirect says the version instead.
drive --api=$here/api/limited --platform=Windows --expect=ok > "$site/page.txt" 2>&1 || fail=1
# A Mac zip that isn't what the fingerprint says.
head -c 3000000 /dev/urandom > "$site/PiratesPlunder-mac.zip"
drive --api=$here/api/latest --platform=macOS --expect=bad > "$site/bad.txt" 2>&1 || fail=1

kill "$server" 2>/dev/null
for f in mac win page bad; do
	echo "== $f"; grep -E "checked:|installing:|RELEASE_RESULT" "$site/$f.txt"
done
[ -n "${KEEP:-}" ] || rm -rf "$site"
if [ $fail -eq 0 ]; then echo "RELEASE_UPDATE_TEST: PASS"; else echo "RELEASE_UPDATE_TEST: FAIL"; exit 1; fi
