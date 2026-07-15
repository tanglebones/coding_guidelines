# Coding Guidelines

Default coding conventions for Claude Code (and any other coding agent) to follow in this environment — general principles plus backend, frontend, database, infra, and game-dev specifics. Trim, merge, or extend as conventions evolve; this is a living reference, not a historical record.

---

## 0. How the Agent Should Use This Document

**These are defaults, not hard rules.** Follow every guideline below automatically, without being asked, whenever it applies to the task at hand. But use judgment about when a guideline doesn't fit — and when it doesn't, don't silently comply and don't silently ignore it either. Instead:

1. **Follow by default.** Apply the relevant guidelines below to any code you write or modify, without waiting to be told.
2. **Flag tension before overriding.** If following a guideline would be actively wrong for the task — it conflicts with an explicit user instruction, contradicts an established pattern already used elsewhere in the codebase, doesn't fit the language/framework/tooling actually in play, or the underlying tradeoff clearly doesn't apply here — stop and ask the user for an explicit exception before proceeding. Say which guideline is in tension and why you think an exception is warranted. Don't guess at whether the user would be fine with it; ask.
3. **User instructions win, but still get flagged.** If the user has explicitly asked for something that conflicts with a guideline, follow the user's instruction — but still call out the conflict rather than silently complying, and document it per rule 4.
4. **Always report and document a deviation, once one happens.** Whether the exception came from the user granting it, from an explicit user instruction, or from your own judgment call in a case too minor to interrupt for:
   - **Tell the user in your response** which guideline was not followed and why.
   - **Leave a short comment in the code at the point of deviation** explaining *why* the guideline wasn't followed — not what the code does. For example: `// Deviates from indexing guidance: no index on this FK — table is <100 rows and never queried by it.`
5. **When genuinely unsure whether a guideline applies**, ask rather than assume either way — silence is never treated as permission to skip a guideline.

---

## 1. General Principles (language-agnostic)

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

---

## 2. Backend

### 2.1 General backend guidelines
- Layer strictly: handlers/controllers never touch data access directly; a repository/data-access layer sits in between.
- Return structured, stable error codes/mnemonics from the API boundary; never leak raw exception details or stack traces to clients. Map error codes centrally on the consuming (frontend) side rather than ad hoc per call site.
- Every mutation of important state should be auditable — either an audit-log table, structured logging, or both — especially for anything with compliance implications.
- Prefer reversible actions (deactivate/soft-delete) over hard deletes where the domain allows it.
- Async all the way — no sync-over-async blocking; wrap unit-of-work/connections in `using`/RAII so they're always released.

### 2.2 C#/.NET

**Formatting & structure**
- 2-space indent, no tabs; braces always required (no single-line `if` without braces); **Allman style** — opening brace on its own line.
- One type per file, filename matches the type name; file-scoped namespaces; directories mirror namespaces (no incidental subfolders).
  ```csharp
  namespace Company.Widgets.Lib;

  public sealed class WidgetSyncRunner : IWidgetSyncRunner
  {
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
- No IoC container. Use a `Dep`/`Deps` static inner-class pattern for test seams: static mutable fields swapped in tests, `Reset()` called in teardown; generic classes get a companion `${Foo}Dep` class.
  ```csharp
  public sealed class WidgetSyncRunner
  {
      internal static class Dep
      {
          public static IFileSystem FileSystem = RealDep.FileSystem;
          public static IClock Clock = RealDep.Clock;
          public static void Reset() { FileSystem = RealDep.FileSystem; Clock = RealDep.Clock; }
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

### 2.3 Rust

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

### 2.4 Node.js / TypeScript backend

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

### 2.5 Bash / Shell

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

## 3. Frontend

### 3.1 General frontend guidelines
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

### 3.2 React / TypeScript

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

### 3.3 Angular

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

### 3.4 Blazor

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

## 4. Database

Treat this section as close to non-negotiable house style — it's the most consistent set of conventions across engines and stacks.

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
- **Bulk insert pattern (Postgres):** avoid row-by-row inserts; for large batches, `COPY FROM STDIN` into a temp staging table (`ON COMMIT DELETE ROWS`), then `INSERT ... SELECT ... ON CONFLICT DO NOTHING`. Each batch-write call should be its own transaction so staging rows can't leak across calls. ~10,000 records/batch is a reasonable target size regardless of backend.
  ```rust
  let mut writer = client.copy_in("copy _widget_stage (widget_id, widget_name) from stdin (format text)")?;
  for row in batch { writer.write_all(to_copy_row(row).as_bytes())?; }
  writer.finish()?;
  client.batch_execute(
    "insert into widget (widget_id, widget_name) select widget_id, widget_name from _widget_stage \
     on conflict do nothing")?;
  ```
- **Relation-table naming infixes** (worth adopting where a team needs this level of precision): `_1_` optional 1:1, `_e_` mandatory 1:1 extension, `_n_` one-to-many detail, `_x_` many-to-many crosswalk, `_t_` time-versioned relation (via `valid_for`).
- **Prefer `JOIN ... USING (col)` over `JOIN ... ON a.col = b.col` in Postgres.** This is only possible because of the table-prefixed shared-column-name convention above (a FK column keeps its source table's column name specifically so it lines up for `USING`) — it's more concise, self-documenting, and Postgres automatically folds the duplicate column into one output column instead of returning both sides. Fall back to explicit `ON` only when the join key names genuinely differ (e.g. joining on a non-FK expression) or when the datatypes need an explicit cast.
  ```sql
  select w.widget_name, s.widget_status_mnemonic
  from widget w
    join widget_x_tag using (widget_id)
    join widget_status using (widget_status_mnemonic);
  ```

### 4.1 Indexing

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

---

## 5. Infra / CI / CD

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
- No dependencies at the root of an npm workspace/monorepo `package.json` — only shared devDependencies; real deps live in the owning workspace package.
  ```json
  {
    "workspaces": ["lib/*", "app/*", "srv/*"],
    "devDependencies": { "typescript": "^5", "turbo": "^2" }
  }
  ```

---

## 6. Game Development (Godot / GDScript)

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

## 7. Working with AI Coding Assistants

- Review AI-generated code carefully, especially data structures and constraints — don't trust it silently, particularly around anything touching persisted data.
- Be explicit about unstated requirements (e.g. data-preservation rules) — the assistant won't infer them.
- Test AI-suggested migrations/changes against realistic, populated data, not empty tables.
- Keep a persistent, explicit "rules" document that the assistant is pointed at every session, so conventions survive across sessions instead of having to be re-explained (this file is meant to be exactly that).

---

## 8. Decisions Log

Record of deliberate calls made when guidance conflicted, kept for context rather than as open questions:

1. **C# test framework**: standardized on NUnit + FakeItEasy.
2. **C# DI-avoidance pattern**: standardized on the `Dep`/`Deps` static inner-class pattern over container-based or ad hoc alternatives.
3. **Brace style**: standardized on Allman (opening brace on its own line) over K&R.
4. **External ID exposure**: standardized on the relaxed rule — high-entropy IDs (UUIDv7) may be exposed raw; only sequential/guessable IDs need slug-encoding.
5. **Rust error handling**: standardized on `anyhow::Result` + `bail!()`/`.context()` everywhere; the hand-rolled-enum / `Rt<T>` alias style is deprecated and should not be used in new code.
