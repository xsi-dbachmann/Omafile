# ADR 0001 — Reach SMB through `mount.cifs`, not a userspace SMB library

**Status**: Accepted (2026-09-07)

## Context

Omafile must read and write SMB shares while guaranteeing that a partial file
never occupies a final path. That requires three primitives: writing at an
arbitrary byte offset (resume), forcing data to durable storage, and replacing
a file in one indivisible step.

Four approaches were surveyed against those primitives.

## Decision

Reach SMB through a **kernel `mount.cifs` mount**, so a share is an ordinary
path and the local-filesystem backend serves it.

## Why the alternatives were rejected

**libsmbclient (and the `pavao` Rust bindings, and gvfs)** — rejected on data
safety, not preference. `smbc_rename` cannot express replace-if-exists, so
Samba's `SMBC_rename_ctx` handles a collision by **unlinking the destination
and retrying**. That is a destroy-then-recreate window on every overwrite.
Worse, libsmbclient exports **no flush primitive at all** — verified against the
installed header, the authoritative exported-symbol list, and the source tree —
and `pavao`'s `flush()` returns `Ok(())` without doing anything, while its
`Drop` discards the `close` result. A library that reports success without
durability is the founding bug wearing a different costume.

**Pure-Rust SMB crates** — the best-shaped API surveyed carries an open,
demonstrated signature-stripping MITM vulnerability; the alternative has no
rename helper and a `Seek` that silently does not seek. Neither is acceptable
for a tool selling integrity.

**`smbclient` CLI** — `reget`/`reput` do resume, but are undocumented upstream,
and `process_command_string` overwrites its return code per command, so a
multi-command invocation reports success after a failure.

## Consequences

- **A one-time root step per share.** `mount.cifs` is setuid, but `/etc/fstab`
  is the gate, and cifs is not `FS_USERNS_MOUNT` — user namespaces return
  `EPERM`. There is no way around this. How it is presented is open.
- **`fsync(2)` is the durability signal, and it works.** Measured: write plus
  `close()` produces zero SMB2 FLUSH operations; write plus `fsync()` produces
  one. **Never mount `nostrictsync`** — it suppresses the flush.
- **Never write in place.** Kernel 7.1.9 carries an unfixed, `Cc: stable`
  silent-truncation bug triggered by concurrent writes plus `O_TRUNC`. The
  commit discipline in ADR 0002 sidesteps it as a side effect; a future
  "optimisation" that overwrites in place would walk into it.
- **Server version is a correctness input.** Samba before 4.7 silently ignored
  SMB2 FLUSH (`strict sync` defaulted to `no`).
- **Rename atomicity is not a protocol guarantee.** MS-SMB2, MS-FSCC and MS-FSA
  make no atomicity statement. It holds against Samba, traced to
  `renameat2(…, 0)`. **Windows/NTFS servers are unverified territory.**
- Verification costs a read-back; there is no server-side hashing in SMB.
