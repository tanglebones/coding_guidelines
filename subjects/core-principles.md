## General Principles (language-agnostic)

- **Match existing style first.** Investigate the surrounding code/conventions before changing anything; keep diffs minimal and focused on the task at hand.
- **No dead weight.** Remove dead code, unused variables, write-only variables, leftover debug output, and stale TODOs as you touch a file.
- **Explicit dependency passing over hidden globals/IoC containers.** Prefer a composition root that wires real dependencies once, with libraries taking dependencies as plain constructor/function parameters, over DI containers or service-locators.
  ```ts
  // Dependencies flow in as ordinary params, not resolved from a container.
  async function createWidgetsInStore(
    storeClient: StoreClientType,
    dbProvider: DbProviderType,
    widgetsToCreate: WidgetCreateType[],
  ): Promise<CreateResultType> { ... }
  ```
- **Two-phase plan → execute for anything destructive or hard to reverse.** Dry-run/plan first, re-verify state, then execute; make execution idempotent and resumable; log every action and error to a durable, timestamped file.
- **Dry-run by default** for any tool that mutates production state or deletes things; require an explicit flag (`-Execute`, `--apply`, etc.) to actually mutate.
  ```powershell
  param([switch]$Execute)
  $dryRun = -not $Execute.IsPresent
  if ($dryRun) { Write-Host "DRY RUN: pass -Execute to actually remove '$name'" }
  else { Remove-Item $name -Recurse } # only reached with -Execute
  ```
- **Small, single-purpose, reusable modules** over large monoliths or inline duplication; hoist generic helpers into a shared library/package rather than copy-pasting.
- **Exceptions are for the unexpected, not control flow.** Never silently catch-and-log without a comment explaining why; never swallow or re-wrap an exception in a way that loses the stack trace (`throw;`, not `throw ex;`; not `new Exception(ex.Message)`).
  ```csharp
  try { await ProcessAsync(item); }
  catch (Exception ex) {
      _logger.LogError(ex, "Failed processing {ItemId}", item.Id);
      throw; // preserves the original stack trace — never `throw ex;`
  }
  ```
- **Never let a client-supplied value control a security decision** (auth bypass, 2FA skip, etc.) — that must always be a server-derived decision. Treat "off by default" security toggles as fragile; test the off-state explicitly.
  ```csharp
  // Anti-pattern actually seen in the wild — don't do this:
  if (model.SkipTwoFactorCheck) await _userManager.SetTwoFactorSkipAsync(model.UserName);
  // A client can set SkipTwoFactorCheck=true on the request and bypass 2FA entirely.
  // The decision to skip 2FA must be derived server-side (e.g. from a trusted device claim).
  ```
- **Secrets never hardcoded** — environment variables, CI-token-replacement, or encrypted-at-rest, always documented, never committed in plaintext.
- **Use cryptographically strong randomness** for anything security- or ID-relevant (e.g. `Guid.NewGuid()`, never `new Guid()`; UUIDv7 for DB primary keys, not sequential/guessable IDs).
- **2-space indentation** is the default house style across languages; treat 4-space/tabs as the outlier if you see it.
- **Bump the version as part of every change**, not as an afterthought: patch per change, minor for new features, major for breaking changes.
- **Deterministic tests.** Prefer seeded/mock time and randomness (a fake clock abstraction, an in-memory filesystem, fixed PRNG seeds) over real sleeps or nondeterministic inputs, so tests are reproducible and fast.
  ```csharp
  var fakeClock = A.Fake<IClock>();
  A.CallTo(() => fakeClock.UtcNow()).Returns(new DateTimeOffset(2025, 1, 1, 0, 0, 0, TimeSpan.Zero));
  ```
- **Doc comments explain *why*, not *what*** — invariants, non-obvious constraints, workarounds for a specific bug. Skip comments that just restate the code.
- **Write project docs (`README.md`, architecture notes, ADRs, etc.) for a fresh reader with zero prior context** — someone who wasn't part of whatever discussion, PR review, or chat session led to the change. Never write "as discussed," "per your request," "we decided," "the user asked for," or similar — state the resulting fact, decision, or rationale directly, as if it had always been true. If the *why* behind a decision matters, capture the durable reason (a constraint, a past incident, a tradeoff) rather than who asked for it or where it came from.
  ```md
  <!-- Bad: assumes the reader was in the room -->
  We decided to switch to keyset pagination like you asked.

  <!-- Good: states the fact and its durable rationale -->
  Pagination uses the keyset pattern — offset pagination degrades badly past large page counts.
  ```
