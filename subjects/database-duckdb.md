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
