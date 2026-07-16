# Login System

Reference for building a login/authentication system: username/password via challenge-response, OAuth2, SAML, and the session that results from any of them. This is one of the `systems/` reference docs (see `README.md`'s "Systems reference" section) — not part of the always-loaded guideline set, consulted only when this specific type of work is underway.

## Username/password via challenge-response

Prefer a challenge-response protocol over sending the password (or even a hash of it) over the wire at all. The core mechanism, verified against a real implementation:

- **Registration**: server generates a random salt `N` and stores `Q = bcrypt(SHA512(password ∥ N))` — never the raw password, and bcrypt (not a fast hash) over the SHA-512 pre-hash so long passwords aren't silently truncated by bcrypt's own input-length limit.
- **Login init**: server issues a random challenge `R` and the bcrypt salt extracted from `Q`, storing both in a short-TTL (a few minutes), single-use `login_challenge` row keyed by a challenge ID.
- **Browser computes**: `HPN = SHA512(password ∥ N)`, `Q' = bcrypt(HPN, salt)`, `Cc = HMAC-SHA512(key=R, msg=Q')`, and sends `F = HPN XOR Cc`. Neither the password nor `HPN` itself ever crosses the wire — only the XOR-masked value.
- **Server verify**: atomically delete-and-return the challenge row (`DELETE ... RETURNING ... WHERE challenge_id = ? AND expires_at > now()`) so it can never be replayed; recompute `Cc` from the stored `R`, XOR to recover `HPN`, re-bcrypt, and constant-time-compare against the stored `Q` (e.g. `CryptographicOperations.FixedTimeEquals` in .NET, `crypto.timingSafeEqual` in Node) — never a plain `==`, which leaks timing information about how many leading bytes matched.

```sql
create table login_challenge (
  login_challenge_id text primary key default (uuidv7()),
  account_id text not null references account(account_id) on delete cascade,
  challenge_r bytea not null,
  challenge_expires_at timestamptz not null
);
```

**This protocol alone is not a complete login system — the following are required additions, not optional hardening:**
- **Rate limiting / lockout** on both challenge-init and verify, keyed by account and by source IP/fingerprint independently (an attacker who controls neither still gets throttled). Without this, the challenge-response protocol's resistance to wire-sniffing does nothing to stop brute-force guessing.
  - **A per-account throttle alone can be weaponized to deny the real owner access** — an attacker who only knows the username, not the password, can deliberately fail logins to keep that account throttled. Past some failure threshold, escalate to a CAPTCHA/proof-of-work challenge rather than a hard block: this makes sustaining the denial cost the attacker continuous effort, instead of a one-time cheap trigger that costs the legitimate owner hours locked out.
  - **Notify the account owner on repeated failed attempts** (email/SMS, independent of whatever channel is being attacked) so they're aware mid-attack and can act or confirm "that wasn't me."
- **MFA/2FA** as a second, independent factor (TOTP is the simplest to self-host; avoid SMS-based codes as the sole second factor — they're phishable and SIM-swap-vulnerable).
- **Audit every attempt** — challenge-init, verify-success, and verify-failure all as distinct, queryable audit events (ties to the general "every mutation of important state should be auditable" backend guidance) — this is what makes the rate-limiting/lockout thresholds and any later incident investigation possible at all.

## OAuth2 support

*Directional — write from general best practice, not verified against a specific implementation in this guidelines repo yet. Verify against the current OAuth2/OIDC spec and your provider's docs before relying on specifics.*

- **Delegate entirely to the provider** — never ask a user for their third-party (Google/Microsoft/etc.) password directly; that defeats the entire point of federated auth.
- **Authorization Code + PKCE**, even for confidential clients — PKCE was originally a public-client (SPA/mobile) mitigation, but using it universally costs nothing and closes off an entire class of authorization-code-interception attacks.
- **Validate the ID token properly**: signature (against the provider's published JWKS, with key rotation handled — don't hardcode a key), `iss`, `aud`, `exp`/`nbf`, and `nonce` (replay protection tying the token back to the specific auth request that initiated it). Skipping any one of these is a real, exploited vulnerability class, not theoretical.
- **Store tokens encrypted at rest**, never in plaintext columns or logs (ties to "secrets never hardcoded... encrypted at rest" — see `SECRETS.md` for the local-secret-bundle convention, though that's for repo-level secrets, not per-user tokens, which belong in the database with column-level or application-level encryption).
- **Refresh-token rotation**: each refresh issues a new refresh token and invalidates the old one; if a supposedly-already-used refresh token is presented again, treat it as a signal of token theft and revoke the whole token family, not just that one token.

## SAML support

*Directional — same caveat as OAuth2 above: write from general best practice, verify against current spec/library docs before relying on specifics.*

- **Know which flow you're in**: SP-initiated (your app redirects the user to the IdP with an `AuthnRequest`) vs IdP-initiated (the user starts at the IdP and lands on your app with an unsolicited assertion) — IdP-initiated is more susceptible to certain replay/confusion attacks and needs stricter validation of `InResponseTo`/audience matching where applicable.
- **Validate the assertion, not just its presence**: signature (against the IdP's published certificate, with rotation handled), audience restriction (the assertion was actually issued *for your app*, not intercepted from traffic meant for another SP), and replay protection (track consumed assertion IDs, reject if seen before, within the assertion's validity window).
- **Prefer a vetted library over hand-rolled XML signature verification.** XML signature wrapping (where an attacker adds a forged, unsigned element while leaving the original signed element untouched, tricking a naive verifier into checking the wrong node) is a well-documented, repeatedly-exploited vulnerability class in hand-rolled SAML implementations — this is not a place to save a dependency.
- **Map IdP attributes to your own user model explicitly** — don't trust arbitrary attribute names/values from the assertion as if they were your application's own claims; treat them as untrusted input to be validated and mapped, the same as any other external data.

## Session issuance (after any of the above succeeds)

Once a user authenticates via any method above, issuing and managing the resulting session is a separate, cross-cutting concern — see `systems/session-management.md` for issuance, validation, rotation, and revocation. That doc applies no matter which login method got the user there, and governs the session for its entire lifetime, not just the moment it's created.
