# Omafile — domain glossary

The vocabulary Omafile is designed and discussed in. Glossary only: no
implementation details, no decisions. Decisions live in `docs/adr/`; open
questions are kept in a private planning repository.

## Job

The central noun. A single user-initiated movement of files from one place to
another — queued, executed, verified, and committed as one unit. A Job is a
thing with a lifetime and a visible presence, not a transient progress bar.
Browsing exists to create Jobs.

A Job is **complete** only when every file in it has been committed. A Job that
was interrupted is **resumable**, not failed.

## Commit

The instant a transferred file becomes the real file at its final path. Until a
file is committed it does not exist under its final name — it exists under a
temporary name that nothing else is expected to read.

**Commit point**: the single operation that performs the commit. In Omafile it
is an atomic rename. Everything the product promises rests on this being one
indivisible step.

## Partial file

A file that contains less than its source but presents as ordinary and
complete. The founding failure. Distinct from an **absent** file and from a
**temporary** file, and the distinction is the whole product: Omafile aims to
make partial files structurally unable to exist at a final path, so any file
found at a final path is whole.

## Verification tiers

Four separable levels of assurance, deliberately not one idea. Ranked by the
strength of what they establish:

- **Shared extents** — the copy shares the source's extents copy-on-write, so
  there is no second set of bytes that could differ. Divergence is impossible by
  construction. Available only for a same-filesystem copy on a copy-on-write
  filesystem.
- **Checksum** — the committed file was read back and hashed against the source.
  Establishes that the bytes matched at one moment. Opt-in, named `--checksum`
  everywhere it appears.
- **Size** — the transferred byte count matched the source size. Unconditional,
  and free: the source size is already known.
- **Structural** — the commit discipline itself: temporary name, `fsync`, atomic
  rename. Unconditional.

Note the ranking is not "more checking is better": shared extents involves *no*
checking and is the strongest, because it removes the possibility of divergence
rather than testing for it.

"Verified" without qualification is ambiguous and should be avoided; name the
tier.

## Journal

Durable working state that makes resume possible. The journal is **not a
history**: it records Jobs that are *incomplete*, so they can be continued or
recovered, and an entry is discarded once its Job is committed. It is
deliberately incapable of answering "what did I copy last month".

## Backend

The implementation of file access for one kind of location — local disk, an SMB
share, later SFTP. A backend is what the transfer engine talks to instead of
talking to a protocol directly.

## Share, mount

A **share** is a named export on a server (`//host/name`). A **mount** is that
share made available at a local path. Omafile reaches SMB through a mount, so
to the engine a mounted share is a path like any other.

## Transfer engine

The part that executes a Job: reads, writes, verifies, commits, and journals.
Distinct from the browser, which selects what to move and shows what happened.
