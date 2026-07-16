# SFTP File Transfer

Reference for exchanging files with an external system over SFTP — a partner drops files for you to pick up, or you deliver files for a partner to pick up. This is one of the `systems/` reference docs (see `README.md`'s "Systems reference" section) — not part of the always-loaded guideline set, consulted only when this specific type of work is underway. This is an application of the marker/`.done`-file idempotency convention already established in `shell`, to the specific shape of a multi-file batch handed off between two systems that don't otherwise coordinate.

## Writer: timestamped batch directory + completion marker

- **One directory per batch, named by a real UTC timestamp** (e.g. `20260716T143000Z/`), not a sequence number — this keeps directory listings naturally chronological and gives every reader an unambiguous ordering with no extra state to track.
- **Write every file in the batch, and only after every file is fully written and closed, create a `done.ctl` marker file in that same directory** — the same "write the completion marker only after the underlying work is fully done, never before" convention already in `shell`, applied to a multi-file batch instead of a single operation.
- **Once `done.ctl` exists, the writer must never modify any file in that directory again.** A completed batch is immutable from that point forward. If a correction is needed, write a *new* batch directory (a new timestamp) — never edit files in a directory already marked done. This is the same discipline as "corrections are truncate-the-old-row + insert-the-new-row, never an in-place update" in `database`'s bitemporal section: once something is marked final, the fix is a new entry, not a retroactive edit to the old one.

## Reader: check for `done.ctl` before reading anything

- **Check for `done.ctl` before reading any file in a batch directory — never read from a directory that doesn't have it yet.** A directory without the marker might still be mid-write (a partial file, one still being appended to); reading early risks processing a truncated file as if it were complete.
- This is the read-side half of the same convention: the writer's guarantee ("nothing in this directory changes once `done.ctl` exists") is exactly what makes it safe for the reader to start the moment it sees the marker, with no further coordination needed between the two sides.
- **After processing, mark or move the batch** (rename/move it to a `processed/` location, or write the reader's own completion marker) so a scheduled reader run doesn't reprocess the same batch twice — the reader's own idempotency, layered on top of the writer's completeness guarantee.

## If batches aren't cleaned up: tier the directories by date

**If completed batch directories are kept indefinitely (the SFTP root doubles as an archive, not just a drop-off/pickup point), use a tiered date-based structure — `yyyy/mm/dd/<timestamp-batch>/` — rather than one flat directory holding every batch ever sent.** A single directory accumulating years of batches eventually becomes slow to list, both for the SFTP server and for any client doing a directory listing, and unwieldy for a human to navigate manually. Tiering by calendar date (not, say, batch count per directory) keeps the structure predictable and lets anyone narrow in on "everything from March 2026" without needing an index. If batches genuinely don't need to be retained after processing, prefer actually deleting or archiving them elsewhere over letting a flat *or* tiered structure grow forever by default — tiering solves "large but necessary," not "large because nothing was ever cleaned up."
