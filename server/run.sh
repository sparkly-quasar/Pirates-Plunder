#!/bin/sh
# Starts the Pirates Plunder server and keeps it on the newest version.
# Settings go after it, as for the server itself (see SERVER.md):
#   ./run.sh --crews=4 --turn-seconds=180
#
# With auto-update on (the default), the server looks for a newer version in
# the game's public releases, downloads and checks it, and once nobody is
# playing, writes where it unpacked it to the file named in PP_LAUNCHER and
# stops with exit code 75. This then starts that version, with the same
# settings. Docker's image and pirates-plunder.service both start the server
# through this.
here=$(cd "$(dirname "$0")" && pwd)
server="$here/PiratesPlunder-server.x86_64"
PP_LAUNCHER=$(mktemp "${TMPDIR:-/tmp}/pirates-next.XXXXXX") || exit 1
export PP_LAUNCHER
trap 'rm -f "$PP_LAUNCHER"' EXIT
while :; do
	"$server" --headless -- "$@"
	code=$?
	next=$(cat "$PP_LAUNCHER" 2>/dev/null)
	if [ "$code" -eq 75 ] && [ -n "$next" ] && [ -x "$next" ]; then
		: > "$PP_LAUNCHER"
		echo "Starting the new version: $next"
		server=$next
		continue
	fi
	exit "$code"
done
