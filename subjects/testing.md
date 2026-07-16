## Testing

A unifying philosophy across the per-language testing conventions already documented elsewhere in this guideline set (NUnit + FakeItEasy in `backend-csharp`, Vitest in `frontend-react`, GUT in `game-godot`, `ClockSource`/`Dep` fakes in `backend-rust`/`backend-csharp`) — this doesn't replace those, it's the shape that should hold across all of them.

### Test pyramid shape

- **Most coverage comes from fast, in-process unit tests** exercising business logic with fakes for anything non-deterministic (clock, randomness, filesystem) — the `Dep`/`ClockSource`-style seams already documented per language exist specifically to make this cheap.
- **A second, smaller layer of integration tests verifies the actual data-access/SQL layer against a real database** — see below; this is not optional given this repo's no-ORM stance.
- **A thin top layer of end-to-end/UI tests** exercises real user flows through the full stack. Keep this the smallest layer on purpose — it's the slowest to run and the most brittle to unrelated changes, so reserve it for the handful of flows that actually need full-stack confidence, not as a substitute for the layers below it.

### Integration tests hit a real database — never a mocked connection

**Given this repo's no-ORM stance — SQL is hand-written and reviewed directly against the target engine, not generated — a mocked DB connection in a test proves the calling code invoked *some* function, and nothing about whether the SQL itself is correct.** A join written wrong, a constraint that doesn't fire, a query that returns the wrong shape — none of that is caught by a fake that just returns canned data regardless of what query was sent. Integration tests for repository/data-access code should run against a real instance of the same engine used in production:

- **SQLite/DuckDB**: cheap — an in-process `:memory:` instantiation per test, the same "ephemeral, rebuildable" case already documented in `database-sqlite`/`database-duckdb`. No separate service needed, and there's no excuse not to do this given how little it costs.
- **Postgres**: a real disposable instance (a test container, or a locally running dev instance reset between runs) — there's no meaningful in-memory substitute that actually exercises Postgres-specific behavior (GiST exclusion constraints, `unnest`, `ON CONFLICT`, partial indexes) faithfully enough to trust.

**What's still fine to fake**: the clock, randomness, the filesystem, and any third-party network dependency — none of those are the thing this repo has a strong, deliberate opinion about writing directly, unlike SQL. Don't extend "test against the real thing" to those; the existing per-language fake-seam patterns are the right call for them.

### An accepted floor even without deep coverage

A trivial "constructs/instantiates without throwing" smoke test is an accepted floor for any class/component that otherwise lacks deeper tests — already the convention in `backend-csharp`'s coverage-gate discussion and `frontend-angular`'s `TestBed` "should create" test, stated here once as a general expectation rather than restated per language.

### Tests requiring a live external dependency

Tag and exclude these from the default fast test run (`backend-rust`'s `#[ignore]`, or the equivalent convention in whatever language is in play) rather than deleting them or letting them flake the default suite — the default test command should stay fast and hermetic by default, while the coverage stays available to run deliberately (e.g. in a scheduled or pre-release CI job).

### Migrations

Already covered in `database` — migrations get tested against realistic, already-populated data, not empty tables, which is what actually surfaces real migration bugs. Not restated here.
