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
- **The catalog database is now durability-critical infrastructure** — picking Postgres vs. SQLite vs. DuckDB itself as the catalog backend should follow the same ephemeral-vs-durable reasoning as `database-sqlite`/`database-duckdb`: a rebuildable/dev catalog can be disposable, but a production catalog is the one thing that can't be silently lost without losing the ability to reconstruct or time-travel the lake at all.
