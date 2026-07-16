## Backend

### General backend guidelines
- Layer strictly: handlers/controllers never touch data access directly; a repository/data-access layer sits in between.
- Return structured, stable error codes/mnemonics from the API boundary; never leak raw exception details or stack traces to clients. Map error codes centrally on the consuming (frontend) side rather than ad hoc per call site.
- Every mutation of important state should be auditable — either an audit-log table, structured logging, or both — especially for anything with compliance implications.
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
