#!/bin/bash
# Builds the release downloads into build/:
#   PiratesPlunder-macos.dmg    open it, drag the app onto Applications
#   PiratesPlunder-windows.exe  a single file; the game data is inside it
#   PiratesPlunder-server-linux.tar.gz
#                               the dedicated server, with the two downloads
#                               above inside so it can update older copies,
#                               and the web version it hands to browsers
#                               (also unpacked in build/server/; SERVER.md)
#   PiratesPlunder-mac.zip      the Mac app zipped, for copies that update
#                               themselves from the public releases
#   SHA256SUMS.txt              fingerprints of all four, for the release page
#                               (and for those updates to check against)
# Run from the godot/ folder, best on a Mac (hdiutil makes a compressed disk
# image). On Linux it makes the same files, but the disk image is a plain
# ISO 9660 one (genisoimage) that macOS opens like any other. Needs Godot's
# export templates, which include Linux for the server.
#
# Each download carries the other computer's version too, so a friend with a
# different version can get the right one straight from whoever they join
# (scripts/updater.gd). In order:
#   1. a plain Windows exe            -> dist/windows/ (goes inside the Mac app)
#   2. the Mac app, with that inside  -> the .dmg, and zipped into dist/mac/
#   3. the Windows exe, with the zipped Mac app inside
#   4. the server, with 2 and 3 beside it
# dist/ is build output, not committed. Every step checks what it made and
# stops with a reason if something is missing, so a release can't go out
# without its server.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "package.sh: $*" >&2; exit 1; }
# A failed export can still leave godot exiting 0, so check what it made.
need() { [ -s "$1" ] || fail "expected $1, but it wasn't built (see Godot's output above)"; }

# The version lives in one place, project.godot; every export takes it from there.
version=$(sed -n 's/^config\/version="\(.*\)"/\1/p' project.godot)
[ -n "$version" ] || fail "no config/version in project.godot"

# Check for the export templates now, not after the Mac and Windows exports:
# the server needs Godot's Linux template, which nothing else here uses.
# (SKIP_TEMPLATE_CHECK=1 skips this, if your templates live somewhere else.)
grep -q '^name="Linux Server"' export_presets.cfg || fail 'no "Linux Server" export preset in export_presets.cfg'
if [ "${SKIP_TEMPLATE_CHECK:-0}" != "1" ]; then
	engine=$(godot --version | head -1 | sed -E 's/^([0-9.]+\.[a-z]+[0-9]*).*/\1/')
	if [ "$(uname)" = Darwin ]; then
		templates="$HOME/Library/Application Support/Godot/export_templates/$engine"
	else
		templates="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$engine"
	fi
	for t in linux_release.x86_64 windows_release_x86_64.exe macos.zip web_nothreads_release.zip; do
		[ -f "$templates/$t" ] || fail "missing the export template $t for Godot $engine (looked in $templates). Install them in Godot: Editor > Manage Export Templates."
	done
fi

rm -rf build/stage build/server build/PiratesPlunder-macos.dmg build/PiratesPlunder-windows.exe \
	build/PiratesPlunder-server-linux.tar.gz build/PiratesPlunder-mac.zip build/SHA256SUMS.txt dist
mkdir -p build/stage/mac dist/windows dist/mac

echo "Exporting version $version..."
godot --headless --path . --export-release "Windows (inside the Mac app)" dist/windows/PiratesPlunder-windows.exe
need dist/windows/PiratesPlunder-windows.exe
godot --headless --path . --export-release "macOS" "build/stage/mac/Pirates Plunder.app"
[ -d "build/stage/mac/Pirates Plunder.app" ] || fail "the Mac app wasn't built (see Godot's output above)"
if command -v ditto > /dev/null; then
	ditto -c -k --keepParent "build/stage/mac/Pirates Plunder.app" dist/mac/PiratesPlunder-mac.zip
else
	# The same zip as ditto's: the app at the top, permissions and links kept
	# (the updater unpacks it with ditto on the Mac).
	(cd build/stage/mac && zip -q -r -y -X ../../../dist/mac/PiratesPlunder-mac.zip "Pirates Plunder.app")
fi
need dist/mac/PiratesPlunder-mac.zip
godot --headless --path . --export-release "Windows" build/PiratesPlunder-windows.exe
need build/PiratesPlunder-windows.exe

# The disk image: the app, and a shortcut to Applications to drag it onto.
ln -s /Applications build/stage/mac/Applications
if command -v hdiutil > /dev/null; then
	hdiutil create -quiet -volname "Pirates Plunder $version" -srcfolder build/stage/mac \
		-fs HFS+ -format UDZO build/PiratesPlunder-macos.dmg
else
	command -v genisoimage > /dev/null || fail "making the disk image needs hdiutil (a Mac) or genisoimage"
	# Rock Ridge keeps the app's permissions and the Applications shortcut.
	genisoimage -quiet -V "Pirates Plunder $version" -R -J -joliet-long -D -no-pad \
		-o build/PiratesPlunder-macos.dmg build/stage/mac
fi
need build/PiratesPlunder-macos.dmg
rm -rf build/stage

# 4. The server: one Linux file (a dedicated-server export, so no graphics or
# sounds), and beside it this version's Mac and Windows downloads, which it
# hands to any older copy that connects. Plus ways to run it.
echo "Exporting the server..."
mkdir -p "build/server/downloads/$version"
godot --headless --path . --export-release "Linux Server" build/server/PiratesPlunder-server.x86_64
need build/server/PiratesPlunder-server.x86_64
file build/server/PiratesPlunder-server.x86_64 | grep -q "ELF 64-bit" \
	|| fail "the server isn't a 64-bit Linux program: $(file -b build/server/PiratesPlunder-server.x86_64)"
chmod 0755 build/server/PiratesPlunder-server.x86_64
cp dist/mac/PiratesPlunder-mac.zip build/PiratesPlunder-windows.exe "build/server/downloads/$version/"

# 5. The web version, which the server hands to browsers (phones). The big
# files also go gzipped, which the server sends to browsers that take it.
echo "Exporting the web version..."
mkdir -p build/server/web
godot --headless --path . --export-release "Web" build/server/web/index.html
for f in index.html index.js index.wasm index.pck; do need "build/server/web/$f"; done
for f in index.wasm index.pck index.js; do gzip -9 -k -f "build/server/web/$f"; done
# What a phone shows when the page is saved to its home screen.
web_icons="apple-touch-icon.png icon-192.png icon-512.png icon-maskable-512.png manifest.webmanifest"
for f in $web_icons; do need "web_shell/$f"; cp "web_shell/$f" build/server/web/; done
cp ../server/Dockerfile ../server/docker-compose.yml ../server/pirates-plunder.service ../server/Caddyfile ../server/run.sh SERVER.md build/server/
chmod 0755 build/server/run.sh
echo "$version" > build/server/VERSION
COPYFILE_DISABLE=1 tar -C build -czf build/PiratesPlunder-server-linux.tar.gz server
need build/PiratesPlunder-server-linux.tar.gz

# The package must hold the server and both downloads, or it can't update anyone.
listing=$(tar -tzf build/PiratesPlunder-server-linux.tar.gz)
for f in server/PiratesPlunder-server.x86_64 "server/downloads/$version/PiratesPlunder-mac.zip" \
		"server/downloads/$version/PiratesPlunder-windows.exe" server/web/index.html server/web/index.wasm.gz \
		server/web/apple-touch-icon.png server/web/manifest.webmanifest \
		server/Dockerfile server/docker-compose.yml \
		server/pirates-plunder.service server/Caddyfile server/run.sh server/VERSION; do
	grep -qxF "$f" <<< "$listing" || fail "the server package is missing $f"
done

# Fingerprints for the release page, so anyone can check a download.
sha256() { if command -v shasum > /dev/null; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
# The Mac app zipped, for copies updating from the public releases (ReleaseUpdate).
cp dist/mac/PiratesPlunder-mac.zip build/PiratesPlunder-mac.zip
(cd build && sha256 PiratesPlunder-macos.dmg PiratesPlunder-windows.exe \
	PiratesPlunder-server-linux.tar.gz PiratesPlunder-mac.zip > SHA256SUMS.txt)

echo
echo "Version $version is ready. Attach these to the release:"
ls -lh build/PiratesPlunder-macos.dmg build/PiratesPlunder-windows.exe \
	build/PiratesPlunder-server-linux.tar.gz build/PiratesPlunder-mac.zip build/SHA256SUMS.txt
