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
