## Backend

### General backend guidelines
- Layer strictly: handlers/controllers never touch data access directly; a repository/data-access layer sits in between.
- Return structured, stable error codes/mnemonics from the API boundary; never leak raw exception details or stack traces to clients. Map error codes centrally on the consuming (frontend) side rather than ad hoc per call site.
- Every mutation of important state should be auditable — either an audit-log table, structured logging, or both — especially for anything with compliance implications. See `observability` for the actor-centric pattern this actually looks like in practice.
- Prefer reversible actions (deactivate/soft-delete) over hard deletes where the domain allows it.
- Async all the way — no sync-over-async blocking; wrap unit-of-work/connections in `using`/RAII so they're always released.
- **Don't default to REST out of habit.** gRPC and a custom WebSocket/RPC transport (a single message-envelope-based channel) are legitimate choices, not exotic fallbacks — pick based on the actual need: simple resource CRUD consumed by a browser fits REST-ish conventions fine; high-throughput bidirectional or streaming workloads are often better served by gRPC or a WebSocket RPC channel instead.
- **HTTP status codes describe transport-level outcomes only — never the business/endpoint result.** A status code answers "did a valid route get reached, did the connection/transfer itself succeed" — nothing about what the endpoint's own logic decided. `404` means *no such endpoint exists at this path*, not "the endpoint ran and didn't find the widget you asked for" (that's a successfully-executed request with a not-found *result* — respond `200` with that result in the payload). `500` means the server process itself failed to produce a response (an unhandled crash), not "the request failed validation" or "the domain operation was rejected." Every endpoint response carries its actual outcome — success or error alike — in the payload via one consistent discriminated result envelope (ties to the structured error-mnemonics bullet above), so client code branches on payload contents, never on `response.status`.
  ```ts
  type ApiResult<T> =
    | { ok: true; data: T }
    | { ok: false; code: string; message: string }; // e.g. "WIDGET_NOT_FOUND", "VALIDATION_FAILED"

  // Both "found" and "not found" are successful invocations of the endpoint —
  // both get HTTP 200, and the caller branches on `result.ok`, not on status.
  const result: ApiResult<WidgetType> = await widgetService.find(widgetId);
  ```
  Using `400`/`401`/`403`/`422` to encode validation failures, auth decisions, or domain rejections is a common but incorrect pattern this guidance deliberately rejects — those are business results too, and belong in the payload alongside everything else. Status codes stay legitimately relevant only for things actually happening at the network/transport layer: redirects, content negotiation, rate limiting or circuit-breaking enforced by a gateway/load balancer in front of the app, and genuine upstream transport failures (`502`/`503`/`504`) — none of which is the endpoint's own business logic speaking.
- **Never emit explicit `null`s in a JSON API response — model optionality more explicitly** (an absent key, a discriminated `{ present: false }`-style shape, or a separate endpoint/field for the optional data). This is a general JSON payload convention, not a C#-specific one — see `backend-csharp` for the language-specific reminder.
- **Encode any integer that could exceed `2^53 - 1` (JavaScript's safe-integer limit, `Number.MAX_SAFE_INTEGER`) as a JSON string, never a JSON number.** JSON itself has no separate integer type — numbers are parsed as IEEE-754 doubles by JavaScript (and by many other JSON consumers), which can only represent integers exactly up to `2^53 - 1`. Any 64-bit integer, snowflake-style ID, large sequence number, or monetary amount in minor units at scale can silently exceed that and lose precision on the wire with no error raised — the response parses fine, the number is just quietly wrong. `int32`-range values are always safe and don't need this; the risk starts well before a true 64-bit range, so encode as a string whenever a field's range isn't provably bounded well under `2^53`.
  ```ts
  type WidgetResponse = {
    widgetId: string;      // UUIDv7 primary key — already a string, no issue
    sequenceNumber: string; // a bigint-backed counter — encoded as a string, not a number
    quantity: number;       // small, provably bounded — a plain number is fine
  };
  ```

### API idempotency & versioning

- **Idempotency keys for any retried mutating request.** A client that never gets a response (timeout, dropped connection) can't tell whether the request succeeded server-side or not — a naive retry risks double-creating, double-charging, or double-sending. The client generates one key per logical operation (not per HTTP attempt) and sends it with the request; the server durably records the key before performing the operation, and on a repeat with the same key, returns the original recorded result instead of repeating the effect. This is the same durable-intent/completion pattern as the externality handling in `systems/background-jobs.md` — same underlying problem (a retried call, no way to tell if it already happened), same fix.
  ```sql
  create table idempotent_request (
    idempotency_key text primary key,
    request_hash text not null,   -- hash of the request body, to catch a key reused for a *different* request
    response_body jsonb,          -- null until the operation actually completes
    created_at timestamptz not null default clock_timestamp()
  );
  ```
  Insert the key first (`on conflict do nothing`); if a row already exists with a `response_body` set, return that instead of re-running the operation; if `request_hash` doesn't match what's stored, that's a client bug (reusing a key for a genuinely different request) — reject it rather than silently doing something with it. Reserve this for operations where a duplicate would actually cause harm (create, charge, send) — a read is already naturally safe to retry and doesn't need it.
- **A deliberate versioning and deprecation policy for endpoints and payload shapes.** Pick one axis to version on (a URL/header-based API version, e.g. `/v2/widgets`, or payload-shape backward-compatibility rules) and apply it consistently — don't mix both informally. Additive changes (a new optional field) don't need a version bump; anything that changes what an existing field means, removes a field, or changes its required-ness is breaking and does. Deprecation needs an actual lifecycle — mark it, publish a real sunset date in advance, keep serving the old version until then — never silently break or remove a version clients are still calling. The same discipline already applies to the audit-event mnemonics in `observability` (`_v1`/`_v2` as a new type, never silently repurposing what an existing mnemonic means) — apply it here too, including to error codes inside the discriminated result envelope from the section above.

### Security patterns

- **Never trust client input, for data or for authorization.** Frontend validation and route guards are UX conveniences, not security controls — a client can always bypass them (a raw HTTP call, a modified request, a different client entirely). This generalizes the "never let a client-supplied value control a security decision" principle in `core-principles` to every input, not just explicit security-toggle fields.
- **Re-check authorization for the specific resource on every request, not just "is this route behind a login gate."** Being authenticated proves who the caller is; it doesn't prove they're allowed to act on the particular resource ID in *this* request. Skipping the per-resource check is how one user ends up reading or mutating another user's data just by changing an ID (IDOR) — the fix is checking ownership/permission against the resource actually being touched, every time, not trusting that reaching the handler at all implies authorization.
- **Validate and constrain every input at the API boundary** — type, range, length, format — before it reaches business logic, regardless of what the client-side form already checked.
- **Never bind a request body directly onto a domain/DB model (mass assignment).** Map only the specific fields a given operation is allowed to set; otherwise a client can set fields it was never meant to control (`isAdmin`, `accountBalance`, `role`) just by including extra keys in the JSON body.
  ```ts
  // Anti-pattern: whatever the client sent becomes the update
  await widgetRepo.update(widgetId, req.body);
  // Explicit allowlist instead: only these fields can ever be set this way
  await widgetRepo.update(widgetId, { name: req.body.name, description: req.body.description });
  ```
- **Encode output at the point of rendering, for the context it's rendered into** (HTML-escape for HTML, JS-string-escape for inline scripts, etc.) — sanitizing on the way in is not a substitute, since the same stored value may end up rendered in more than one context with different escaping needs.
- **CSRF protection on every state-changing endpoint reachable via a browser session cookie** — `SameSite` cookies plus an anti-forgery token for cookie-authenticated requests. Not needed for a pure bearer-token API the browser never attaches automatically, but don't assume that's what you have without checking.
- **Set security response headers centrally** (a CSP, `X-Content-Type-Options: nosniff`, HSTS, etc.), via shared middleware — not decided ad hoc per endpoint, where it's easy for a new endpoint to simply be forgotten.
- **Least-privilege service/DB credentials.** The application's own database role or service account should hold only the permissions it actually exercises, not a superuser/admin connection reused everywhere out of convenience — a compromised app process shouldn't automatically mean a compromised database.
- **Dependency/supply-chain integrity**: commit the lockfile, audit dependencies for known vulnerabilities as part of CI (e.g. `npm audit`, per the equivalent bullet in `frontend-angular`), and track any necessary exception in an explicit allowlist rather than silently ignoring a finding.
- **Rate-limit and abuse-protect any expensive or sensitive endpoint, not only login.** `systems/login.md` documents the detailed pattern (per-account + per-source keying, capped backoff, CAPTCHA escalation) — the same shape applies to any endpoint that's costly to run or attractive to abuse (password reset requests, expensive search/export operations, anything that sends email/SMS on the caller's behalf).
