# Runbook: build and run Rogue 5.4

## Requirements

- A C compiler (gcc, clang, or tcc)
- make (for the standard build)
- ncurses development headers (`libncurses-dev` on Debian/Ubuntu, `ncurses` via Homebrew on macOS)
- A terminal that is at least 70 columns wide and 22 lines tall

## Standard build

```sh
./configure
make
./rogue
```

## Build without root and without gcc (Linux)

Use this procedure when the machine has no compiler and you cannot install packages.

1. Download and unpack the toolchain packages to a local directory:

   ```sh
   mkdir -p ~/tcc-root && cd ~/tcc-root
   apt-get download tcc libc6-dev linux-libc-dev libcrypt-dev libncurses-dev
   for d in *.deb; do dpkg -x "$d" root; done
   ```

2. Compile all sources in one tcc call. Set `R` to the unpack directory:

   ```sh
   R=~/tcc-root/root
   G=$R/usr/lib/x86_64-linux-gnu
   cd /path/to/rogue
   $R/usr/bin/tcc -B$G/tcc \
     -I$R/usr/include -I$R/usr/include/x86_64-linux-gnu -I. \
     -DHAVE_CONFIG_H -nostdlib \
     $G/crt1.o $G/crti.o *.c \
     /lib/x86_64-linux-gnu/libncursesw.so.6 \
     /lib/x86_64-linux-gnu/libtinfo.so.6 \
     /lib/x86_64-linux-gnu/libc.so.6 \
     $G/crtn.o -o rogue
   ```

   This build does not use `configure`. It needs a `config.h` in the
   repository root. Write one by hand with the usual Linux `HAVE_*`
   defines, or run `./configure` on a machine that has gcc and copy
   the generated `config.h`.

## Run

```sh
./rogue
```

To run it in a detached tmux session for testing:

```sh
tmux new-session -d -s rogue-test -x 80 -y 24
tmux send-keys -t rogue-test './rogue' Enter
tmux capture-pane -t rogue-test -p
```

## Play in the browser (rogue-web)

The `web/` directory contains a Go server that runs Rogue in the
browser. It serves an xterm.js page and bridges each WebSocket
connection to one rogue process in a pty. Each visitor gets an
isolated game. The game process stops when the browser tab closes.

Build and run (needs Go 1.22 or later and a compiled `./rogue`):

```sh
cd web
go build -o rogue-web .
./rogue-web -addr :80 -rogue /path/to/rogue -static /path/to/rogue/web/static
```

Then open `http://<server-ip>/` in a browser.

To install it as a systemd service:

```ini
[Unit]
Description=Rogue in the browser
After=network.target

[Service]
WorkingDirectory=/root/rogue
ExecStart=/usr/local/bin/rogue-web -addr :80 -rogue /root/rogue/rogue -static /root/rogue/web/static
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Notes:

- The page loads xterm.js from the jsdelivr CDN, so the browser needs
  internet access.
- The server has no authentication. Anyone who can reach the port can
  play. Do not expose it on a machine that holds anything sensitive.
- The terminal is fixed at 80x24, which is what Rogue expects. The
  page scales the font so all 80 columns fit the screen width.
- On touch devices the page shows a D-pad with the real rogue keys
  (hjkl and yubn diagonals, hold to repeat) and action buttons. In
  landscape the D-pad sits left of the terminal and the actions sit
  right of it. The "keyboard" button opens a text input bar for
  free-text prompts, such as the name question. Add `?touch` to the URL to force the touch
  layout on a desktop browser for testing.
- `/help` serves the original guide "A Guide to the Dungeons of
  Doom" (generated from rogue.html.in into web/static/help.html).
- Saving works per browser. The page stores a random player id in
  localStorage and passes it to /ws. The server keeps one save file
  per id (default directory: saves/ next to the binary, override
  with -saves). S saves and exits; the next connection with the
  same id restores and deletes the save file. Clearing browser
  storage orphans the save.

### HTTPS with Caddy

For a public domain with TLS, run rogue-web on localhost and put
Caddy in front. Caddy gets and renews the Let's Encrypt certificate,
redirects HTTP to HTTPS, and proxies WebSockets without extra
configuration.

1. Point an A record at the server. With Hetzner DNS:

   ```sh
   hcloud zone rrset create --name <subdomain> --type A --record <server-ip> <zone>
   ```

2. Change the rogue-web service to `-addr 127.0.0.1:8080`.

3. Install Caddy (see caddyserver.com/docs/install) and set
   `/etc/caddy/Caddyfile` to:

   ```
   <domain> {
       reverse_proxy 127.0.0.1:8080
   }
   ```

4. `systemctl restart rogue-web caddy`

The live deployment is https://rogue.cederik.com on the rogue-test
Hetzner server (cederik context).

## Troubleshooting

- **Compile error: `field not found: _cury` or `incomplete definition of type 'WINDOW'`.**
  Modern ncurses makes the WINDOW struct opaque. Commit 3acae44 fixes
  this in `main.c` (`tstp()` now uses `wmove()`). Pull the latest
  master. See BUILD_ISSUES.md for the full analysis.
- **The game exits immediately after "digging the dungeon".**
  The terminal is too small. Rogue needs at least 70 columns and 22 lines.
- **Score file errors.**
  The game writes `rogue54.scr` and `rogue54.lck` in the directory set
  at configure time. Make sure that directory is writable.
