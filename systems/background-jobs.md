# Background Jobs

Reference for background/scheduled job design. This is one of the `systems/` reference docs (see `README.md`'s "Systems reference" section) — not part of the always-loaded guideline set, consulted only when this specific type of work is underway. Unlike `systems/login.md`/`systems/websocket-api.md`, this one is directional — written from general best practice, not verified against a specific implementation in this guidelines repo yet.

## Model convergence toward a computed state, not a sequence of operations

**The unit of design isn't "a job that does X" — it's "what should this state be right now, given everything currently known."** A job's real purpose is almost always to move some piece of persisted state toward a target value computed fresh from current source data, not to apply one more instruction in a sequence. This is the same idea as the "forward-cascading recompute" and `container_t_contents` hash-compare patterns already in `database`: recompute the whole target from source facts and reconcile, rather than accumulating relative deltas.

```
-- Delta-style (fragile): depends on how many times this has already run
update account set pending_invoice_count = pending_invoice_count + 1;

-- Convergence-style (idempotent by construction): recomputes the true
-- current value from source rows every time; running it twice with no
-- new invoices produces the identical result
update account set pending_invoice_count = (
  select count(*) from invoice where account_id = account.account_id and invoice_status = 'pending'
);
```

Running a convergence-style job twice in a row, or a hundred times, with no relevant change in source data, is a no-op by construction — not because someone remembered to add a dedup check, but because it's recomputing the same answer from the same inputs every time.

## Anti-pattern: multiple jobs, one piece of state, order-dependent outcome

**Don't let several independently-triggered jobs each patch the same state slice from their own partial view.** A common shape this goes wrong: an "expire stale widgets" job sets `widget_status_mnemonic = 'expired'` on one trigger, while a "reactivate on payment" job sets it to `'active'` on a different trigger — and whichever job happens to run last wins, regardless of which outcome is actually correct given *all* current facts. The bug isn't in either job individually; it's that two independent writers share one piece of state with no single source of truth about what it should be.

```
-- Anti-pattern: two jobs, two partial views, order determines the outcome
update widget set widget_status_mnemonic = 'expired' where widget_expires_at < now();   -- job A
update widget set widget_status_mnemonic = 'active' where widget_id in (select ...);     -- job B, unrelated trigger

-- Convergence instead: one function considers every current fact together
select widget_status_converge(widget_id); -- expiry, payment state, manual overrides — all inputs, one recomputed answer
```

The fix is one convergence function per state slice. Multiple events can still *trigger* it (a payment webhook, a scheduled sweep, a manual admin action) — but every trigger calls the same function, which recomputes the full target value from every current input, rather than each trigger applying its own narrow patch.

## Idempotency is the default expectation, not a special case

At-least-once delivery is the normal operating mode for any real job scheduler or queue — a worker can crash after finishing the work but before acknowledging it, a message can be redelivered, someone can manually rerun a job to recover from an incident. **A job must be safe to run twice (or a hundred times) on the same inputs.** Convergence-style design gives this for free for anything that's purely internal state; the moment a job touches something outside the system's own storage, a different pattern is needed — see below.

## The externality exception

**Anything that crosses the system boundary — sending an email, charging a card, calling a third-party API — cannot be converged.** There's no way to "recompute and reconcile" a real-world side effect once it's fired; unlike an internal database row, you can't just overwrite it with the correct value on the next run.

- **Durably record intent before performing the effect, and completion after** — a three-state lifecycle (`not yet attempted` → `attempted` → `completed`), so a crash mid-job leaves a detectable, resumable state instead of silent duplication or silent loss.
  ```sql
  create table job_side_effect (
    job_side_effect_id text primary key default (uuidv7()),
    side_effect_kind text not null,        -- e.g. 'send_welcome_email'
    target_id text not null,               -- e.g. the account_id this pertains to
    performed_at timestamptz,              -- null until the effect actually fired
    unique (side_effect_kind, target_id)   -- at most one attempt per kind+target, ever
  );
  ```
  Insert the intent row first (`ON CONFLICT DO NOTHING` — the unique constraint is what prevents two concurrent job runs from both deciding to fire); only perform the effect if the insert actually happened or `performed_at` is still null; mark `performed_at` on success. A crash between insert and marking `performed_at` leaves a detectable "attempted but unconfirmed" row for investigation, rather than either silently retrying (possible duplicate) or silently giving up (possible loss).
- **Use the external provider's own idempotency key support where available** (e.g. Stripe-style `Idempotency-Key` headers) as the authoritative dedup — it lets the one system that can actually enforce "exactly once" do so, with your own marker as the first line of defense against firing the request at all.
- **Risk-scale the guarantee to the harm a duplicate would cause.** An occasional duplicate email is annoying but tolerable — the marker-based approach above is enough. An occasional duplicate charge is not — that needs a real provider-side idempotency key, not just a same-process marker that a genuinely concurrent retry could still race past.

## Retries, backoff, and poison messages

- **Exponential backoff with a cap** between retry attempts for a failing job, same shape as the login rate-limiting guidance in `systems/login.md`.
- **A dead-letter/poison-message path after N failures** — a job that fails every time (a permanently malformed input, a bug) should stop retrying forever silently and instead land somewhere surfaced for investigation, not spin invisibly or get dropped.
