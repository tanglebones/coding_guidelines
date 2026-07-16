# File Uploads

Reference for handling user-uploaded files. This is one of the `systems/` reference docs (see `README.md`'s "Systems reference" section) — not part of the always-loaded guideline set, consulted only when this specific type of work is underway. Directional — written from general best practice, not verified against a specific implementation in this guidelines repo yet.

## Validate before trusting anything about the file

- **Validate file type by content (actual file signature/magic bytes), not by the client-supplied MIME type or filename extension** — both are trivially spoofable client input, the same "never trust client input" discipline as `backend-general`'s security patterns.
- **Enforce a size limit server-side (and ideally at the reverse proxy/gateway too) while streaming, not after fully buffering an arbitrarily large upload into memory.** An unbounded upload accepted before any size check is a denial-of-service vector.
- **Never use the client-supplied filename directly as a storage path or key.** A crafted filename (`../../etc/passwd`-style, or one containing path-traversal or null-byte tricks) is untrusted input same as any other. Generate your own storage key (e.g. a UUID) and keep the original filename only as displayed metadata, never as something used to construct a path.

## Upload path: through your server vs. direct-to-storage

- **Small files**: proxying through the app server (client → app → object storage) is fine.
- **Larger files or high volume**: prefer direct-to-storage upload via a presigned URL — the client uploads the actual bytes directly to object storage, bypassing the app server entirely for the transfer; the app server's job is only to issue the presigned URL (after checking authorization) and later confirm/register the completed upload. This keeps the app server from being a bandwidth/memory bottleneck for large payloads.
- **A presigned URL is a capability token — issue it with the same care as any other security decision.** Short-lived expiry, scoped to exactly one object key that the *server* chooses (never let the client pick the destination key), and only issued after the caller's authorization to upload there has already been checked — the same "authorization decided server-side, never by a client-supplied value" principle as everywhere else in this guideline set.

## Malware scanning

**Scan before anything is treated as trusted or servable to other users** — quarantine (stored but not yet exposed) until the scan completes, rather than exposing first and scanning after. This matters most for anything that will be downloaded by, or rendered inline to, a *different* user than the one who uploaded it.

## Storage lifecycle

- **Track upload metadata in your own database — object storage is a dumb blob store, not the source of truth for what's allowed to exist there.** Owner, tenant (see `systems/multi-tenancy.md` if this is a multi-tenant system), original filename, content type, size, scan status, and the storage key all belong in a row your application queries and authorizes against; the blob itself is just bytes at a key.
- **Orphaned uploads need a cleanup path.** A presigned URL that was issued but never actually used, or an upload that completed at the storage layer but whose confirming API call never arrived, leaves a dangling object with no matching metadata row. A scheduled reconciliation job (see `systems/background-jobs.md` — this is exactly the convergence-toward-a-target-state shape that doc describes: reconcile "uploads we issued a URL for" against "uploads actually confirmed," and expire/delete anything left dangling past a reasonable window) keeps storage from silently accumulating orphans.
- **Deletion should default to soft** (mark deleted, actually purge after a retention window) unless there's a hard requirement — e.g. a legal/compliance "right to be forgotten" request — for immediate, unrecoverable deletion. This is the same "prefer reversible actions over hard deletes" principle as `backend-general`.

## Serving uploaded content back

- **Don't serve user-uploaded content from the same origin as the main application if it could contain active content** (HTML, SVG with embedded scripts, etc.) — serve it from a separate, cookie-less origin/subdomain, so a stored-XSS payload smuggled in through an upload can't execute in the context of an authenticated session on the main app.
- **Set `Content-Type` and `Content-Disposition` deliberately when serving a file back — don't let the browser sniff/guess the type.** Content-type sniffing on a mis-typed or deliberately mislabeled upload is exactly how an uploaded file becomes an XSS vector; declaring the type explicitly (validated at upload time, not re-derived from the stored filename) closes that off.
