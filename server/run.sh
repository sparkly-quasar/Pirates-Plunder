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
#
# In Docker (the image sets PP_RESTART_TO_UPDATE=1) it doesn't switch inside
# the running container: it stops too, Docker starts the container again
# (restart: unless-stopped), and this starts the new version. Docker Desktop
# can lose a port's forwarding when the server is swapped inside a running
# container (the server lists' UDP port stopped answering until the
# container was restarted), and a container restart sets every port up afresh.
here=$(cd "$(dirname "$0")" && pwd)
server="$here/PiratesPlunder-server.x86_64"

if [ "${PP_RESTART_TO_UPDATE:-0}" = 1 ]; then
	# The container's own files outlive a restart, and go when it's recreated
	# from a new image (which then starts its own version first, as it should).
	PP_LAUNCHER=${PP_LAUNCHER:-/tmp/pirates-next}
	export PP_LAUNCHER
	next=$(cat "$PP_LAUNCHER" 2>/dev/null)
	if [ -n "$next" ] && [ -x "$next" ]; then
		echo "Starting the version auto-update switched to: $next"
		server=$next
	else
		next=""
	fi
	"$server" --headless -- "$@"
	code=$?
	if [ "$code" -eq 75 ]; then
		echo "Stopping so Docker starts the container again, on the new version."
		exit 75
	fi
	# A new version that never got going (it marks its folder STARTED when it
	# does): the next start uses the image's own version, which won't pick it again.
	if [ -n "$next" ] && [ ! -f "$(dirname "$(dirname "$next")")/STARTED" ]; then
		echo "That version didn't start; the next start uses the image's own version."
		: > "$PP_LAUNCHER"
	fi
	exit "$code"
fi

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
