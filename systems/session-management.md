# Session Management

Reference for managing an authenticated session's full lifecycle — issuance, validation, rotation, and revocation. This is a cross-cutting concern, not part of any one login method: it applies no matter how the user proved their identity (`systems/login.md`), and it governs every authenticated request for as long as the session lives, over any transport (a plain HTTP request or a long-lived WebSocket connection, see `systems/websocket-api.md`). This is one of the `systems/` reference docs (see `README.md`'s "Systems reference" section) — not part of the always-loaded guideline set, consulted only when this specific type of work is underway. The mechanisms below are verified against a real implementation.

## Issuance

Once a user authenticates via any method (`systems/login.md`), issue a session:

- **The cookie (or bearer token, for non-browser clients) carries only an opaque session-claim ID** — not a JWT, not the framework's default self-contained session cookie. Cookie flags: `HttpOnly`, `Secure`, `SameSite=Lax` (or `Strict` if cross-site navigation into an authenticated view is never needed).
- **Validity is authoritative in a server-side row, not the cookie's cryptographic validity alone.** A cookie can be well-formed and still represent a revoked/expired session.
  ```sql
  create table session_claim (
    session_claim_id text primary key default (uuidv7()),
    account_id text not null references account(account_id) on delete cascade,
    expires_at timestamptz not null
  );
  ```

## Validation

- **Every request validates the claim ID against the DB, not just against the cookie's own signature** — for an ordinary HTTP request, this is a per-request middleware check.
- **For a long-lived connection (a WebSocket, a server-push channel), validate once at connect and then periodically re-validate on an interval** (e.g. every 30s) for the connection's whole lifetime — a session can be revoked while the connection stays open, and cryptographic cookie validity alone can't detect that. See `systems/websocket-api.md`'s connection-lifecycle section for how this applies at the HTTP→WebSocket upgrade specifically.

## Rotation

- **Rotate with an overlapping grace period, not an atomic swap.** On rotation (e.g. a client-driven refresh call before expiry), demote the *old* claim ID to a short grace TTL (seconds, not minutes) instead of deleting it outright, and issue a new claim ID — this absorbs the race where a concurrent request already in flight still carries the old cookie value.
- **A background reaper for expired rows** — TTL-based server state needs an explicit process deleting expired claims on a schedule; don't rely on lazy expiry-on-read alone, or the table grows unbounded.

## Revocation

- **Distinguish single-session revoke from "sign out everywhere."** An explicit logout on one device should revoke only that session's claim by default; a user-initiated "sign out of all devices" (or an admin/security-triggered forced logout) revokes every claim for that account.
- **Consider surfacing and capping concurrent sessions per account** — letting a user see their active sessions (device/location/last-active, if tracked) and revoke individually is a reasonable feature to build once the claim table already exists; an outright hard cap on concurrent sessions is a product decision, not a security requirement, and shouldn't be assumed without one.
