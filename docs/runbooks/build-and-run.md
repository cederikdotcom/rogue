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
