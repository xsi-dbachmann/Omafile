# Omafile

A file browser for Omarchy that can prove what it did.

It exists because copying files from an SMB share through Nautilus silently
produced partial files that reported success — in the founding incident, one
886 MB video arrived as 802 KB, 0.09% of it, and nothing said so. The cause was
traced to gvfs treating a zero-length SMB read as a clean end of file
(`gvfsbackendsmb.c do_read()` treats only `-1` as an error), while
`copy_stream_with_progress()` already held the source size for the progress bar
and never compared it.

There is no upstream bug to wait for: from GIO's perspective nothing
malfunctioned.

## How Omafile answers that

Three tiers, two of them free and unconditional:

| Tier | Status | What it catches |
|---|---|---|
| **Structural** — temp name, `fsync`, atomic rename | always on | A partial file occupying the final name |
| **Size** — bytes written vs. source size | always on | Truncation, short reads, a laundered EOF |
| **Checksum** — read-back hashing (`--checksum`) | opt-in, off by default | Silent corruption, bit rot, a lying server |

The size check alone would have caught **41 of 41** damaged files in the
founding incident, and it costs nothing. Checksum verification was measured at
roughly 2.5–2.7× wall-clock, which is why it is opt-in rather than default.

## Status

**End to end.** Pick files in one pane, press Copy, and they arrive in the other
pane verified — every transfer committed by atomic rename or not at all.

Dual-pane, because the destination should be a fact of the layout rather than
something held in the head: the action bar says "Copy → right" instead of
putting intent on a clipboard.

    Tab             switch which pane is the source
    Up/Down         move the cursor
    Space           pick or unpick a file
    Enter           open a directory
    Backspace       go up
    Ctrl+A          pick every file here
    Ctrl+C / Ctrl+M copy or move to the other pane
    Ctrl+K          toggle checksum for the next transfer
    Ctrl+B          show or hide the places sidebar
    Delete          delete the selection (trash where the filesystem allows)
    Ctrl+Z          take back the last move or delete
    Escape          close

Deletion tells the truth about itself. Where the filesystem can host a trash
the file is recoverable and says so; where it cannot — SMB shares frequently
cannot — it is permanent and the message says *that*, rather than quietly
copying gigabytes somewhere to look reversible.

Right-click for Copy, Move, Open, Rename, Delete and Properties. Dragging
between panes always copies — never moves, because a drag is easy to do by
accident.

Adding an SMB share is not done from inside Omafile. Shares that are already
mounted appear in the sidebar and work today; adding one is a one-time step at
the terminal, described below. ADR 0007 designs a polkit helper that would do it
in-app, and its implementation is deliberately deferred past v1: it would be the
product's only privileged component, it writes `/etc/fstab`, and it has not had
a security review.

## Adding an SMB share by hand

There is no way around root here, and it is not Omafile's doing. `mount.cifs` is
setuid, but `/etc/fstab` is the gate, and cifs is not `FS_USERNS_MOUNT`, so the
user-namespace route returns `EPERM` — verified, not assumed (ADR 0001).

Once per share, as root:

```bash
# 1. credentials, readable only by root
install -Dm0600 /dev/null /etc/samba/creds-myshare
cat > /etc/samba/creds-myshare <<'EOF'
username=your-user
password=your-password
EOF

# 2. a mount point
mkdir -p /mnt/myshare

# 3. one fstab line — noauto,user lets you mount it later without sudo
printf '%s\n' \
  '//nas.local/share /mnt/myshare cifs noauto,user,credentials=/etc/samba/creds-myshare,uid=1000,gid=1000 0 0' \
  >> /etc/fstab
```

Then, as yourself, whenever you want it: `mount /mnt/myshare`. It shows up in
Omafile's sidebar under Network, and transfers to it get the same commit
discipline as anything local — the size check in particular, which is the one
that would have caught all 41 files in the founding incident.

Use your own uid and gid (`id -u`, `id -g`). `noauto` keeps boot from hanging on
an absent server; `user` is what lets you mount it without root afterwards.

```bash
cd daemon && cargo build --release
./target/release/omafiled copy <source> <destination> [--checksum]
./target/release/omafiled move <source> <destination>
./target/release/omafiled unfinished
```

The daemon also serves the plugin over a Unix socket:

```bash
omafiled serve                      # newline-delimited JSON on $XDG_RUNTIME_DIR/omafiled.sock
```

Run that way it binds the path itself, and **refuses** rather than take a
running daemon's clients — a socket that answers means somebody is already
serving it; only one that refuses the connection is stale enough to clear.

## Installing it

Two halves on two cadences (ADR 0006). The plugin arrives through Omarchy:

```bash
omarchy plugin add https://github.com/xsi-dbachmann/Omafile
```

The engine is an Arch package built from this repository. Enabling its socket
is a second step, because a package may not enable its own units — so it is one
line rather than two, joined:

```bash
cd ~/.config/omarchy/plugins/io.github.xsi-dbachmann.omafile/packaging \
  && makepkg -si \
  && systemctl --user enable --now omafiled.socket
```

You do not have to type that. Until the engine is there Omafile opens and
browses normally, and its transfer bar says which of the two halves is missing
and offers a **copy command** button that puts exactly the right line on your
clipboard. It copies; it never runs anything (ADR 0006).

> **Why build it rather than install a package?** The Omarchy plugin catalog
> distributes the plugin, not the engine: `omarchy plugin add` runs no build
> step and a manifest cannot declare a dependency, so a compiled binary has to
> arrive some other way. The `PKGBUILD` here is that way, and it needs no
> account anywhere — `makepkg` builds and installs the binary, the socket and
> the service, and every byte of what it installs is reviewable as text in this
> repository. See ADR 0006, including why the binary is deliberately not
> committed to the plugin repo.

Nothing is running once that finishes, and that is correct. The socket is what
listens; the daemon starts on the first connection and stays for the session.
Until both halves are in place Omafile opens and browses normally and names, in
the transfer panel, exactly which half is missing — it never installs anything
itself.

`packaging/` holds the `PKGBUILD` and the two units, so what lands on a machine
is reviewable as text in the same diff as the code.

### About this repository

`omarchy plugin update` fetches the default branch, so what it points at is what
you get on your next update. **Every commit here is one release** — the tree
exactly as published, nothing else.

Development happens in a separate private repository, which is where the
planning record, the test harness and the session-by-session working notes live.
None of that is needed to read, build or run what is here; the reasoning that
matters is in `docs/adr/`, all fourteen decisions with the measurements behind
them.

`cargo test` covers the commit discipline, including the tests that matter most:
that a checksum mismatch is *detected*, that a failed verification leaves no
file at the destination and no temp file behind, and that the journal records
nothing about finished work.

The decisions behind all of this are in `docs/adr/` — fourteen of them, each
with the measurement that settled it. The planning record they came from is kept
in a private repository; nothing in it is needed to read, build or run Omafile.

## Development install

```bash
./scripts/link-plugin.sh
omarchy-shell shell summon io.github.xsi-dbachmann.omafile '{}'
```

The script symlinks this repo into `~/.config/omarchy/plugins/io.github.xsi-dbachmann.omafile`.
Symlinking the plugin *directory itself* is the sanctioned workflow — Omarchy
refuses symlinks *inside* a plugin folder, but walks the plugins directory with
`find -L`.

## Removing it

Both halves, in this order. Removing only the plugin leaves a daemon installed
and a socket unit still listening.

```bash
# 1. the plugin
omarchy plugin disable io.github.xsi-dbachmann.omafile
omarchy plugin remove io.github.xsi-dbachmann.omafile

# 2. the engine — stop it listening before removing the binary
systemctl --user disable --now omafiled.socket
sudo pacman -R omafiled
```

That leaves two files behind on purpose, because neither is Omafile's to
discard silently:

```bash
rm -f  ~/.config/omafile/settings.json    # the checksum default, nothing else
rm -rf ~/.local/state/omafile             # the journal
```

**Check the journal before deleting it.** It records transfers that never
finished, and it is what lets an interrupted one resume — `omafiled unfinished`
prints anything still in it. On a clean shutdown it is empty.

## A note for anyone editing the window

The window title is `omafile`, and that string is part of the public contract.
Every Quickshell toplevel shares the Hyprland class `org.quickshell`, so
Omarchy's window rules discriminate by title — users' rules will match on it.
Do not change it.
