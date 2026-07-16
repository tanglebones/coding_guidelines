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
- **Relation-table naming infixes are mandatory, not a nice-to-have.** Adopt this from a table's very first migration. By the time a table's relationship shape turns out to need this precision, its plain name is already baked into every query, join, and piece of application code referencing it — a rename at that point is a tractability problem, not a naming exercise. Paying the small naming cost upfront avoids ever facing that migration.

  | Infix | Relationship | Example |
  |---|---|---|
  | `_1_` | Optional 1:1 | `widget_1_shipping_detail` |
  | `_e_` | Mandatory 1:1 extension | `widget_e_billing_detail` |
  | `_n_` | One-to-many detail | `widget_n_email` |
  | `_x_` | Many-to-many crosswalk | `widget_x_tag` |
  | `_t_` | Time-versioned relation (via `valid_for` — see the time-versioned/bitemporal data section below for how corrections and exclusion constraints work on these) | `widget_t_price` |

  **`_1_`/`_e_` (and `_n_`) name an ownership relationship, not just a reference — that's what decides the `ON DELETE` policy from the bullet above, and whether an infix belongs in the name at all.** `widget_1_shipping_detail`/`widget_e_billing_detail` exist solely to extend one `widget` row: nothing else references that row's id, `widget` owns its lifecycle outright, and the FK is `on delete cascade`. A **shared reference** — some `bbb_id` that legitimately shows up as a FK in multiple, unrelated tables — is the opposite case: no single owner, `on delete restrict` (deleting `bbb` while other rows still point to it should fail loudly, not cascade away data those rows still need), and no `_1_`/`_e_`/`_n_` prefix on whichever table holds the reference, since it isn't an owned sub-table relationship at all, just an ordinary FK column.

  **Avoid `_e_` in the common case — a plain `NOT NULL` column added via `ALTER TABLE` requires exactly the same thing at insert time (the value must be supplied on every insert, same as `_e_`), for far less cost: no extra table, no extra join to read it back, no mutual-FK setup.** `_e_` doesn't buy easier inserts; it only buys something when altering the parent table directly isn't viable:
  - the parent table is large/hot enough that the lock `ALTER TABLE` would need is an unacceptable production outage, or
  - `ALTER TABLE` on the parent is itself blocked (e.g. by the FK-driven restrictions documented in the `database-sqlite`/`database-duckdb` subjects).

  **A true `_e_` is mandatory in both directions, not advisory — that's what makes its insert pattern trickier than a plain column.** It isn't just `widget_e_billing_detail.widget_id` FK-ing to `widget` (that alone only stops the extension row from dangling); `widget` also carries a `NOT NULL` FK *back* to `widget_e_billing_detail`, so neither row can exist without the other. That mutual pair is genuinely enforced by the database, unlike a same-transaction insert convention alone — but it also means both rows' keys have to exist simultaneously before either FK can validate, which is why it can't be done as two naive sequential inserts. Verified per engine:
  ```sql
  -- Postgres: pre-generate both ids in a leading CTE, then chain two
  -- data-modifying CTEs. Postgres checks FK constraints at end-of-statement,
  -- not row-by-row, so both rows already exist by the time either FK
  -- validates — no DEFERRABLE needed.
  with ids as (
    select uuidv7() as widget_id, uuidv7() as widget_e_billing_detail_id
  ), new_widget as (
    insert into widget (widget_id, widget_name, widget_e_billing_detail_id)
    select widget_id, 'example', widget_e_billing_detail_id from ids
    returning widget_id
  ), new_detail as (
    insert into widget_e_billing_detail (widget_e_billing_detail_id, widget_id, billing_amount)
    select widget_e_billing_detail_id, widget_id, 0 from ids
    returning widget_e_billing_detail_id
  )
  select * from ids;
  ```
  ```sql
  -- SQLite: no data-modifying CTEs at all (INSERT is not permitted inside
  -- WITH). Pre-generate both ids in application code instead, and defer FK
  -- checking to commit so two ordinary sequential inserts can satisfy each
  -- other's FK within one transaction:
  begin;
  pragma defer_foreign_keys = on;
  insert into widget (widget_id, widget_name, widget_e_billing_detail_id) values (?, 'example', ?);
  insert into widget_e_billing_detail (widget_e_billing_detail_id, widget_id, billing_amount) values (?, ?, 0);
  commit;
  ```
  - **DuckDB: not achievable at the database layer.** DuckDB has no data-modifying CTEs either, checks FK constraints immediately (no deferred/commit-time option), and — as of 1.3.1 — has no `ALTER TABLE ADD CONSTRAINT` to attach the second, reverse FK once both tables already exist. A genuinely bidirectional `_e_` can't be expressed there; treat "mandatory" as an application-level contract only (always write both rows together) if using `_e_` on DuckDB at all.

  Backfilling `_e_` onto an already-large table (the scenario this pattern exists for in the first place) is a separate concern from the insert-time enforcement above — batch it per the bulk-insert/bulk-write guidance already in this section (Postgres: bound-array `unnest`; SQLite: explicit transactions per batch) rather than one long-running statement.
- **Prefer `JOIN ... USING (col)` over `JOIN ... ON a.col = b.col` in Postgres.** This is only possible because of the table-prefixed shared-column-name convention above (a FK column keeps its source table's column name specifically so it lines up for `USING`) — it's more concise, self-documenting, and Postgres automatically folds the duplicate column into one output column instead of returning both sides. Fall back to explicit `ON` only when the join key names genuinely differ (e.g. joining on a non-FK expression) or when the datatypes need an explicit cast.
  ```sql
  select w.widget_name, s.widget_status_mnemonic
  from widget w
    join widget_x_tag using (widget_id)
    join widget_status using (widget_status_mnemonic);
  ```

**Anti-patterns to avoid**

- **EAV (entity-attribute-value) tables** — a generic `(entity_id, attr_name, attr_value)` table to dodge schema changes. Kills type safety, indexing, and query readability; if the shape is genuinely dynamic, that's what a JSON/JSONB column is for, not a hand-rolled schema-less schema.
- **Money/currency stored as `float`/`double`** instead of `numeric`/`decimal` — binary floating point can't represent most decimal fractions exactly, so sums silently drift.
- **Freetext status/type columns instead of a FK-constrained reference table** (the `widget_status_mnemonic` pattern above) — a plain `text` column accepts typos and has no referential integrity; nothing stops `'actvie'` from being inserted.
- **Denormalizing a one-to-many/many-to-many relationship into a JSON array column** instead of a proper `_n_`/`_x_` table — can't index, join, or enforce uniqueness on individual members; directly undercuts the naming-infix convention above.
- **Natural/business keys as primary keys** (email, username, SSN) instead of a surrogate UUID — the natural key can change, and a PK change cascades through every FK referencing it.
- **Reflexive `ON DELETE CASCADE`** applied without checking ownership direction — cascading a delete through a *shared reference* (see the ownership note above) silently destroys data other rows still needed; should have been `RESTRICT`.
- **God tables** — one wide table with dozens of nullable, rarely-populated columns for every entity subtype, instead of `_1_`/`_e_` extension tables — defeats `NOT NULL` by default and makes "which columns actually apply to this row" a runtime guessing game.
- **A cached/derived column with no documented recompute path** — e.g. a running total or aggregate that's written once and never reconciled when its source rows change, silently drifting from the truth (the forward-cascading recompute pattern later in this section is the correct version of this).

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
