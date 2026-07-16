# Coding Guidelines

Default coding conventions for Claude Code (and any other coding agent) to follow in this environment — general principles plus backend, frontend, database, infra, and game-dev specifics. Trim, merge, or extend as conventions evolve; this is a living reference, not a historical record.

---

## How the Agent Should Use This Document

**These are defaults, not hard rules.** Follow every guideline below automatically, without being asked, whenever it applies to the task at hand. But use judgment about when a guideline doesn't fit — and when it doesn't, don't silently comply and don't silently ignore it either. Instead:

1. **Follow by default.** Apply the relevant guidelines below to any code you write or modify, without waiting to be told.
2. **Flag tension before overriding.** If following a guideline would be actively wrong for the task — it conflicts with an explicit user instruction, contradicts an established pattern already used elsewhere in the codebase, doesn't fit the language/framework/tooling actually in play, or the underlying tradeoff clearly doesn't apply here — stop and ask the user for an explicit exception before proceeding. Say which guideline is in tension and why you think an exception is warranted. Don't guess at whether the user would be fine with it; ask.
3. **User instructions win, but still get flagged.** If the user has explicitly asked for something that conflicts with a guideline, follow the user's instruction — but still call out the conflict rather than silently complying, and document it per rule 4.
4. **Always report and document a deviation, once one happens.** Whether the exception came from the user granting it, from an explicit user instruction, or from your own judgment call in a case too minor to interrupt for:
   - **Tell the user in your response** which guideline was not followed and why.
   - **Leave a short comment in the code at the point of deviation** explaining *why* the guideline wasn't followed — not what the code does. For example: `// Deviates from indexing guidance: no index on this FK — table is <100 rows and never queried by it.`
5. **When genuinely unsure whether a guideline applies**, ask rather than assume either way — silence is never treated as permission to skip a guideline.

---

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

---

## Backend

### General backend guidelines
- Layer strictly: handlers/controllers never touch data access directly; a repository/data-access layer sits in between.
- Return structured, stable error codes/mnemonics from the API boundary; never leak raw exception details or stack traces to clients. Map error codes centrally on the consuming (frontend) side rather than ad hoc per call site.
- Every mutation of important state should be auditable — either an audit-log table, structured logging, or both — especially for anything with compliance implications.
- Prefer reversible actions (deactivate/soft-delete) over hard deletes where the domain allows it.
- Async all the way — no sync-over-async blocking; wrap unit-of-work/connections in `using`/RAII so they're always released.

### C#/.NET

**Formatting & structure**
- 2-space indent, no tabs; braces always required (no single-line `if` without braces); **Allman style** — opening brace on its own line.
- One type per file, filename matches the type name; file-scoped namespaces; directories mirror namespaces (no incidental subfolders).
  ```csharp
  using System.IO.Abstractions; // NuGet: TestableIO.System.IO.Abstractions

  namespace Company.Widgets.Lib;

  public sealed class WidgetSyncRunner : IWidgetSyncRunner
  {
      internal static class Dep
      {
          public static IFileSystem FileSystem = FileSystemDep.Real;
      }

      public async Task RunAsync(CancellationToken ct = default)
      {
          if (Dep.FileSystem.File.Exists(path))
          {
              ...
          }
      }
  }
  ```
- No `#region`.
- `.editorconfig`-enforced where present: LF line endings, final newline, file-scoped namespaces.

**Design**
- Most restrictive access modifier by default (`private` > `internal` > `public`); avoid `protected` entirely.
- No `abstract` classes, no implementation inheritance (`virtual`/`override`) — use `sealed` classes + interfaces (ISP/LSP) + composition/delegation instead.
- Avoid `enum`; prefer discriminated-union-style types (e.g. `OneOf`) or string constants.
  ```csharp
  using OneOf;

  internal static class WidgetDeleteResolver
  {
      internal static OneOf<NeedsDelete, AlreadyGone, SizeMismatch> Decide(
          IFileSystem fileSystem, string path, long expectedSizeBytes)
      {
          if (!fileSystem.File.Exists(path)) return new AlreadyGone();
          return fileSystem.FileInfo.New(path).Length == expectedSizeBytes
              ? new NeedsDelete()
              : new SizeMismatch();
      }
  }
  ```
  **Once .NET 11 ships, prefer the native `union` type over `OneOf`** for this — it needs no library dependency and is consumed with an ordinary `switch`, no `.Match()`/`.Switch()` call needed:
  ```csharp
  internal union WidgetDeleteDecision(NeedsDelete, AlreadyGone, SizeMismatch);

  internal static class WidgetDeleteResolver
  {
      internal static WidgetDeleteDecision Decide(IFileSystem fileSystem, string path, long expectedSizeBytes)
      {
          if (!fileSystem.File.Exists(path)) return new AlreadyGone();
          return fileSystem.FileInfo.New(path).Length == expectedSizeBytes
              ? new NeedsDelete(path)
              : new SizeMismatch(path);
      }
  }

  // consuming code:
  switch (WidgetDeleteResolver.Decide(fileSystem, path, expectedSizeBytes))
  {
      case NeedsDelete needsDelete: fileSystem.File.Delete(needsDelete.Path); break;
      case AlreadyGone: break;
      case SizeMismatch sizeMismatch: Log(sizeMismatch.Path); break;
  }
  ```
- Avoid "class as data + serialization" — for external/DB-shaped data prefer raw dynamic/JSON objects or query results over rigid POCOs; prefer Newtonsoft.Json over `System.Text.Json` where a choice exists.
- Never emit explicit `null`s in API responses; model optionality more explicitly.
- UTC / `DateTimeOffset` / `TimeSpan` everywhere — never naive local `DateTime`.
  ```csharp
  public sealed class Clock : IClock
  {
      public DateTimeOffset UtcNow() => DateTimeOffset.UtcNow;
  }
  ```
- `var` everywhere; LINQ method syntax, not query syntax; iterative over recursive; depend on interfaces, construct concrete types lazily at the edges.

**Dependency injection & testing**
- No IoC container. Use a `Dep` static inner-class pattern for test seams: static mutable fields swapped in tests, `Reset()` called in teardown; generic classes get a companion `${Foo}Dep` class. The inner class is always named `Dep` (singular) — never `Deps`.
  ```csharp
  // One small wrapper per dependency source/area, not one shared class bundling
  // everything together — FileSystem and Clock come from unrelated libraries.
  internal static class FileSystemDep
  {
      public static readonly IFileSystem Real = new FileSystem(); // System.IO.Abstractions
  }

  internal static class ClockDep
  {
      public static readonly IClock Real = new Clock();
  }

  public sealed class WidgetSyncRunner
  {
      internal static class Dep
      {
          public static IFileSystem FileSystem = FileSystemDep.Real;
          public static IClock Clock = ClockDep.Real;
          public static void Reset() { FileSystem = FileSystemDep.Real; Clock = ClockDep.Real; }
      }
  }

  // in a test fixture:
  [SetUp] public void SetUp() { WidgetSyncRunner.Dep.Clock = _fakeClock; }
  [TearDown] public void TearDown() => WidgetSyncRunner.Dep.Reset();
  ```
- Testing stack: **NUnit + FakeItEasy** (`A.Fake<T>()`), with a fake/in-memory filesystem abstraction for file I/O.
  ```csharp
  [TestFixture]
  public class WidgetSyncRunnerTf
  {
      private IClock _clock = A.Fake<IClock>();

      [SetUp]
      public void SetUp() =>
          A.CallTo(() => _clock.UtcNow()).Returns(new DateTimeOffset(2025, 6, 15, 10, 30, 0, TimeSpan.Zero));
  }
  ```
- `InternalsVisibleTo` wired to the matching `.Test` assembly (and FakeItEasy's dynamic proxy assembly) via the `.csproj`.
- All `Task`/`Task<T>` methods take a trailing `CancellationToken ct = default`.
- Trivial "constructs without throwing" / non-null smoke tests are an accepted floor even when deeper coverage is missing.
- For libraries with well-defined boundaries, consider enforcing 100% line/branch coverage via a coverage gate, with explicit `[ExcludeFromCodeCoverage]` + a short comment for the handful of intentionally-excluded composition-root classes.
  ```csharp
  [ExcludeFromCodeCoverage(Justification = "Thin wrapper around the real DB connection")]
  internal static class SqlQueryExecutor { ... }
  ```

**Anti-patterns to avoid**
- `Try/Catch` that re-throws as `new Exception(ex.Message)`, losing the original stack trace — use `throw;` instead.
- Returning raw exception objects to API clients (e.g. `BadRequestObjectResult(ex)`) — map to a stable, safe error code/message instead.

### Rust

- Prefer many small, single-purpose crates over one monolith; put shared logic in a thin library crate at the bottom of the dependency graph.
  ```
  workspace/
    rt/          # thin shared lib: error alias, small helpers — no dependents
    widget_fetch/
    widget_normalize/
    widget_export/
  ```
- **`anyhow::Result<T>` + `bail!()`/`.context()` everywhere** — this is the only accepted error-handling style now. Do not introduce a hand-rolled error enum or a project-wide `Rt<T> = Result<T, Box<dyn Error>>` alias for new code; treat any existing `Rt<T>`-style alias as legacy to migrate away from when touched, not a pattern to extend.
  ```rust
  use anyhow::{Result, Context, bail};

  fn parse_widget(bytes: &[u8]) -> Result<Widget> {
      if bytes.first() != Some(&b'W') {
          bail!("invalid widget header");
      }
      let body = std::str::from_utf8(bytes).context("widget body was not valid utf8")?;
      Ok(Widget::from_str(body)?)
  }
  ```
- `rustfmt`/`cargo fmt --check` and `cargo clippy --all-targets` (often `-D warnings`) enforced in CI; 2-space indent via `rustfmt.toml` is the deliberate house style, not default rustfmt (`tab_spaces = 2`, `newline_style = "Unix"`).
- `#![deny(warnings)]` at the crate root for services where that's appropriate.
- Config via `serde` + RON for human-edited files, not JSON/YAML.
  ```rust
  #[derive(serde::Deserialize)]
  struct WidgetConfig { batch_size: u32, endpoint: String }

  impl Default for WidgetConfig {
      fn default() -> Self { ron::from_str(DEFAULT_CONFIG_RON).unwrap() }
  }
  ```
- Time/randomness abstracted behind a trait (e.g. a `ClockSource`) so it can be faked in tests instead of sleeping or relying on real entropy.
  ```rust
  trait ClockSource { fn now(&self) -> Instant; }
  struct RealClock;
  impl ClockSource for RealClock { fn now(&self) -> Instant { Instant::now() } }
  struct TestClock(Cell<Instant>); // advance() manually in tests, never sleep
  ```
- Doc comments (`//!` module docs, `///` on public fns) spell out invariants, panics, and algorithmic guarantees — treated as load-bearing documentation, not boilerplate.
  ```rust
  /// Accumulates stats without a lock; fields update independently, so
  /// cross-field consistency is only guaranteed once writes have quiesced.
  pub struct StreamingStats { ... }
  ```
- Known-answer/round-trip tests as `const` arrays or deterministic hand-rolled PRNGs, preferred over pulling in a fuzzing dependency for small closed-form problems.
  ```rust
  // Verified against the spec, not against the implementation.
  const VECTORS: &[(&[u8], &str)] = &[(b"", ""), (b"f", "Zg=="), (b"fo", "Zm8=")];
  #[test]
  fn encodes_known_vectors() {
      for (input, expected) in VECTORS { assert_eq!(encode(input), *expected); }
  }
  ```
- `#[ignore]`-tag tests that need an external service so `cargo test` stays fast and hermetic by default.
  ```rust
  #[test]
  #[ignore] // requires a running postgres instance
  fn round_trips_through_postgres() { ... }
  ```

### Node.js / TypeScript backend

- Layer "core" libraries by execution environment: environment-agnostic code first, dropping to a Node-only or browser-only layer only when the API genuinely needs it. It's fine for a Node-specific layer to duplicate an environment-agnostic function with a better platform-specific implementation.
  ```
  lib/
    anycore/     # environment-agnostic
    nodecore/    # Node-only, imports from anycore
    webcore/     # browser-only, imports from anycore
    nodesrv/     # server-specific, imports from nodecore
  ```
- Prefer factory functions (`xFactory(...)`) returning an object of bound functions over classes; no DI container — dependencies passed explicitly.
  ```ts
  export const widgetRepositoryFactory = (
    dbProvider: DbProviderType,
    onError: (error: string, details: Record<string, unknown>) => void,
  ): WidgetRepositoryType => {
    const create = async (widget: WidgetType) => { ... };
    const find = async (widgetId: string) => { ... };
    return { create, find };
  };
  ```
- Lightweight tagged error type with a short SCREAMING_SNAKE_CASE code (`throw new AppError("NO_CTX_REQ")`) instead of deep custom exception hierarchies.
  ```ts
  export class AppError extends Error {
    constructor(public code: string, public details?: Record<string, unknown>) {
      super(code);
    }
  }
  // usage:
  if (!ctx.req) throw new AppError("NO_CTX_REQ");
  ```
- A `ctx` object threaded through request handling carries db/session/request state.
  ```ts
  type CtxReqType = { settings: SettingsType; req: RequestInfoType; db: { dbProvider: DbProviderType } };
  const ctxReqFactory = (req: RequestInfoType, dbProvider: DbProviderType, settings: SettingsType): CtxReqType =>
    ({ settings, req, db: { dbProvider } });
  // handlers take `ctx: CtxReqType` instead of pulling globals
  ```
- snake_case filenames, camelCase identifiers, `.type.ts` suffix for pure type-only files, `.test.ts` colocated with source, `.default.ts` suffix for default-config/instance modules.
- Extract generic utilities into small scoped internal packages rather than duplicating inline helpers across services.
- Status/health convention: `/status` (grep-able structured log) plus `/healthz` for liveness.

### Bash / Shell

- Always `set -euo pipefail`.
- Set `MSYS2_ARG_CONV_EXCL="*"` for any script that must also run correctly under Windows/msys2 (msys2 otherwise mangles arguments containing colons, e.g. `C:\path` or Docker image refs).
- Scripts that write/transfer data should be idempotent — use marker/`.done`/`.ctl` files, and only write the completion marker **after** the underlying work is fully done, never before.
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  if [[ ! -d "$dest" && ! -e "$dest.done" ]]; then
    mkdir "$dest"
    extract_archive "$archive" "$dest"
    touch "$dest.done"   # only written once the extraction actually succeeded
  fi
  ```

---

## Frontend

### General frontend guidelines
- Centralize all HTTP/API calls behind one service/module — never hardcode endpoints inline in components.
  ```ts
  export class ApiService {
    constructor(private http: HttpClient) {}
    getWidgets(): Observable<WidgetType[]> { return this.http.get<WidgetType[]>(`${API_URL}/widgets`); }
  }
  ```
- Strong-type API responses; avoid `any`.
- Avoid `Map`/`Set` in component/app state — prefer `Record<K, V>` so state stays trivially JSON-serializable.
  ```ts
  const [featureFlags, setFeatureFlags] = useState<Record<string, boolean>>({});
  ```
- Consistent async UX: disable the triggering control and show a loading indicator during the action; on completion, always clear the loading state and surface errors — no infinite spinners (wrap in try/catch/finally).
  ```ts
  function useActionLoading() {
    const [loading, setLoading] = useState(false);
    const withLoading = <T,>(fn: () => Promise<T>) => async () => {
      setLoading(true);
      try { return await fn(); } finally { setLoading(false); }
    };
    return { loading, withLoading };
  }
  // <Switch disabled={loading} onChange={(_, v) => withLoading(() => updateFlag(key, v))()} />
  ```
- Debounce search inputs; persist meaningful page/filter state in the URL, not only in memory.
  ```ts
  const [searchParams, setSearchParams] = useSearchParams();
  const [query, setQuery] = useState(searchParams.get("q") ?? "");
  const debouncedQuery = useDebouncedValue(query, 150);
  useEffect(() => { fetchResults(debouncedQuery); }, [debouncedQuery]);
  const onChange = (v: string) => {
    setQuery(v);
    setSearchParams(v.trim() ? { q: v } : {}, { replace: true });
  };
  ```
- Route by stable ID, not by display name.
- Environment config is swapped/token-replaced at build or deploy time — never hand-edit a generated environment file.
- Zero-warning lint gate in CI (`--max-warnings=0` style) where a lint step exists.

### React / TypeScript

- Functional components + hooks only; no class components.
- Prefer `type` over `interface`; avoid `class`, prefer closures/functions.
- Named export per component, with an explicit `displayName` set at the bottom of the file.
  ```tsx
  export const PasswordInput = React.forwardRef<HTMLInputElement, PasswordInputProps>((props, ref) => {
    const [visible, setVisible] = React.useState(false);
    const toggle = (e: React.MouseEvent) => { e.preventDefault(); setVisible(v => !v); };
    exportActions(actions, { toggle }); // exposes the handler for tests, no prop-drilling
    return <div className="password-input">...</div>;
  });
  PasswordInput.displayName = "PasswordInput";
  ```
- An `exportActions(actions, {...})` pattern to expose internal handlers for testing without prop-drilling is a useful option for components with complex internal behavior.
- Encapsulate lifecycle-sensitive browser APIs in custom hooks (e.g. a hook wrapping `requestAnimationFrame` that also handles `cancelAnimationFrame` cleanup, or a subscribe-on-mount/unsubscribe-on-unmount transport hook).
  ```tsx
  function useLiveConnection(url: string) {
    const connectionRef = useRef<Connection>();
    useEffect(() => {
      connectionRef.current = connect(url);
      return () => connectionRef.current?.close();
    }, [url]);
  }
  useLiveConnection.displayName = "useLiveConnection";
  ```
- Keep `.tsx` files thin — extract non-trivial logic into plain functions/modules.
- For apps with heavy realtime/interactive needs, consider a single WebSocket-RPC transport for all post-auth data instead of ad hoc REST endpoints — not a universal rule, but worth evaluating.
- Prettier as the formatting gate (a reasonable baseline config: semi, singleQuote, trailingComma all, printWidth 120); a strict typecheck (`tsc -b` or equivalent) as the minimum lint gate where a full linter isn't set up.
- Vite + Vitest (+ Testing Library where present) is a solid modern toolchain default; wire up client-side error monitoring.
- Keep layout sub-panels always visible but disabled rather than conditionally unmounting them.

### Angular

- Feature-module folder convention: `.module.ts` + `-routing.module.ts` + component + `.spec.ts` per feature.
- Centralize all HTTP in an injectable `ApiService` returning `Observable<T>`; put cross-cutting concerns (auth headers, error toasts) in interceptors, not per-call code.
  ```ts
  @Injectable()
  export class AuthInterceptor implements HttpInterceptor {
    intercept(req: HttpRequest<unknown>, next: HttpHandler) {
      return next.handle(req.clone({ setHeaders: { Authorization: `Bearer ${this.token}` } }));
    }
  }
  ```
- Route guards as dedicated classes; lazy-load feature modules.
- Loading state tracked via per-request keys in a shared `LoaderService` so multiple concurrent requests don't clobber each other's spinner state.
  ```ts
  @Injectable({ providedIn: "root" })
  export class LoaderService {
    private active: Record<string, boolean> = {};
    status = new BehaviorSubject<boolean>(false);
    set(key: string, isLoading: boolean) {
      this.active[key] = isLoading;
      this.status.next(Object.values(this.active).some(Boolean));
    }
  }
  ```
- Minimum "should create" (`TestBed` + `HttpClientTestingModule`) smoke test per component is an accepted floor even without deeper coverage.
- `npm audit` must pass for new dependencies; track any necessary exceptions in an explicit allowlist file rather than silently ignoring.

### Blazor

- Render mode is opt-in per component (e.g. `@rendermode InteractiveServer`), not set globally.
  ```razor
  @* WidgetPanel.razor *@
  @rendermode InteractiveServer
  ```
- Component-scoped CSS/JS colocated with the `.razor` file; static assets served via `MapStaticAssets()` / `@Assets[...]`.
  ```
  Components/WidgetPanel.razor
  Components/WidgetPanel.razor.css
  Components/WidgetPanel.razor.js
  ```
  ```razor
  <script src="@Assets["Components/WidgetPanel.razor.js"]"></script>
  ```

---

## Database

Treat this section as close to non-negotiable house style — it's the most consistent set of conventions across engines and stacks.

- **No ORMs.** Write SQL tailored to the specific database engine in use, behind a hand-written code-side abstraction (the repository/data-access layer from `backend-general`) around storage/query concerns — not an ORM's generic query builder or entity-mapping layer. An ORM's abstraction goes the wrong direction for a persisted store: application code has exactly one current view of the schema, while the data itself is read and written by many versions of the code over its lifetime (old rows written by last year's code, new columns not yet backfilled, migrations in flight). An ORM that maps the schema to *today's* code model (the "code-first" style, generating/migrating the schema from entity classes, is the worst offender here) bakes in the assumption that there's one authoritative shape, and it also makes real query-pattern analysis (what's actually hitting the DB, which indexes matter, `EXPLAIN`-driven tuning) much harder, since the SQL is generated rather than written and reviewed.
  Don't stop at just dropping the ORM and keeping a Dapper-style row-to-class mapper, either — that's still the "class as data shape" problem in miniature, just with hand-written SQL in front of it. Read query results defensively into flexible containers (a dictionary/map, a dynamic/JSON-shaped object) rather than mapping rows onto a rigid class, mirroring the "class as data + serialization" guidance in `backend-csharp`: a fixed class shape makes the same one-current-view-vs-many-code-versions mistake at the row level that an ORM makes at the schema level.
- **Never use a bare `id`/`name`/`type`/`status`/`value` column.** Prefix every column with its table/domain name (e.g. `order_id`, `order_status`), so a `SELECT *` or a `JOIN ... USING (col)` is always unambiguous and safe.
- **Singular table names.**
- **`NOT NULL` by default** on every column; nullable is the exception and needs a documented reason. Model true optionality via a separate sub-table (an "extension" table joined 1:1), not a nullable column.
  ```sql
  create table widget (
    widget_id text primary key default (uuidv7()),
    widget_name text not null
  );
  create table widget_1_shipping_detail ( -- optional 1:1 extension, no nullable columns needed on widget
    widget_id text primary key references widget(widget_id) on delete cascade,
    shipping_address text not null
  );
  ```
- **UUIDv7 (DB-generated) primary keys**, not auto-increment integers — avoids enumeration/guessing and accidental cross-table `id` conflation. Where a naming distinction matters: `_id` = DB-assigned UUID, `_identifier` = externally-assigned string, `_mnemonic` = migration/env-assigned string.
  ```sql
  create table widget_1_external_system (
    widget_id text primary key references widget(widget_id) on delete cascade,
    external_system_identifier text not null unique -- assigned by the external system, not us
  );
  create table widget_status ( widget_status_mnemonic text primary key ); -- stable enum key, e.g. 'active'
  ```
- **External ID exposure:** high-entropy IDs (UUIDv7) may be exposed to clients/APIs raw. Only sequential or otherwise-guessable IDs need slug-encoding (`{id}_{id_slug}`) before being exposed externally.
- **Forward-only migrations, no down-migrations.** Roll back via restoring a prior snapshot or shipping a new roll-forward fix — down-migrations are considered inherently unsafe. Migrations are named with strictly increasing real-UTC timestamps and are never edited once committed. Never use `CREATE TABLE IF NOT EXISTS` in a migration (silently no-ops on existing tables) — use explicit `ALTER TABLE`. To restructure without data loss: create a `_new` table, copy, drop old, rename.
  **This requires exclusive access to the table for the duration of the copy.** Any row inserted/updated/deleted in the source table after the copy starts isn't in the new table — the copy is a snapshot, not a live view. Either hold a lock that blocks concurrent writers for the whole operation, or take the application/writers offline for the migration; don't run this pattern against a table still receiving live writes and assume it'll catch up.
  ```
  migrations/20250101T000000Z_20250103T120000Z_rename_widget_status.sql
  ```
  ```sql
  alter table widget rename column widget_type to widget_status_mnemonic;
  alter table widget_x_tag rename column widget_type to widget_status_mnemonic;
  ```
- **Migrations must be idempotent and safely re-runnable** (`INSERT OR IGNORE` / `ON CONFLICT DO ...`), and tested against realistic, already-populated data — not empty tables, which hides real migration bugs.
  ```sql
  insert into widget_status (widget_status_mnemonic)
    values ('pending'), ('active'), ('archived')
    on conflict (widget_status_mnemonic) do nothing;
  ```
- **Lowercase SQL keywords.**
- **No `OFFSET` pagination** — keyset/seek pagination only.
- **Timestamps always `timestamptz`/UTC**; never encode "not yet happened" as a sentinel timestamp — model it as an explicit state/row instead. Use `interval` for durations, not raw `_seconds` integers.
- **Explicit `ON DELETE` policy on every foreign key.**
  ```sql
  widget_id text not null references widget(widget_id) on delete restrict, -- referenced entity, don't cascade
  widget_tag_id text not null references widget(widget_id) on delete cascade -- owned sub-row, cascade
  ```
- **Bulk insert pattern (Postgres): default to `unnest` with bound array parameters.** Avoid row-by-row inserts; transpose the batch into one array per column, bind them as real query parameters (not string-interpolated literal SQL), and zip them back into rows with `unnest` in a single statement — no staging table, one round trip:
  ```ts
  const widgetIds: string[] = [];
  const widgetNames: string[] = [];
  for (const w of batch) {
    widgetIds.push(w.id);
    widgetNames.push(w.name);
  }

  await client.query(
    `insert into widget (widget_id, widget_name)
     select * from unnest($1::uuid[], $2::text[]) as t(widget_id, widget_name)
     on conflict (widget_id) do nothing`,
    [widgetIds, widgetNames],
  );
  ```
  **This must be genuinely bound parameters, not literal arrays built by string interpolation** (`array['a','b',...]`) — a query builder or ORM helper that inlines values as SQL text defeats the whole point: Postgres then pays real parser cost lexing thousands of embedded tokens. Benchmarked locally on Postgres 18 (5 trials/batch size): bound-parameter `unnest` was roughly level with the `COPY`-staging pattern below at 1k-10k row batches and ~30% *faster* at 100k, while the literal-SQL-text version of the same query was 23-44% *slower* than `COPY` at 10k-100k rows. ~10,000 records/batch is a reasonable target size regardless of pattern. Re-verify against your own driver/workload before trusting these numbers at production scale.
  - **Fall back to `COPY FROM STDIN` into a temp staging table** (`ON COMMIT DELETE ROWS`), then `INSERT ... SELECT ... ON CONFLICT DO NOTHING`, when a driver/toolchain doesn't support binding array parameters cleanly, or the data is already arriving as a raw byte/row stream rather than something naturally transposed into column arrays. Each batch-write call should be its own transaction so staging rows can't leak across calls.
  ```rust
  let mut writer = client.copy_in("copy _widget_stage (widget_id, widget_name) from stdin (format text)")?;
  for row in batch { writer.write_all(to_copy_row(row).as_bytes())?; }
  writer.finish()?;
  client.batch_execute(
    "insert into widget (widget_id, widget_name) select widget_id, widget_name from _widget_stage \
     on conflict do nothing")?;
  ```
- **Relation-table naming infixes** (worth adopting where a team needs this level of precision): `_1_` optional 1:1, `_e_` mandatory 1:1 extension, `_n_` one-to-many detail, `_x_` many-to-many crosswalk, `_t_` time-versioned relation (via `valid_for` — see the time-versioned/bitemporal data section below for how corrections and exclusion constraints work on these).
- **Prefer `JOIN ... USING (col)` over `JOIN ... ON a.col = b.col` in Postgres.** This is only possible because of the table-prefixed shared-column-name convention above (a FK column keeps its source table's column name specifically so it lines up for `USING`) — it's more concise, self-documenting, and Postgres automatically folds the duplicate column into one output column instead of returning both sides. Fall back to explicit `ON` only when the join key names genuinely differ (e.g. joining on a non-FK expression) or when the datatypes need an explicit cast.
  ```sql
  select w.widget_name, s.widget_status_mnemonic
  from widget w
    join widget_x_tag using (widget_id)
    join widget_status using (widget_status_mnemonic);
  ```

### Indexing

- **Every foreign key gets an index.** Postgres does not create one automatically for FK columns (only for the referenced primary key) — an un-indexed FK causes slow joins and full-table locks on the parent row during `ON DELETE`/`ON UPDATE` cascade checks.
- **Every column used in a `WHERE`, `JOIN ... USING/ON`, or `ORDER BY` on a non-trivial table should have a deliberate indexing decision** — not necessarily its own single-column index, but a conscious choice (composite index, covered by an existing index's leading columns, or explicitly "not indexed, table is small/rarely queried").
- **Composite indexes**: order columns by selectivity/query pattern — equality-filtered columns first, range-filtered or sorted columns last — so the index can be used for both the filter and the `ORDER BY` in one pass.
  ```sql
  create index ix_widget_event_tenant_at on widget_event (tenant_id, widget_event_at desc);
  ```
- **Partial indexes** (`CREATE INDEX ... WHERE condition`) for columns where queries almost always filter on a narrow, known subset (e.g. `WHERE status = 'active'`, `WHERE deleted_at IS NULL`) — smaller index, faster writes, still fast reads for the common case.
  ```sql
  create unique index ix_widget_n_email_preferred on widget_n_email (widget_id, preferred) where preferred;
  ```
- **Avoid redundant indexes**: a composite index on `(a, b)` already serves queries filtering on `a` alone — don't also add a single-column index on `a`.
- **Don't over-index write-heavy tables.** Every index adds write amplification (insert/update/delete all maintain every index) — justify each index against an actual query pattern, not "just in case."
- **Use `CREATE INDEX CONCURRENTLY` in Postgres for indexes added via migration against a live/populated table** — a plain `CREATE INDEX` takes an exclusive lock that blocks writes for the duration of the build; `CONCURRENTLY` avoids that at the cost of not running inside the migration's own transaction (handle that explicitly in migration tooling).
- **Name indexes explicitly and consistently** (e.g. `ix_<table>_<col[_col2...]>`), not left to the database's auto-generated name — makes them greppable and safe to drop/recreate by name in later migrations.
- **Verify with `EXPLAIN ANALYZE` before assuming an index helped.** Don't add speculative indexes without confirming the planner actually uses them for the query in question — an index that isn't selective enough (e.g. on a low-cardinality boolean) may be ignored by the planner in favor of a sequential scan anyway.

### Time-versioned / bitemporal data (`_t_` tables)

Any time you need to answer both **"what did we say the value was, as of time t"** (a transaction-time question — freeze the audit trail and read what was current then) and **"what is the correct value for time t, given everything we know now"** (a valid-time question — the business fact, possibly corrected after the fact), you have two independent time axes and need to model them separately. Collapsing them into one timestamp/flag is how systems end up with silently wrong "as of" reports after the first correction.

- **Valid time** — modeled as a `[lower, upper)` half-open range column (conventionally named `valid_for`) on the `_t_` table itself, protected by a GiST exclusion constraint so the same entity can never have two overlapping valid periods.
  ```sql
  create table widget_t_price (
    widget_t_price_id uuid primary key default (uuidv7()),
    widget_id uuid not null references widget(widget_id) on delete restrict,
    price numeric not null check (price >= 0),
    valid_for daterange not null default '(,)' check (range_well_formed(valid_for)),
    exclude using gist (widget_id with =, valid_for with &&) -- no two valid periods can overlap
  );
  ```
  `range_well_formed(r)` is a small reusable helper — `(lower(r) is null or lower_inc(r)) and (upper(r) is null or not upper_inc(r))` — enforcing the half-open convention everywhere instead of re-deriving it per table. `daterange` (day granularity) is the default choice even for data that's technically timestamped, since day-level correction/versioning is usually all the business actually needs; reach for `tstzrange` only when sub-day precision is a real requirement, not by default.
- **Scope the exclusion constraint to match the real cardinality** — a plain `(entity_id, valid_for)` exclusion assumes "one valid row per entity"; a join-style `_t_` table relating two entities needs a 3-column exclusion instead, and which side is "the one that must be exclusive at a time" is a modeling decision worth a one-line comment, since the same shape of table can go either way:
  ```sql
  create table household_t_advisor (
    household_t_advisor_id uuid primary key default (uuidv7()),
    household_id uuid not null references household(household_id) on delete restrict,
    advisor_id uuid not null references advisor(advisor_id) on delete restrict,
    valid_for daterange not null default '(,)' check (range_well_formed(valid_for)),
    -- the same household/advisor pair can't have two overlapping valid periods
    exclude using gist (household_id with =, advisor_id with =, valid_for with &&)
  );
  ```
- **The GiST-exclusion technique generalizes to any `anyrange`, not just time** — e.g. a numeric tier band scoped to its owning row:
  ```sql
  exclude using gist (fee_schedule_id with =, tier with &&) -- tier is a numrange
  ```
- **Don't gate the exclusion constraint with a partial `WHERE`** (e.g. `... WHERE not is_deleted`) to let "inactive" rows overlap — it's tempting for soft-delete-style filtering, but a conditional exclusion constraint is easy to get subtly wrong (a row that changes status silently stops being protected). Keep the invariant unconditional on the table; filter status at the query layer instead.
- **Corrections are truncate-the-old-row + insert-the-new-row, never an in-place update of the fact, and never a `superseded_by`/`is_current`/soft-delete flag column.** The exclusion constraint is what makes this safe — the split can't accidentally create an overlap.
  ```sql
  -- correcting the value effective from _as_of onward:
  update widget_t_price
  set valid_for = daterange(lower(valid_for), _as_of)
  where widget_id = _widget_id and valid_for @> _as_of;

  insert into widget_t_price (widget_id, price, valid_for)
  values (_widget_id, _new_price, daterange(_as_of, upper(_old_valid_for)));
  ```
  Wrap this pattern in a single `..._upsert` function per table rather than leaving callers to do the split by hand — a hand-rolled split racing against the exclusion constraint is a common source of bugs. It's fine for this to occasionally leave a zero-width/empty range behind (e.g. via range subtraction, `valid_for = valid_for - _new_range`) rather than compacting — simplicity and correctness win over storage.
- **Transaction time is a separate, generic mechanism — not another column on the `_t_` table.** A schema-wide audit trigger writing to one shared history table (storing only the changed-column diff, tagged with the transaction ID, the acting user, and a `clock_timestamp()`) answers "what did the system record and when" for every table uniformly, decoupled from whatever `valid_for` says about the business fact:
  ```sql
  create table history (
    tx bigint not null,                -- pg_current_xact_id()
    table_name text not null,
    row_id uuid not null,
    changed_by text not null,          -- required; raise if the caller hasn't set it
    recorded_at timestamptz not null default clock_timestamp(),
    op char(1) not null check (op in ('I','U','D')),
    diff hstore                        -- pre-image of changed columns only
  );
  ```
- **Not every "current value over time" need is a full range-versioned table** — for pure status/event tracking (no corrections, only forward progress), a simpler accumulating log where "current" = latest row is enough, and is cheaper to reason about:
  ```sql
  create table widget_activity_n_status (
    widget_activity_id uuid not null references widget_activity(widget_activity_id) on delete cascade,
    widget_activity_status_mnemonic text not null references widget_activity_status,
    changed_by text not null,
    recorded_at timestamptz not null default clock_timestamp()
  );
  -- current status = the row with max(recorded_at) for this widget_activity_id
  ```
- **A container's changing *set* of contents over time** (e.g. "what does this account hold today") is a different shape from a single versioned attribute, and is worth a distinct pattern rather than forcing an `EXCLUDE (container_id, item_id, valid_for)` per item. Model it as a **header `_t_` row per container** (scoped by `(container_id, valid_for)`, exactly like a scalar `_t_` table) holding a **hash of the whole membership set**, plus a satellite child table with the actual members — the child rows carry no `valid_for` of their own; their validity is entirely inherited from the parent header row:
  ```sql
  create table container_t_contents (
    container_t_contents_id uuid primary key default (uuidv7()),
    container_id uuid not null references container(container_id) on delete restrict,
    valid_for daterange not null default daterange(current_date, null) check (range_well_formed(valid_for)),
    contents_hash text not null default '', -- hash of the whole (item_id, quantity) set for this period
    exclude using gist (container_id with =, valid_for with &&)
  );
  create table container_t_contents_n_item (
    container_t_contents_id uuid not null references container_t_contents(container_t_contents_id) on delete cascade,
    item_id uuid not null references item(item_id) on delete restrict,
    quantity numeric not null,
    unique (container_t_contents_id, item_id)
  );
  ```
  On each new snapshot ("container X currently holds {a, b, c}"), hash the whole incoming set and compare it to what's on file **instead of diffing item by item**:
  - Hash matches the header row already (or about to) cover that date → nothing changed; just extend that header row's `valid_for` and touch zero child rows. This is what keeps an unchanged set of contents down to one header row (and one set of children) across however many days it stays unchanged, instead of a row per day.
  - Hash differs → split the header row (or insert the very first one) exactly as in the scalar correction pattern above, then **delete and fully re-insert the entire new set of children** under the (possibly new) header id — even if only one item actually changed.
  ```sql
  -- current contents view: same "latest lower(valid_for) per key" idiom as a scalar _t_ table
  create view container_current_contents as
  with head as (
    select container_id, max(lower(valid_for)) as as_of from container_t_contents group by container_id
  )
  select c.container_id, e.item_id, e.quantity
  from container_t_contents c
    join head using (container_id)
    join container_t_contents_n_item e using (container_t_contents_id)
    where c.valid_for @> head.as_of;
  ```
  **The tradeoff to be explicit about**: collapsing the whole set to one hash is simple and keeps row-churn proportional to "how often the set actually changes," not "how many items it contains" — but it means a single item's addition/removal rewrites *every* child row for that period, and you lose per-item history (you can't ask "when exactly was item X added" without diffing adjacent header periods yourself). If genuine per-item history is a real requirement, track each `(container, item)` pair as its own scoped `_t_` row instead (`EXCLUDE (container_id, item_id, valid_for)`) — see the alternative below.
- **Alternative: per-item `_t_` rows, reconciled by diffing rather than hashing.** Skip the header/child split entirely and give each `(container, item)` pair its own versioned row, with the item folded directly into the exclusion key:
  ```sql
  create table container_t_item (
    container_t_item_id uuid primary key default (uuidv7()),
    container_id uuid not null references container(container_id) on delete restrict,
    item_id uuid not null references item(item_id) on delete restrict,
    quantity numeric not null,
    valid_for daterange not null default daterange(current_date, null) check (range_well_formed(valid_for)),
    exclude using gist (container_id with =, item_id with =, valid_for with &&)
  );
  ```
  On each new snapshot, diff it against the currently-open rows (`upper(valid_for) is null`) for that container instead of hashing the whole set — typically staged via a temp table of the incoming `(item_id, quantity)` pairs, then joined both ways against the open rows:
  - Present in both, same quantity → **untouched**, no write at all.
  - Present in both, changed quantity → close the open row (`upper = _date`) and insert a new open row `[_date, null)` with the new quantity.
  - Present only in the open rows (item dropped) → close the open row, insert nothing.
  - Present only in the new snapshot (item added) → insert a fresh open row `[_date, null)`.

  **Tradeoff vs. the hash-based pattern above**: write amplification now scales with *how many items actually changed*, not "did the set change at all" — a 50-item container with one quantity tick touches 2 rows instead of a full 50-row delete+reinsert, and per-item history ("when was item X added/dropped/resized") falls out for free. The cost is the reconciliation logic itself: a real set-diff against the currently-open rows rather than one hash comparison, and "what does this container hold as of date d" now scans N per-item rows (`where container_id = _id and valid_for @> _d`) instead of one header row joined to its children — still a single indexed query, just a different shape. Prefer this when per-item history is an actual requirement; prefer the hash-based header pattern when the set only needs to be treated as a unit and reconciliation simplicity matters more.
- **Query idioms**: "as of a given date" is ordinary SQL against the range column, not a special abstraction — `join widget_t_price using (widget_id) where valid_for @> _as_of`. "Currently in effect, unqualified by a date" is worth a dedicated view when several consumers need it, resolved via the latest `lower(valid_for)` per key:
  ```sql
  create view widget_current_price as
  with head as (
    select widget_id, max(lower(valid_for)) as as_of from widget_t_price group by widget_id
  )
  select p.* from widget_t_price p
    join head using (widget_id)
    where p.valid_for @> head.as_of;
  ```
  Where a `_t_` table must have **no gaps** across all time for a given key (e.g. "every widget must always have exactly one owning group"), enforce that as an explicit trigger-checked invariant on top of the exclusion constraint — the exclusion constraint alone only prevents overlap, it says nothing about gaps:
  ```sql
  -- raises if the ranges for widget_id don't collapse to exactly '(,)'
  select range_agg(valid_for) = '{(,)}'::datemultirange from widget_t_group where widget_id = _widget_id;
  ```
- **Forward-cascading recompute for a derived running total** — a different correction shape again, for data like a running balance/cache that's *cumulative* rather than a fact or a set: correcting an early value can't be handled by closing/opening one row, because every later cached value was computed on top of it. Instead: delete every cached row from the earliest affected date forward, then walk forward re-summing deltas from the source ledger onto the last surviving value.
  ```sql
  create table account_item_balance_cache (
    account_id uuid not null references account(account_id) on delete restrict,
    item_id uuid not null references item(item_id) on delete restrict,
    as_of_date date not null,
    balance numeric not null,
    primary key (account_id, item_id, as_of_date)
  );

  create function account_item_balance_cache_update(_account_id uuid, _from_date date)
  returns void language plpgsql as $$
  declare _r record; _prev numeric;
  begin
    delete from account_item_balance_cache
    where account_id = _account_id and as_of_date >= _from_date;

    for _r in
      select effective_date, item_id, sum(amount) as delta
      from ledger_entry
      where account_id = _account_id and effective_date >= _from_date
      group by effective_date, item_id
      order by effective_date, item_id
    loop
      select balance into _prev from account_item_balance_cache
        where account_id = _account_id and item_id = _r.item_id and as_of_date < _r.effective_date
        order by as_of_date desc limit 1;

      insert into account_item_balance_cache (account_id, item_id, as_of_date, balance)
      values (_account_id, _r.item_id, _r.effective_date, coalesce(_prev, 0) + _r.delta);
    end loop;
  end;
  $$;
  ```
  **This one deliberately isn't trigger-driven.** A single correction is often a batch of several ledger rows touching the same account, and a per-row `AFTER INSERT` trigger can't cheaply batch "recompute once for the whole correction" — it would redo the forward walk once per row instead of once total. Make the contract explicit instead: whatever wrote the correcting ledger rows is responsible for calling `..._update` once, with the lowest `effective_date` it touched, after all of its writes for that account are committed. Document that contract on the table/function, since it's easy for a future caller to assume triggers have it covered.
- **Frozen "as reported at the time" snapshot** — for anything that gets communicated externally (an invoice, a statement, a regulatory filing), the record must stay fixed once issued even if the bitemporal facts it was computed from are corrected afterward. Don't recompute these live from the `_t_` tables on every read; persist the computed result at computation time, including a copy of any input that could otherwise drift out from under it later:
  ```sql
  create table monthly_fee_statement (
    monthly_fee_statement_id uuid primary key default (uuidv7()),
    account_id uuid not null references account(account_id) on delete restrict,
    statement_month date not null,
    -- captured at issue time, since the account's jurisdiction assignment can change later
    jurisdiction_mnemonic text not null references jurisdiction,
    fee_amount numeric not null,
    created_at timestamptz not null default clock_timestamp(),
    unique (account_id, statement_month)
  );
  ```
  No `valid_for`, no correction-in-place, and deliberately no versioning machinery at all on this table — that absence *is* the point. If a later correction to the source facts means a past statement was wrong, the fix is a new statement for a later period or an explicit adjustment entry, never a silent rewrite of what was already reported; treat this table as append-only, full stop.

### SQLite

SQLite shows up in two distinct roles, and which conventions above apply depends on which one you're in — say which one explicitly rather than leaving it implicit:

- **An ephemeral, rebuildable in-process store** — an in-memory (`:memory:`) or scratch-file database that's fully reconstructed from an external source of truth on every process start (a local mirror/read-model/cache). Nothing here needs to survive a restart, so there's no migration history to protect.
- **The durable, primary store** — a file-backed database that *is* the system of record (a desktop or game app with no server backing it). This one needs the same durability discipline as any production database.

- **Schema bootstrap**: for the ephemeral case, `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` run idempotently on every startup is fine, and is a deliberate, documented exception to the general "never `CREATE TABLE IF NOT EXISTS` in a migration" rule earlier in this section — it's safe specifically because there's no persisted migration history to silently no-op against. For the durable case, that exception does **not** apply: use the same forward-only, explicitly-timestamped migrations as anywhere else. SQLite's `ALTER TABLE` is limited (no `ALTER COLUMN` type change; `DROP`/`RENAME COLUMN` support depends on the SQLite version in use) — the "create a `_new` table, copy, drop, rename" restructure pattern from earlier in this section is the *normal* path here, not a fallback.
  **Foreign keys narrow `ALTER TABLE` further, gated by the `foreign_keys` pragma** (verified against SQLite 3.51): `RENAME COLUMN` is unrestricted either way — SQLite automatically rewrites the FK clause in every other table that references a renamed column. `DROP COLUMN` is where it bites: dropping a column that's the *local* side of an outgoing FK is blocked while `PRAGMA foreign_keys = ON`, but succeeds (and cleanly removes the now-dangling FK clause) with it `OFF`. Dropping a column that's the *target* of another table's FK is usually blocked too, but that's really SQLite's separate "can't drop a `PRIMARY KEY`/`UNIQUE` column" rule — FK targets are almost always one of those — not a rule about FK targets specifically; a plain non-unique column that happens to be pointed at by an FK can be dropped freely. Toggling `foreign_keys` off for a single restructuring migration, in a single transaction, is a reasonable way to get past the outgoing-FK-column case when the "`_new` table, copy, drop, rename" pattern is overkill for a small change.
- **UUIDv7 primary keys are still the default**, but SQLite has no native `uuidv7()` — register one as an application-level function on the connection before running any DML, since SQLite lets you call out to host-language functions from SQL:
  ```ts
  db.function('uuidv7', uuidv7); // uuidv7: () => string, implemented in application code
  ```
  ```sql
  create table if not exists widget (
    widget_id text primary key default (uuidv7()),
    widget_name text not null
  );
  ```
- **Foreign key enforcement is off by default, per connection** — SQLite doesn't persist this in the file, so `PRAGMA foreign_keys = ON` has to run every time a connection opens, not just once at schema-creation time.
- **Upsert idiom**: `INSERT ... ON CONFLICT (...) DO UPDATE SET col = excluded.col, ...` (there's no `MERGE`); `ON CONFLICT (...) DO NOTHING` for idempotent seed/reference-data inserts.
  ```sql
  insert into widget (widget_id, widget_name) values (?, ?)
  on conflict (widget_id) do update set widget_name = excluded.widget_name;

  insert into feature_flag (feature_flag_name, feature_flag_is_enabled) values ('new_ui', 0)
  on conflict do nothing;
  ```
- **No native boolean type** — model as `integer not null default 0` (or `1`), same convention as a Postgres boolean but worth spelling out, since SQLite's dynamic typing/type-affinity won't stop something else from being inserted there. Reach for `STRICT` tables (SQLite ≥ 3.37) on new schemas to get closer to enforced column types instead of relying on affinity alone.
- **Timestamps as ISO-8601 UTC text**, not a native `timestamptz` (SQLite doesn't have one) — `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')` as the default, which stays lexicographically sortable just like a Postgres `timestamptz` column would.
- **No `EXCLUDE`/GiST** — the bitemporal non-overlap invariants from the `database` subject aren't expressible as a table constraint here. Enforce them with a `BEFORE INSERT`/`BEFORE UPDATE` trigger that raises if an overlapping range already exists:
  ```sql
  create trigger widget_t_price_no_overlap
  before insert on widget_t_price
  when exists (
    select 1 from widget_t_price
    where widget_id = new.widget_id
      and valid_from < new.valid_until and new.valid_from < valid_until
  )
  begin
    select raise(abort, 'overlapping valid_for for this widget_id');
  end;
  ```
  (Note the range is necessarily two plain columns, `valid_from`/`valid_until`, rather than a range type — SQLite has no `daterange`/`tstzrange` equivalent either.)
- **Full-text search**: no `tsvector`-equivalent — use an `fts5` virtual table kept in sync via `AFTER INSERT/UPDATE/DELETE` triggers on the source table, rather than adding a search column to the row table itself:
  ```sql
  create virtual table if not exists search using fts5(entity_type, entity_id, display_text, tokenize='trigram');

  create trigger if not exists widget_search_insert after insert on widget begin
    insert into search (entity_type, entity_id, display_text) values ('widget', new.widget_id, new.widget_name);
  end;
  ```
- **Audit trail**: no generic hstore-diff history table like the Postgres pattern in the `database` subject (SQLite has no `hstore`) — the natural analog is a dedicated `_audit` table per source table with its own `AFTER INSERT/UPDATE/DELETE` trigger, denormalizing whatever display fields are useful onto the audit row so a later read doesn't depend on a join against data that may no longer exist:
  ```sql
  create trigger if not exists widget_update_audit after update on widget
  when old.widget_name <> new.widget_name
  begin
    insert into widget_audit (widget_id, action, old_widget_name, new_widget_name, recorded_at)
    values (new.widget_id, 'update', old.widget_name, new.widget_name, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
  end;
  ```
- **Bulk writes**: wrap batches in an explicit transaction. Every statement outside one is its own implicit transaction/fsync in SQLite, which makes row-by-row inserts drastically slower than the equivalent in Postgres.
- **Single-writer model**: SQLite serializes all writers regardless of isolation level. For a file-backed database, turn on WAL mode (`PRAGMA journal_mode = WAL`) so readers aren't blocked by a writer, and set a `busy_timeout` so a second writer blocks-and-retries instead of failing immediately with `SQLITE_BUSY`.
- **`OFFSET` pagination is more tolerable here** than the blanket "no `OFFSET` pagination" rule earlier in this section — SQLite is typically backing a small, locally-bounded table (a local log, a per-user cache), not an internet-scale one, so the usual "gets slower as the offset grows" concern rarely bites in practice. Still prefer keyset pagination once a table's row count isn't known to stay small.
- **Pick `:memory:` vs. a file path deliberately, and say which**: `:memory:` for anything that's purely derived and safe to lose (rebuilt from an external source at process start); a file under a well-known app-data directory for anything that must survive a restart.

### DuckDB

DuckDB is an embedded **columnar/OLAP** engine, not a row-store like SQLite — reach for it over SQLite when the workload is bulk/analytical loading and querying rather than many small transactional writes. It's reasonable to implement the same storage interface against both (e.g. behind one shared `Sink`/repository trait) and benchmark a batch-size sweep across them rather than guess which fits a given ingest workload better.

- **Bundled/statically-linked by default** (e.g. Rust's `duckdb = { version = "1", features = ["bundled"] }`) so there's no runtime dependency on a system DuckDB install — the tradeoff is a slow first build (DuckDB itself compiling in, ~30-60s) with fast incremental builds after; don't mistake that first build for something broken.
- **The native `Appender` API bypasses the SQL parser/planner entirely** and writes straight to columnar storage — the fastest bulk-load path available, faster than any SQL `INSERT`. The sharp edge: because it skips the planner, **column `DEFAULT` expressions are never evaluated for appended rows** — a `default (uuidv7())`-style column default silently does nothing through the Appender. Generate every column's value (including IDs) in application code before appending, the same discipline as the SQLite section's registered `uuidv7()` function, just enforced more strictly here.
- **Stage, then move with a single dedup `INSERT`** — the same staging-table convention as the Postgres `COPY`-then-`INSERT ... ON CONFLICT` pattern earlier in this section, adapted for the Appender:
  ```rust
  // clear staging unconditionally: the Appender's writes are NOT covered by the
  // surrounding transaction, so a prior rollback can't be trusted to have undone them.
  conn.execute_batch("delete from _widget_stage")?;

  let mut app = conn.appender("_widget_stage")?;
  for r in batch { app.append_row(duckdb::params![r.widget_id, r.widget_name])?; }
  app.flush()?; // app must drop/flush before the connection is used again

  conn.execute_batch(
    "insert into widget select * from _widget_stage on conflict do nothing"
  )?;
  ```
  **Transaction note**: only the final `INSERT ... SELECT ... ON CONFLICT` participates in the surrounding `begin`/`commit`/`rollback` — the Appender's writes to the staging table happen outside it. A crash mid-batch leaves the outer transaction uncommitted (so the permanent table stays clean) and the staging table empty on the next connection (temp tables are session-scoped), so dedup on restart/reprocess still holds — but don't assume `rollback` undoes anything the Appender already wrote; that's exactly why staging is cleared unconditionally at the start of every batch rather than trusted to already be empty.
- **Autocommit by default, same as SQLite** — wrap a multi-statement batch in an explicit `begin`/`commit`/`rollback` rather than relying on each statement being its own transaction.
- **Durability is managed internally** — no WAL-mode/`synchronous` pragma tuning to do here, unlike SQLite (see `database-sqlite`). DuckDB's concurrency model targets single-writer analytical workloads, not the many-small-concurrent-writers case SQLite's WAL tuning addresses.
- **Dedup via a plain `unique` constraint + `on conflict do nothing`** — DuckDB supports standard `UNIQUE`/`PRIMARY KEY`/`ON CONFLICT` SQL, so most relational conventions from earlier in this section carry over directly; the Appender bypass above is the one real exception, not the rule.
- **Schema bootstrap** follows the same ephemeral-vs-durable split as `database-sqlite`: `CREATE TABLE IF NOT EXISTS` run idempotently is fine for a rebuildable analytical store; a DuckDB file used as an actual system of record should get the same forward-only, explicitly-timestamped migrations as any other durable database.
- **Foreign keys restrict `ALTER TABLE` far more broadly than in SQLite/Postgres, and asymmetrically by direction** (verified against DuckDB 1.3.1, no pragma to opt out): `ADD COLUMN` is always fine on either side. On the table that *has* the FK, `RENAME COLUMN`/`DROP COLUMN` work on any column except the FK column itself, which is always blocked. On the table an FK *points at*, `RENAME COLUMN`/`DROP COLUMN` are blocked **for every column, including ones with nothing to do with the FK** — the whole table is locked for those operations as long as any other table anywhere in the database has an FK referencing it. There's no pragma to relax this the way SQLite's `foreign_keys = OFF` does — the "create a `_new` table, copy, drop, rename" restructure pattern (or dropping and recreating the referencing FK constraint around the change) is the way through it, not a fallback.
- **Native typed columns are richer than SQLite's** — a real `uuid` column type, plus `bigint`/`blob`/`uinteger`/etc. — but there's still no built-in `uuidv7()` generator, so IDs are still supplied by application code, not a column default (doubly true given the Appender point above).
- **Worth knowing even before you need it**: `read_parquet()`/`read_csv()`/`read_json()` let DuckDB query files directly as tables with no import step at all — reach for that ad hoc, before writing an ingestion pipeline, when the source data already exists as files and the need is analytical/exploratory rather than a durable store.

### DuckLake — time travel for lakehouse tables

**Not used in any project here yet** — this subsection is written from DuckLake's documented design, not from repo evidence like the rest of this file. Treat the syntax as directional, verify it against DuckLake's current docs before relying on it, and replace this with real conventions once a project actually adopts it.

DuckLake is DuckDB Labs' lakehouse table format: table data is still plain Parquet files in object storage (or local disk), but the catalog/metadata — schema, snapshots, file listing — lives in a real transactional SQL database (Postgres, SQLite, or DuckDB itself) instead of the pile of eventually-consistent JSON/Avro metadata files Iceberg/Delta Lake use. The pitch is that a real database is a better fit for concurrent, ACID metadata operations than a metadata layer built out of files.

- **Attach a catalog, then use ordinary SQL.** A single-file form bundles catalog and data together for local/dev use; production separates a durable catalog database from the object-storage data path:
  ```sql
  -- local/dev: catalog + data bundled in one file
  attach 'ducklake:my_lake.ducklake' as lake;

  -- production: catalog in Postgres, data in object storage
  attach 'ducklake:postgres:dbname=lake_catalog host=catalog-db' as lake
    (data_path 's3://my-bucket/lake/');

  use lake;
  create table widget (widget_id uuid primary key, widget_name text not null);
  insert into widget values ((uuidv7()), 'example');
  ```
  Once attached, `CREATE TABLE`/`INSERT`/`UPDATE`/`DELETE` read like ordinary DuckDB SQL — DuckLake handles writing Parquet files and recording the corresponding catalog/snapshot metadata underneath.
- **Every write is a new immutable snapshot** — nothing is mutated or deleted in place at the storage level, which is what makes time travel close to free rather than something to hand-roll:
  ```sql
  select * from widget at (version => 3);
  select * from widget at (timestamp => '2026-01-15 00:00:00');
  select * from ducklake_snapshots('lake'); -- list snapshot ids/timestamps
  ```
  This reconstructs both **rows and schema** as of that snapshot — schema evolution is versioned in the catalog too, not just data.
- **This is transaction-time versioning at the whole-table/catalog level, essentially for free** — the exact concern the generic `history` audit table in the `database` subject solves by hand, one Postgres table at a time. If a table's storage layer is DuckLake, an explicit history table for "what did this look like as of transaction time T" may be redundant with what the engine already gives you — don't build both without a reason to.
- **Retention is not automatic — say so explicitly.** Every snapshot keeps its Parquet files reachable, so storage grows without bound unless old snapshots are deliberately expired and their now-unreferenced files compacted/cleaned up on a schedule:
  ```sql
  call ducklake_expire_snapshots('lake', older_than => now() - interval '30 days');
  call ducklake_cleanup_old_files('lake');
  call ducklake_merge_adjacent_files('lake'); -- compact small files after heavy incremental writes
  ```
  Treat the retention window as a deliberate policy decision (how far back must "as of" queries reach), the same way any other retention/cleanup tool in this document is dry-run-by-default and explicit about what it's discarding.
- **The catalog database is now durability-critical infrastructure**, not an incidental detail — picking Postgres vs. SQLite vs. DuckDB itself as the catalog backend should follow the same ephemeral-vs-durable reasoning as `database-sqlite`/`database-duckdb`: a rebuildable/dev catalog can be disposable, but a production catalog is the one thing that can't be silently lost without losing the ability to reconstruct or time-travel the lake at all.

---

## Infra / CI / CD

- TLS terminates at the gateway/load balancer, never on application VMs directly; certs should be Key-Vault-referenced (or equivalent) with auto-renewal — never a manually-uploaded static cert.
- Immutable, per-build (per-commit) parallel deploys with an explicit, separate promotion/cutover step — never deploy-and-cutover atomically. Prune old deploys with a dry-run-by-default cleanup tool.
  ```
  1. deploy.sh: unpacks {version}-{sha} to its own isolated site/container, binds no live traffic.
  2. promote.sh: health-checks the candidate, then repoints the live-alias binding to it.
     Rollback = re-run promote.sh pointing at the previous (still-installed) sha.
  ```
- Branch naming can drive what gets deployed: a `.../main` branch auto-deploys (optionally to its own preview subdomain); a `.../task/work`-style branch does not, and must merge to its own `main` before that merges further up.
  ```bash
  if [[ "$BRANCH" =~ ^([a-z0-9]+)/main$ ]]; then TARGET="${BASH_REMATCH[1]}"
  elif [[ "$BRANCH" == "main" ]]; then TARGET="main"
  else exit 0; fi # non-main branches never deploy
  ```
- Kubernetes minor-version upgrades must be applied one version at a time — skipping versions breaks the upgrade.
- Secrets are set out-of-band as environment/machine-level variables by an admin — deploy tooling itself never handles secret values.
- A small bundle of local secret files that must travel with the repo goes in a gitignored `./secret/`, packed and AES-256 encrypted to the one committed artifact `./secret.tgz.enc` via `scripts/secret_encrypt.sh`/`secret_decrypt.sh` (passphrase from a `REPO_SECRET` env var) — see `SECRETS.md`.
- No dependencies at the root of an npm workspace/monorepo `package.json` — only shared devDependencies; real deps live in the owning workspace package.
  ```json
  {
    "workspaces": ["lib/*", "app/*", "srv/*"],
    "devDependencies": { "typescript": "^5", "turbo": "^2" }
  }
  ```

---

## Game Development (Godot / GDScript)

- One class per file, filename matches the class; `class_name` + `extends` on the first two lines; typed variables and constants throughout.
  ```gdscript
  class_name Widget
  extends RefCounted

  var widget_id: String = ""
  var hp: int = 100
  ```
- snake_case for files/functions, PascalCase for `class_name`; underscore-prefixed private members (`_dispatch_tick`).
- Scene-root scripts stay thin (wiring/composition only); real logic lives in plain data/model classes.
- Single mutation point per domain (one autoload/singleton owns the canonical state), exposed through verb-named methods that validate preconditions, return early on failure, and only emit a signal after the mutation succeeds. Signals are named past-tense (`inventory_changed`).
  ```gdscript
  # autoload/game_state.gd
  signal widget_status_changed(widget_id: String)

  func complete_widget(widget_id: String) -> void:
      var w = _find(widget_id)
      if w == null:
          return
      w.status = "complete"
      widget_status_changed.emit(widget_id) # only after the mutation succeeds
  ```
- Serialization via a paired `to_dict()` / `static from_dict()`, reading with defensive `.get(key, default)` and `.duplicate()` to avoid aliasing bugs.
  ```gdscript
  func to_dict() -> Dictionary:
      return { "id": widget_id, "traits": traits.duplicate() }

  static func from_dict(d: Dictionary) -> Widget:
      var w := Widget.new()
      w.widget_id = d.get("id", "")
      w.traits = d.get("traits", {}).duplicate()
      return w
  ```
- Errors surfaced via `push_error()` with an actionable message rather than raised exceptions (GDScript convention).
  ```gdscript
  push_error("SaveManager: cannot open %s for writing" % save_path)
  ```
- Testing via GUT (`extends GutTest`, `tests/unit/test_<subject>.gd`, one test file per production script); float comparisons use `assert_almost_eq` with a descriptive message; round-trip serialization tests are a recurring, worthwhile pattern to keep.
  ```gdscript
  extends GutTest

  func test_round_trips_through_dict():
      var w := Widget.new()
      w.hp = 42
      var w2 := Widget.from_dict(w.to_dict())
      assert_eq(w2.hp, w.hp)

  func test_dodge_chance_is_within_tolerance():
      assert_almost_eq(widget.get_dodge_chance(), 0.04, 0.0001, "dodge chance formula drifted")
  ```

---

## Working with AI Coding Assistants

- Review AI-generated code carefully, especially data structures and constraints — don't trust it silently, particularly around anything touching persisted data.
- Be explicit about unstated requirements (e.g. data-preservation rules) — the assistant won't infer them.
- Test AI-suggested migrations/changes against realistic, populated data, not empty tables.
- Keep a persistent, explicit "rules" document that the assistant is pointed at every session, so conventions survive across sessions instead of having to be re-explained (this file is meant to be exactly that).
