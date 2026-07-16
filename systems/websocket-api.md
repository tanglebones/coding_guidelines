# WebSocket RPC API System

Reference for building a custom WebSocket-based RPC API — an alternative transport to REST/gRPC for high-throughput bidirectional or streaming workloads (see `backend-general`'s "don't default to REST" guidance). This is one of the `systems/` reference docs (see `README.md`'s "Systems reference" section) — not part of the always-loaded guideline set, consulted only when this specific type of work is underway. The mechanisms below are verified against a real production implementation.

## Connection lifecycle

- **Reuse the existing HTTP session cookie for WebSocket auth — don't invent a separate handshake token.** On the HTTP `upgrade` event, parse the same session cookie used elsewhere, validate it, and attach the resulting session/identity to the connection's context *before* accepting the socket. Every RPC call made on that socket then closes over an already-authenticated context — there's no separate "log in over the socket" step. See `systems/session-management.md` for the validation/rotation/revocation mechanics themselves, including why a long-lived connection needs periodic re-validation, not just a check at connect time.
- **Negotiate a sub-protocol version explicitly** (e.g. the client connects with `new WebSocket(url, ['rpc1'])`); reject and report supported protocols if the server doesn't recognize what the client offered. This is a deliberate, cheap seam for evolving the wire protocol later without an ambiguous "silently misinterpret old clients" failure mode.
- **Ping/pong idle-timeout, done correctly**: server pings every ~20s, tracks an `isAlive` flag reset on each `pong`, and terminates any socket that didn't respond since the *previous* ping (not the one just sent) — this is the standard correct pattern; a common mistake is checking the flag before giving the client a chance to respond to the ping that was just sent.
- **Client auto-reconnects with a rate cap, not unbounded retries or a single attempt.** A simple "at most once per N seconds" throttle on reconnect attempts is sufficient — full exponential backoff isn't required for this to be well-behaved, just a floor on retry frequency.
- **Reject in-flight requests immediately on disconnect** rather than leaving their promises hanging forever — synthesize a "connection closed" result for every pending request when the socket closes, so calling code's `await` always eventually resolves or rejects.

## Message envelope / RPC framing

**One flat, bidirectional JSON envelope, used identically for requests and responses in both directions** — either side can initiate a call, since server-push (see below) is just a call running in the opposite direction through the same shape:

```ts
type RpcEnvelope = {
  id?: string;       // client-generated correlation id (e.g. a tuid)
  module?: string;   // namespace — which registered module handles this
  method?: string;   // method name within that module
  args?: unknown;    // call arguments
  state?: string;    // '?' = request, '+' = success, '-XX' = a specific failure kind
  result?: unknown;  // present on success
  error?: unknown;   // present on failure
};
```

- **`id` is the entire correlation mechanism.** The initiating side generates it, stores a pending-promise entry keyed by it, and settles that promise when a response frame echoes the same `id` back. No other request/response matching machinery is needed.
- **Define this envelope once, as a single shared type used by both the client and server transport code** — don't let client and server packages each declare their own ad hoc inline shape for the same wire format; that's exactly the kind of drift the `_1_`/`_e_` "mandatory in both directions" naming discussion elsewhere in this guideline set warns about (two sides silently assuming a shared contract that isn't actually enforced anywhere).
- **Fire-and-forget calls** get an immediate ack the moment they're dispatched (not once the handler finishes) and no final result frame — this is the mechanism server-initiated push uses (see below), not a separate envelope variant.

## Routing / dispatch

**A two-level registry — `module name → method name → handler` — not a switch statement.**

```ts
type RpcHandler = (ctx: RequestContextType, args: unknown) => Promise<unknown>;
type RpcCallDef = { call: RpcHandler; authz?: AuthzCheckType; fireAndForget?: boolean };
type RpcModule = { name: string; calls: Readonly<Record<string, RpcCallDef>> };

// registering a module throws if the name is already taken — fail fast on a
// naming collision rather than silently letting one module shadow another
rpcServer.addModule(sessionModule);
```

Dispatch is: look up `modules[envelope.module]` → an optional module-level authorization gate → `module.calls[envelope.method]` → an optional per-call authorization gate → invoke the handler.

- **Organize by domain, one factory function per feature, each self-registering its own module** — e.g. a `sessionModuleFactory(rpcServer, ...)` that both calls `rpcServer.addModule(...)` and returns a typed client-side wrapper for that same domain. Compose all of them once, centrally, at service bootstrap (a flat sequence of factory calls) — this is a lightweight plugin/DI pattern for RPC modules, not a framework dependency.
- Generic, cross-domain concerns (see push/subscription below) are worth factoring into their own reusable factory that any domain module can parametrize, rather than reimplementing per domain.

## Result/error handling — the concrete proof of "results belong in the payload"

A raw WebSocket frame has no concept of success or failure — there is no transport-level signal available the way an HTTP status code exists for REST. This system's `state` field is the **entire** discriminant, carrying the result — success or a specific failure kind — of every call:

| `state` | Meaning |
|---|---|
| `'?'` | request |
| `'+'` | success (see `result`) |
| a failure code (e.g. `'-EX'` uncaught exception, `'-SE'` structured/expected app error, `'-NF'` method not found, `'-AD'` access denied, `'-CC'` connection closed while pending) | failure (see `error`) |

- **Distinguish an expected, structured application error from an uncaught exception explicitly.** A structured error (a typed, expected rejection the handler deliberately produced) should carry its full structured shape to the client; an uncaught exception should fold down to a generic failure code with just a message — never leak a stack trace or internal exception detail to the client, mirroring the "never leak raw exception details" guidance in `backend-general`.
- **Centralize the failure-code taxonomy as one shared type/enum, not hand-written string literals scattered at each call site.** Functionally a handful of ad hoc string literals still works, but a shared type catches typos and makes the full set of possible outcomes discoverable in one place.
- This is the same principle documented in `backend-general` as HTTP status codes being transport-only — here there's no transport-level signal available at all, which makes it unambiguous: the payload has to carry the result, full stop.

## Push / broadcast events

**Server-initiated push is not a separate mechanism — it's an ordinary fire-and-forget call, running through the exact same registry and envelope, just initiated by the other side.** There's no distinct "event" frame type to design.

- **Model subscriptions as explicit, topic-scoped app-level state — not blind broadcast-to-all.** A client subscribes to a partition/key it cares about; the server tracks subscribers per topic and fans out only to those sockets when that topic changes; unsubscribing (including on disconnect) removes the client from the topic's subscriber set. This gives targeted push without needing a general pub/sub broker.
- Two distinct shapes are both legitimate depending on the data:
  - **Patch/delta push** for a topic a client is actively viewing (server sends the applied change; client applies it to local state).
  - **Keyed cache-invalidation push** for individual entities (server sends `{store, key, data, hash}` whenever that specific entity changes; client compares the hash to detect whether it actually needs to update).

## Reconnection & state recovery

- **Signature-based resync is a good middle ground between "always reload everything" and "replay every missed event."** On (re)subscribe, the client sends its last-known state signature for that topic; the server compares against its current signature and only ships full current state back if they actually differ — otherwise it tells the client "you're already current," and the client just resumes receiving live push from that point. This avoids both unnecessary full-state transfers on trivial reconnects and the complexity of true incremental replay of missed messages.
- **Not everything needs resync logic.** For state that's cheap to refetch outright (a session-info call, a small reference lookup), it's a reasonable simplification to just have the client re-issue the same request fresh on reconnect rather than building signature-comparison machinery for it. Reserve the signature-compare optimization for higher-volume or streaming topics where a full refetch would actually be expensive.

## What to avoid

- **Don't duplicate the envelope type definition across client and server packages** — declare it once, in a shared location both sides import, so a wire-format change can't silently drift out of sync between the two sides.
- **Don't hand-roll error/state codes as ad hoc string literals at each call site** — centralize them in one shared type.
- **Don't leave the core transport/dispatch layer untested even if the domain modules built on top of it are well covered** — a bug in the envelope/dispatch plumbing itself silently breaks every module built on top of it at once, which is exactly the kind of foundational code that most needs test coverage, not least.
