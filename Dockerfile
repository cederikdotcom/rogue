# Rogue as a Hydra scale — the game plus its web bridge in one OCI image.
#
# Two binaries: the classic C rogue (needs ncurses at runtime) and the Go
# rogue-web server that bridges each browser to a rogue process over a pty.
# Serves plain HTTP on :8080; TLS is terminated upstream by hydrascalerouter,
# so this never binds 443 or manages certificates.
#
# Deliberately NO VOLUME: Incus's OCI runtime cannot satisfy an anonymous
# volume and the container fails to start with `Failed to mount "none"`.
# Game state (save files, score and lock files) lives under /data, which is
# attached as an Incus disk device at launch — never baked into the image.

# --- build stage: compile both binaries ---
FROM golang:1.25-bookworm AS build
WORKDIR /src

# rogue is C and needs ncurses headers and make to build.
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc make libncurses-dev \
    && rm -rf /var/lib/apt/lists/*

COPY . .

# The C game. NO_SHELL_ESCAPE disables the `!` shell-escape command, which
# would otherwise be a shell for every visitor.
RUN ./configure -q && make CFLAGS="-O2 -DNO_SHELL_ESCAPE"

# The Go web bridge (its own module under web/).
RUN cd web && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /rogue-web .

# --- runtime stage ---
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      libncursesw6 libtinfo6 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /src/rogue      /app/rogue
COPY --from=build /rogue-web      /usr/local/bin/rogue-web
COPY --from=build /src/web/static /app/web/static

# rogue-web has no self-updater, but declare the convention anyway.
ENV HYDRA_AUTO_UPDATE=off
EXPOSE 8080

# Game state on /data (attach an Incus disk device there at launch).
CMD ["rogue-web", "-addr", ":8080", \
     "-rogue", "/app/rogue", \
     "-static", "/app/web/static", \
     "-saves", "/data/saves", \
     "-workdir", "/data"]
