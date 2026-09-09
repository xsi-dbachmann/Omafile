# Architecture decisions

| ADR | Decision |
|---|---|
| [0001](0001-smb-through-mount-cifs.md) | Reach SMB through `mount.cifs`, not a userspace SMB library |
| [0002](0002-atomic-rename-as-the-commit-point.md) | Temp name, `fsync`, atomic rename is the commit point |
| [0003](0003-verification-tiers.md) | Verification tiers; only the checksum is optional |
| [0004](0004-the-backend-seam.md) | Backend primitives are a precondition; the engine owns the commit |
| [0005](0005-daemon-as-a-systemd-user-unit.md) | The daemon is a socket-activated `systemd --user` unit |
| [0006](0006-daemon-distribution.md) | The daemon ships as an AUR package; the plugin instructs |
| [0007](0007-adding-a-share-via-polkit.md) | A polkit helper adds shares and owns the credentials file |
| [0008](0008-verification-policy.md) | Verification policy: granularity, recording, and failure |
| [0009](0009-completion-states-and-undo.md) | Completion is stated, not ticked; undo is a session stack |
| [0010](0010-no-share-server.md) | Omafile does not run a share server; use Taildrive |
| [0011](0011-ipc-protocol.md) | Newline-delimited JSON, coalesced daemon-side at 10 Hz |
| [0012](0012-context-menu-and-drag.md) | A drag always copies; one path to every destructive action |
| [0013](0013-conflict-resolution.md) | Ask before overwriting; report what was replaced |
| [0014](0014-the-pixel-budget.md) | A notice row, draggable boundaries, a header that counts both |

ADR 0004 extends 0003's tier table with a fourth tier. ADR 0008 completes 0003,
and carries an implementation note about a decision that predated anything able
to express it. ADR 0003 supersedes the project's original always-on verification
decision, and carries a correction: the tiers describe copies, so a
same-filesystem move reports `Moved` rather than a tier.

ADR 0014 carries a 2026-09-09 amendment (issue 19): a notice lives as long as
its sentence, and a size is decimal so the column and the daemon's exact byte
count describe one file without disagreeing.

⚠️ **ADR 0007 requires a security review before shipping** — it is the product's
one privileged component and it writes `/etc/fstab`.
