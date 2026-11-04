#!/bin/bash
# The saved-online-match network test: a host and two friends, three
# processes per stage, each with its own --player-id= (they share one
# computer, and so one user:// folder). See tools/net_resume_driver.gd.
#   play     a match is played, coached, saved, and everyone quits
#   match    the host continues it; the friends get their own crews back
#            without choosing, then the host saves partway through game 2
#   midgame  the host continues that; everyone is rebuilt as they were
# Run from anywhere:  godot/tools/resume_test.sh   (GODOT=/path/to/godot to pick one)
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
logs=$(mktemp -d)

# A hard limit per player, in case a script fails to load (macOS has no
# `timeout` unless coreutils is installed; there it runs without one).
limit=(); command -v timeout >/dev/null && limit=(timeout 300)
player() { # role id stage
	${limit[@]+"${limit[@]}"} "$GODOT" --headless --path . res://tools/NetTest.tscn -- --role="$1" --player-id="$2" --stage="$3" \
		> "$logs/$3-$1.txt" 2>&1
}

fail=0
for stage in play match midgame; do
	echo "--- stage: $stage ---"
	player resume-host host-1 "$stage" & host=$!
	sleep 1 # let the host open its port
	player resume-guest-a guest-a "$stage" & a=$!
	player resume-guest-b guest-b "$stage" & b=$!
	for pid in $host $a $b; do
		wait "$pid" || fail=1
	done
	for who in resume-host resume-guest-a resume-guest-b; do
		grep -E '\[(PASS|FAIL)\]|NET_RESULT|SCRIPT ERROR|Parse Error|ERROR:' "$logs/$stage-$who.txt" \
			| grep -v 'resources still in use'
	done
	[ $fail -eq 0 ] || break # the next stage needs this one's save
done
echo "(full logs in $logs)"
if [ $fail -eq 0 ]; then echo "RESUME_TEST: ALL PASS"; else echo "RESUME_TEST: FAIL"; fi
exit $fail
