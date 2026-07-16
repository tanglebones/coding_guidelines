## Observability

### System / operational logging

- **Structured logging** (JSON-shaped fields, not string-interpolated messages) so log lines are machine-queryable, not just human-readable after the fact.
- **One correlation/trace ID per request**, generated at ingress if the caller didn't already supply one, threaded through the same request-scoped context object used for db/session state (the `ctx` pattern in `backend-node`) — so every log line, downstream call, and audit event emitted during that request can be tied back to a single trace.
  - **A caller-supplied trace ID is normal and expected from a trusted internal caller** (service-to-service propagation, e.g. a `traceparent`-style header) — that's the whole point of distributed tracing, and it should simply be adopted rather than replaced.
  - **From an external/untrusted client, accepting a caller-supplied trace ID isn't a flat "never" — but treat it as untrusted input, not inert metadata, once accepted.** Validate its shape (length/charset) before it lands anywhere unescaped, the same as any other client-supplied value — an unvalidated trace ID logged verbatim is a log-injection vector. And think through what an attacker gains from controlling this value: hammering an endpoint under one shared trace ID (or a flood of freshly-chosen ones) to probe how correlation/aggregation behaves, to blend into another client's traffic in a review, or to see what an anomaly-detection system keys off of. If external callers are allowed to set this, have an actual answer for "what happens when a lot of requests arrive under the same trace ID" — rate-limit/flag on it like any other high-cardinality abuse surface (the same discipline as `backend-general`'s rate-limiting guidance), rather than assuming a trace ID is automatically harmless just because it isn't a business field.
- **Use log levels deliberately**: `error` — something broke and needs attention; `warn` — degraded but recovered on its own; `info` — notable lifecycle events (startup/shutdown, a scheduled job completed); `debug` — verbose detail, off by default in production.
- **Never log secrets, tokens, passwords, or full PII** — log an identifier (`account_id`) instead of a name/email/etc., and redact known-sensitive fields centrally (a logging middleware/formatter), not by trusting every call site to remember.
- **Don't silently swallow a caught exception with no log line.** A bare `catch { }` that assumes some other layer's default logging will "pick up" the failure doesn't work — by definition, an exception that's been caught and handled is no longer unhandled, so whatever safety net exists for genuinely unhandled exceptions never sees it. This is the concrete downstream cost of the "exceptions are for the unexpected" principle in `core-principles`: catching and logging deliberately is fine; catching and silently discarding hides real failures.

### Actor-centric audit / domain-event log

**Model every notable occurrence — a user's action or the system's own observation — as one event type, distinguished only by who/what the actor was, not by which pipeline it went through.** A real user is one kind of actor; an automated process (a background job, a scheduled check) is a second kind of actor in the same actor table. This single mechanism is what "every mutation of important state should be auditable" (`backend-general`) actually looks like in practice, whether the mutation was triggered by a person or by the system itself:

```sql
create table actor (actor_id uuid primary key default (uuidv7()));

create table actor_1_user (
  actor_id uuid primary key references actor(actor_id) on delete cascade,
  user_account_id uuid not null references user_account(user_account_id) on delete cascade
);
create table actor_1_system_actor (
  actor_id uuid primary key references actor(actor_id) on delete cascade,
  system_actor_mnemonic text not null unique -- e.g. 'liveness_check_runner', 'billing_reconciler'
);

create table audit_event (
  audit_event_id uuid not null default (uuidv7()),
  audit_event_at timestamptz not null default clock_timestamp(),
  actor_id uuid not null references actor(actor_id) on delete restrict,
  audit_event_type_mnemonic text not null references audit_event_type on delete restrict,
  audit_event_data jsonb not null,
  primary key (audit_event_id, audit_event_at)
) partition by range (audit_event_at); -- e.g. monthly, for a high-volume append-only log
```

- **One schema, one emit function, one query surface serves both "what did a user do" and "what did the system observe/do on its own"** — rather than maintaining two separate logging pipelines for what's fundamentally the same "what happened, who/what did it, when" query need. Reading "audit events for this account" and "domain events for this account" become the same query, filtered or not by actor kind.
- **Closed, versioned event-type mnemonics** (e.g. `login_verified_v1`, `liveness_check_v1`), DB-enforced via a reference table — not freeform strings — so the full set of possible event types is discoverable and query-able, while the payload (`audit_event_data`) stays schemaless JSON per type, since genuinely different event types carry genuinely different data.
- **Version the mnemonic itself, not the row, when a payload shape changes.** Introduce `_v2` as a new type rather than silently changing what `_v1` rows mean — old rows keep the shape they were actually written with, consistent with the forward-only migrations principle in `database`.
- **This write is not free, and isn't automatically atomic with the action it describes.** Emitting the audit/event row on a separate connection or transaction from the action being recorded means a crash between the two silently loses the record. If completeness actually matters (compliance, security investigation), write the event in the *same* transaction as the action — a fire-and-forget call afterward is a real gap, not a detail to skip over.

### Current-state tables still need their transitions logged

Some things aren't really "events" at all — they're current, mutable state you query for "what's true right now" (an open incident, a running job's status), not a history to replay. Don't force that into the append-only event log as its primary representation. But the *transitions* of that state (opened, closed, reassigned) are exactly the kind of thing worth mirroring into the audit/event log for history — the same shape as the frozen-snapshot-vs-live-table split already documented in `database`'s time-versioned/bitemporal section: a live mutable table answers "what's true now," a separate append-only log answers "what happened over time," and neither should be forced to do the other's job.
