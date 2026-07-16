### SQLite

SQLite shows up in two distinct roles, and which conventions above apply depends on which one you're in — say which one explicitly rather than leaving it implicit:

- **An ephemeral, rebuildable in-process store** — an in-memory (`:memory:`) or scratch-file database that's fully reconstructed from an external source of truth on every process start (a local mirror/read-model/cache). Nothing here needs to survive a restart, so there's no migration history to protect.
- **The durable, primary store** — a file-backed database that *is* the system of record (a desktop or game app with no server backing it). This one needs the same durability discipline as any production database.

- **Schema bootstrap**: for the ephemeral case, `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` run idempotently on every startup is fine, and is a deliberate, documented exception to the general "never `CREATE TABLE IF NOT EXISTS` in a migration" rule earlier in this section — it's safe specifically because there's no persisted migration history to silently no-op against. For the durable case, that exception does **not** apply: use the same forward-only, explicitly-timestamped migrations as anywhere else. SQLite's `ALTER TABLE` is limited (no `ALTER COLUMN` type change; `DROP`/`RENAME COLUMN` support depends on the SQLite version in use) — the "create a `_new` table, copy, drop, rename" restructure pattern from earlier in this section is the *normal* path here.
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
