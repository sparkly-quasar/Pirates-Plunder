# Pirates Plunder server, from the package tools/package.sh builds. This file
# is copied into that package (godot/build/server/), so build it from there:
#   docker build -t pirates-plunder-server .
#   docker run -d --name pirates --restart unless-stopped -p 24680-24681:24680-24681/udp -p 24680-24682:24680-24682/tcp pirates-plunder-server
# or use the docker-compose.yml beside it. Settings are environment variables
# (-e PP_CREWS=4) or arguments after the image name (--crews=4); see SERVER.md.
#
# The package holds the server (one file, exported from Godot as a dedicated
# server: no graphics, no sounds) and downloads/<version>/, the Mac and
# Windows versions of the same build, which it hands to any older copy that
# connects so everyone ends up on the server's version, and web/, the web
# version it hands to browsers (phones) on TCP 24682.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 pirate
WORKDIR /srv/pirates
COPY --chown=pirate:pirate PiratesPlunder-server.x86_64 run.sh ./
COPY --chown=pirate:pirate downloads/ ./downloads/
COPY --chown=pirate:pirate web/ ./web/
# The saves folder belongs to pirate, and Docker copies that owner into a
# new, empty volume mounted there (docker-compose.yml's "saves"). Without it
# the volume belongs to root and the server can't write a single save.
RUN chmod 0755 PiratesPlunder-server.x86_64 run.sh \
 && mkdir saves \
 && chown pirate:pirate saves
USER pirate
EXPOSE 24680/udp 24681/udp 24680/tcp 24681/tcp 24682/tcp
# run.sh starts the server and keeps it on the newest version: auto-update
# downloads new versions into the saves volume (saves/updates) and run.sh
# switches to them. tini -g passes a stop on to the server as well.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/srv/pirates/run.sh"]
