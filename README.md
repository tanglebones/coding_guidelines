# Coding Guidelines

Single source of truth for a shared set of coding conventions — general principles plus backend, frontend, database, infra, and game-dev specifics — meant to be pointed at by an AI coding assistant every session so conventions survive across sessions instead of being re-explained. Consumed by other repos as a git submodule (see [SUBMODULE.md](SUBMODULE.md)).

This file is a hand-maintained overview and index. The actual guideline content lives in `subjects/*.md`, one file per area/language, and is never edited through this file.

## Layout

| Path | What it is |
|---|---|
| `subjects/*.md` + `subjects/manifest.tsv` | The guideline content itself, split by subject — canonical source. |
| `GUIDELINES.md` | Generated (`scripts/build-guidelines.sh --subjects all`) — every subject concatenated, this repo's own "consumes everything" copy. Regenerate after editing a fragment via `scripts/update-guidelines.sh`. |
| `scripts/build-guidelines.sh` | Assembles selected subjects (+ their deps) into one combined file. `--list` prints all subject slugs. |
| `scripts/setup-submodule.sh` | Run once from a **consumer** repo to add this repo as a submodule, pick subjects, and generate that repo's own combined guidelines file. |
| `scripts/update-guidelines.sh` | Run from **this** repo after editing a fragment — regenerates `GUIDELINES.md`, then commits/pushes. |
| `scripts/sync-guidelines.sh` | Run periodically from a **consumer** repo — pulls the latest commit here and regenerates that repo's combined file to match. |
| `scripts/secret_encrypt.sh` / `secret_decrypt.sh` | Unrelated to the above — AES-256 encrypt/decrypt a local `./secret/` bundle to the one committed artifact `./secret.tgz.enc`. See [SECRETS.md](SECRETS.md). |
| `SUBMODULE.md` | Full walkthrough of embedding this repo in a consumer repo, including subject selection. |
| `SECRETS.md` | The `./secret/` convention in detail. |

## Subject index

Selectable subjects (pass a comma-list to `--subjects`; `all` selects every one of these). `core-usage`/`core-principles`/`ai-assistants` — the process guidance on how to use this document, language-agnostic principles, and AI-assistant handling — are always included regardless of selection, since they apply no matter the stack.

| Slug | Covers | Depends on |
|---|---|---|
| [`backend-general`](subjects/backend-general.md) | General backend guidelines | |
| [`backend-csharp`](subjects/backend-csharp.md) | C#/.NET | |
| [`backend-rust`](subjects/backend-rust.md) | Rust | |
| [`backend-node`](subjects/backend-node.md) | Node.js / TypeScript backend | |
| [`shell`](subjects/shell.md) | Bash / Shell | |
| [`observability`](subjects/observability.md) | Logging, actor-centric audit/domain events, current-state-vs-transition-log | |
| [`testing`](subjects/testing.md) | Testing philosophy: pyramid shape, real-DB integration tests, smoke-test floor, excluding live-external-dependency tests from the default run | |
| [`frontend-general`](subjects/frontend-general.md) | General frontend guidelines | |
| [`frontend-react`](subjects/frontend-react.md) | React / TypeScript | |
| [`frontend-angular`](subjects/frontend-angular.md) | Angular | |
| [`frontend-blazor`](subjects/frontend-blazor.md) | Blazor | |
| [`database`](subjects/database.md) | Database core conventions, indexing, time-versioned/bitemporal data | |
| [`database-sqlite`](subjects/database-sqlite.md) | SQLite | `database` |
| [`database-duckdb`](subjects/database-duckdb.md) | DuckDB | `database` |
| [`database-ducklake`](subjects/database-ducklake.md) | DuckLake | `database`, `database-duckdb` |
| [`infra`](subjects/infra.md) | Infra / CI / CD | |
| [`game-godot`](subjects/game-godot.md) | Game development (Godot / GDScript) | |

Run `scripts/build-guidelines.sh --list` for the same list read live from `subjects/manifest.tsv`.

## Systems reference

`systems/*.md` is a separate, standalone reference area for guidance that only matters when building one specific subsystem — niche enough that it isn't worth loading every session the way `subjects/*.md` is. These are plain files, not part of `build-guidelines.sh`'s composition pipeline and not selectable via `--subjects`; a consumer repo's `.guidelines/` submodule is a full clone regardless of which subjects it chose, so `.guidelines/systems/*.md` is always present and readable even though it's never concatenated into a combined guidelines file. `core-usage` (always loaded, front position) carries the one pointer that makes these discoverable: check `systems/` for a matching file before starting that specific type of work.

| File | Covers |
|---|---|
| [`systems/login.md`](systems/login.md) | Username/password via challenge-response, OAuth2, SAML, and the session issued once any of them succeeds. |
| [`systems/websocket-api.md`](systems/websocket-api.md) | Building a custom WebSocket-based RPC API: connection lifecycle, message envelope, dispatch, result/error handling, push/subscription, and reconnection resync. |
| [`systems/session-management.md`](systems/session-management.md) | Managing an authenticated session's full lifecycle — issuance, validation, rotation, revocation — independent of which login method or transport is in play. |
| [`systems/background-jobs.md`](systems/background-jobs.md) | Background/scheduled job design: convergence toward a computed target state instead of a sequence of instructions, the multiple-partial-writers anti-pattern, and the externality exception (side effects that can't be converged, e.g. sending an email). |
| [`systems/multi-tenancy.md`](systems/multi-tenancy.md) | Shared-schema tenant isolation: `tenant_id` on every tenant-owned table, users belonging to multiple tenants, per-tenant roles + resource-level ACLs, the "platform"/global-admin pattern, and why filtering-by-convention alone is the biggest real risk. |
| [`systems/file-uploads.md`](systems/file-uploads.md) | Handling user-uploaded files: content validation, direct-to-storage upload via presigned URLs, malware scanning, storage lifecycle/orphan cleanup, and serving uploads back safely. |
| [`systems/sftp.md`](systems/sftp.md) | Exchanging batch files over SFTP: timestamped batch directories, a `done.ctl` completion marker that makes a batch immutable and safe to read, and tiered date directories for an SFTP root used as an archive. |

## Why subject fragments, not Claude Code Skills

This could instead be packaged as a set of Claude Code Skills (one per language/area, or one per project type) rather than plain files. The seam looks similar — both let a consumer pick only the subjects relevant to their stack — but the loading model is different in a way that matters here:

- **Skills load conditionally**, matched by description at the moment a task seems to need them. A guideline that's supposed to be followed automatically, without being asked (see `core-usage` — "Follow every guideline below automatically, without being asked, whenever it applies") depends on actually being in context every session, not on the assistant correctly noticing and invoking the right skill. Miss the match once and that guidance silently never applies — there's no signal that anything was skipped.
- **Subject fragments are static and chosen once**, at `setup-submodule.sh` time, based on what the repo *is* (its stack), not what a given task looks like turn-to-turn. That's a much more stable signal than per-task skill matching, and the combined output is still loaded in full every session like a normal `CLAUDE.md` import — as reliable as loading everything, just scoped to less content.
- Plain markdown files also work with any agent that reads a pointed-at file, not just Claude Code's skill mechanism specifically — consistent with this repo's goal of being consumable by "Claude Code (and any other coding agent)."

If Claude Code's skill-invocation reliability changes, or a use case emerges where per-task (rather than per-repo) selection is actually wanted, this is worth revisiting — but for a set of always-apply house-style conventions, static composition is the safer default.
