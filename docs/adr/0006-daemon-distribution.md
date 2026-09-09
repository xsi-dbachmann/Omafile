# ADR 0006 — How each half reaches a user; the plugin instructs, never installs

**Superseded in part, 2026-09-09.** The AUR is no longer the channel — see
"Superseding the AUR" below. The daemon still ships as an Arch package built
from `packaging/PKGBUILD`; what changed is who builds it and where it is
hosted.

**Status**: Accepted (2026-09-07)

## Context

`omarchy plugin add` clones a git repo, validates it, and moves it into place. It
**runs no build step and no install step**, and the manifest schema is closed —
across all 40 manifests on this machine there is no `dependencies` key. So the
plugin cannot declare that it needs `omafiled`, and cannot install it.

ADR 0005 raises the bar further: a `systemd --user` unit and its socket must be
installed, not merely dropped on disk.

## Decision

**An AUR package ships the binary, the systemd user unit, and the socket.** It is
the only surveyed route that installs a unit properly.

**The plugin detects, degrades, and names the command. It never installs.**
`yay -S` needs sudo and a QML `Process` has no tty.

**A missing or mismatched daemon degrades to browse-only**, with a banner giving
the exact install command.

**A version handshake is required.** The daemon reports its version on connect;
the plugin refuses to queue Jobs against an incompatible one.

**What "incompatible" means, decided 2026-09-09** (issue 29): the wire
protocol's own number, `PROTOCOL_VERSION`, and nothing else. The two package
versions — `manifest.json`'s and `daemon/Cargo.toml`'s — move independently, are
shown to the user for diagnosis, and gate nothing.

Rejected: a **minimum daemon version** alongside the protocol gate. Its only
failure mode is refusing a daemon that works — a wire-neutral bug fix either
does not raise the floor, making it decorative, or does, putting a working
install into browse-only. Two gates that must be kept in agreement is this
project's signature defect in miniature. Rejected too: **lockstep versions**,
which contradict the two cadences this ADR is about; half-updated is the normal
case here, so identical version strings would be false the moment they were
printed, and the transfer panel prints one.

The bump rule lives beside the constant in `daemon/src/protocol.rs`, with the
test that makes it a rule rather than a preference: an additive request does not
bump the protocol only if an old daemon's refusal of it never reaches the user
as an error. That was checked for `Release` rather than assumed — an unknown
`op` is answered with `Reply { id: 0, … }`, the plugin's request ids start at 1,
so the reply matches nothing pending and is dropped silently. Bumping is not the
cautious choice: the gate is an equality test, so a bump puts every user of the
older half into browse-only.

**Where the package is built from**: `packaging/PKGBUILD` in this repository,
`pkgname=omafiled`, sourced from the tag `daemon-v$pkgver`, where `pkgver` is
`daemon/Cargo.toml`'s version — the same string the daemon reports on connect.
Keeping it in the repository rather than only in a package archive is this
ADR's own argument against a committed binary: everything installed on a user's
machine should be visible as text in the diff they are asked to approve, and the
unit files and the daemon they start should not drift apart in separate
repositories. That reasoning outlived the AUR itself — see below.

Rejected: a `-git` VCS package (every user builds an untagged commit, and "which
daemon am I running" answers with a hash — an unhelpful answer for the half of
the product that implements the commit protocol).

## The release order, and why the plugin needs a branch (2026-09-09)

`omarchy-plugin-update` runs `git fetch --quiet origin HEAD` — it tracks the
repository's **default branch**. So the plugin has no release channel separate
from a branch: whatever the default branch points at *is* what users get on
their next update, the moment it lands.

That turns the version handshake's equality test into a sequencing constraint.
A plugin commit that bumps `PROTOCOL_VERSION` puts **every** user into
browse-only until they install a daemon that speaks it — and that daemon reaches
them through the AUR, which needs a human, a tag, and a build. The plugin half
is the fast one and the daemon half is the slow one, which is exactly the wrong
way round.

**So the release channel is a separate branch — and, since 2026-09-09, a
separate *repository*.** Development happens on `main` in a private repository;
`release` carries a tree built by `scripts/publish.sh`, one commit per release,
rooted at a commit with no parent in the private history, and is pushed to the
public repository's default branch. A protocol bump can sit on `main` until its
daemon is published, and both halves reach users in one push.

The earlier form of this decision — `release` as a fast-forwarded branch of the
same repository — was replaced when the planning record had to stay private.
GitHub visibility is per repository, so a private branch does not exist; the
only way `.scratch/` stays private is for it never to enter the public
repository at all. `release` is therefore built rather than fast-forwarded, and
"what did users actually get" is still answerable, now by reading `release`'s
own history: one commit per release, each holding exactly the published tree.

**The order, when the protocol changes:**

1. Bump `PROTOCOL_VERSION`, add a `PROTOCOL_HISTORY` row naming the daemon
   version that carries it, bump `daemon/Cargo.toml`, set the plugin's
   `expectedProtocol`. All on `main`. `scripts/lint-qml.sh` refuses if these
   four disagree, so this cannot be done in one place.
2. Tag `daemon-vX.Y.Z` **on the public repository**, so `PKGBUILD`'s source URL
   resolves. **Before** step 3.
3. Run `scripts/publish.sh` and push `release` to the public repository.

Doing 3 before 2 is the failure. Nothing can mechanically prove the AUR
published, so the check does the next best thing: it makes the bump impossible
to perform without reading the rule, by requiring the `PROTOCOL_HISTORY` row
where the rule is written down.

`scripts/check-release.sh` covers what *is* mechanically checkable at tag time —
that `Cargo.toml`, `PKGBUILD` and `Cargo.lock` agree, that the tree is clean,
that `omarchy plugin validate` accepts HEAD, and that any tag which exists is not
stale.

## The AUR turned out to be optional (2026-09-09)

On the day v1 was cut, the AUR closed new account registration — a response to
automated signups, with no stated date and no manual queue. `omafiled` could not
be submitted.

**It cost a command, not a release**, and the reason is the decision above:
the `PKGBUILD` lives in this repository rather than only in the AUR. So
`cd packaging && makepkg -si` builds and installs the same binary, the same
socket and the same service, with no AUR account involved by anyone. What the
AUR was actually providing was **discovery and updates** — not the ability to
install, and not the ability to install a unit properly, which was this ADR's
original reason for choosing it.

That is worth recording as a consequence rather than a lucky escape: keeping the
packaging in the repository was argued for on *reviewability* grounds — that
everything landing on a user's machine should be visible as text in the diff
they approve. It turned out to also be what kept a third party's incident from
blocking a release.

So the browse-only banner names `makepkg -si` and not `yay -S omafiled`, because
naming a package that cannot exist is telling the user to run a command that
fails — the same defect this project already fixed once, when the banner told
people to install software they already had. One line changes back when
registration reopens, and the AUR becomes the update channel it was chosen to be.

## The plugin has a catalog, and it validates (2026-09-09)

`plugins.omarchy.org` lists plugins through a submission form (repository link,
category, tags) with automated validation of the current commit before a
maintainer approves the listing. It requires a public repository with
`manifest.json`, a README and a licence — all of which exist.

`omarchy plugin validate <folder>` is that validation, runnable locally, and it
exits non-zero on failure. `scripts/check-release.sh` now runs it against
**`git archive HEAD`** rather than the working tree, because the catalog
validates a commit and the working tree carries gitignored build artifacts the
validator rejects — the ghost harness's generated cursor theme contains symlinks,
and Omarchy refuses symlinks inside a plugin folder. Validating the working tree
would fail for a reason no user could ever encounter.

## Superseding the AUR: the package is built by the user (2026-09-09)

The AUR closed new account registration on the day v1 was cut, and the plugin
catalog at `plugins.omarchy.org` turned out to distribute **the plugin only** —
it is a listing, and `omarchy plugin add` still runs no build step. So the AUR
is dropped as the channel and `packaging/PKGBUILD` stays as the artefact:
`cd packaging && makepkg -si` builds and installs the binary, the socket and the
service, needing no account anywhere.

`packaging/.SRCINFO` is deleted with it — an AUR-repository requirement that
`makepkg` never reads. Reinstating the AUR later is one command
(`makepkg --printsrcinfo > .SRCINFO`) plus an account, so this is deferral, not
demolition.

**What is lost is updates, and it should be said plainly.** The plugin
auto-updates through `omarchy plugin update`; the daemon now does not update at
all. Drift is therefore guaranteed over time rather than merely possible, and
the only thing standing between a drifted pair and a silent protocol mismatch is
`PROTOCOL_VERSION` and the release order above. That makes the handshake more
load-bearing than it was when this ADR was written, not less.

## Why the binary is still not committed to the plugin repository

Re-examined 2026-09-09 against the installed Omarchy rather than from memory,
because the question is reasonable: if the catalog ships the plugin, why not
ship the daemon in it?

**Mechanically it would work.** `omarchy-plugin-validate` checks entry points
and symlinks and inspects no file types; nothing rejects an ELF. A plugin could
go further and write `~/.config/systemd/user/omafiled.{socket,service}` itself —
that path is user-writable and, unlike the plugins directory, writing there
triggers no teardown — making the whole thing self-installing with no user
command at all.

It is still refused, for one reason that has not weakened:
`omarchy-plugin-update` runs `git diff HEAD FETCH_HEAD` and then asks the user
to confirm, **on every update**. A committed binary renders as "Binary files
differ", so the one mechanism by which a user inspects what they are about to
run would be hollowed out — by the plugin whose entire pitch is proving what it
did. A file manager that asks to be trusted cannot pay for its own convenience
with the user's ability to review it.

Two lesser costs stand as well: one architecture per repository, and a
multi-megabyte blob entering git history on every release, permanently.

`makepkg -si` costs the user one command and keeps every byte they install
reviewable as text.

## The two version numbers, and what v1 means (2026-09-09)

The plugin is `1.0.0`; the daemon is `0.1.0`. "v1" is a claim about the product,
and the product is the plugin — it is what a user installs, what the manifest
names, and what `omarchy plugin update` tracks. The daemon is a component with
its own cadence, and putting it at 1.0.0 on the same day would assert a stability
promise about a wire protocol that is two days old.

They are free to diverge precisely because neither number gates anything:
`PROTOCOL_VERSION` does.

## Why not a committed binary

Mechanically it works — nothing inspects file types, and another installed plugin
already ships one. It was rejected for a specific reason: **`omarchy plugin
update` shows the user a `git diff` and asks them to approve it**, and a binary
renders as "Binary files differ", hollowing out that review on *every* update.
For a plugin whose entire pitch is trustworthiness, quietly degrading the
mechanism by which users inspect what they are installing is the wrong trade. It
also pins one architecture per repo and couples to glibc.

Build-on-first-run was rejected for putting a Rust toolchain and a multi-minute
compile in a file browser's startup path.

## Consequences

- **Two release artefacts on two cadences.** The plugin ships through git, the
  daemon through the AUR, so they drift independently — a user updates one
  without the other.
- **The version handshake is therefore not politeness.** The two halves implement
  one commit protocol, and a silent mismatch in that protocol is precisely the
  class of failure Omafile exists to make impossible.
- **First run means telling the user to run a command.** This is the established
  pattern for privileged installs inside Omarchy (Tailscale, Dropbox): detect,
  say "Not installed", offer no install button. **Two commands, in fact**: an
  Arch package may not enable its own units, so installing the package and
  enabling `omafiled.socket` are separate steps and either one alone leaves the
  window browse-only with the same message. The banner names both.
- Browse-only was chosen over refusing to open (harsh, makes a partial product
  useless) and over failing at transfer time (surfaces the problem after files
  are already chosen).
