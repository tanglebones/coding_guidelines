# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`coding_guidelines` is a single source of truth for a shared set of coding conventions — general principles plus backend, frontend, database, infra, and game-dev specifics — consumed by other repos as a git submodule. There is no build/lint/test suite; the repo is markdown content plus a handful of bash scripts that assemble and distribute that content.

## Architecture: canonical fragments → generated combined file

The guideline content is **not** hand-edited as one file. It is split into per-subject fragments under `subjects/*.md` (one file per language/area, e.g. `backend-rust.md`, `database-sqlite.md`), driven by `subjects/manifest.tsv`, which lists each fragment's `slug`, `file`, `position` (`front`/`body`/`back`), `group` (controls where a `---` separator is inserted between concatenated fragments), and `deps` (other slugs it depends on, e.g. `database-sqlite` depends on `database`).

- **`subjects/*.md` is the canonical source. Never hand-edit `GUIDELINES.md`** — it's generated output and gets silently overwritten.
- `scripts/build-guidelines.sh --subjects all --out GUIDELINES.md` assembles every subject into this repo's own "everything" copy. `--subjects <slug>[,<slug>...]` assembles a scoped subset (auto-expanding `deps`); `--list` prints all slugs.
- `front`/`back` position rows (`core-usage` = §0 process guidance, `core-principles` = §1 language-agnostic principles, `ai-assistants` = §7) are always included regardless of subject selection — they apply no matter the stack. Only `body` rows are selectable.
- Fragment headings have no numeric prefixes (`## Backend`, not `## 2. Backend`) and cross-references in prose point to subject slugs (e.g. "see the `database` subject") rather than section numbers — this is deliberate: numbered headings/refs break when a consumer repo selects only a subset of subjects.
- `README.md` is hand-maintained (not generated) — it's the human-facing overview, subject index, and the rationale for why this uses static subject-fragment composition rather than Claude Code Skills (see its "Why subject fragments, not Claude Code Skills" section before proposing a Skills-based restructure).

## Making a change

```bash
# 1. Edit the relevant fragment
vim subjects/backend-rust.md

# 2. Regenerate + commit + push (dry-run by default; add --execute to apply)
scripts/update-guidelines.sh -m "tighten the Rust error-handling guidance" --execute
```

`update-guidelines.sh` always regenerates `GUIDELINES.md` from the fragments before diffing/committing, so it can never drift from source.

## The submodule distribution model

Consumer repos embed this repo via `git submodule` at `.guidelines/`, then run `scripts/setup-submodule.sh` once to:
1. Add the submodule and copy `.editorconfig`/`.gitignore`/`rustfmt.toml` to the consumer root (only if it doesn't already have its own — plain copies, not symlinks, since a symlink through a submodule boundary breaks in CI checkouts that skip `--recurse-submodules`).
2. Generate that consumer's own combined guidelines file from `--subjects` (default `all`), naming it via `--file` (prompts interactively if omitted, default `GUIDELINES.md`), and record the choice in `.guidelines-config` so it can be regenerated later.
3. Wire up the consumer's `CLAUDE.md` with an `@<file>` import line — Claude Code only auto-loads `CLAUDE.md` itself, so an arbitrarily-named generated file needs this to actually load every session. `--no-claude-import` skips this.

`scripts/sync-guidelines.sh`, run periodically from a consumer repo, pulls the latest commit into the submodule and regenerates that consumer's combined file from `.guidelines-config` to match.

All four scripts (`setup-submodule.sh`, `build-guidelines.sh`, `update-guidelines.sh`, `sync-guidelines.sh`) are dry-run by default — pass `--execute` to actually change anything. None of them push a consumer repo's `main` on your behalf (`update-guidelines.sh` pushes *this* repo, by design, when run from here).

Full details: `SUBMODULE.md`.

## Unrelated: the `./secret/` convention

`scripts/secret_encrypt.sh` / `secret_decrypt.sh` are unrelated to the guidelines-distribution machinery above — they AES-256 encrypt/decrypt a local `./secret/` directory to the one committed artifact `./secret.tgz.enc`, keyed by a `REPO_SECRET` env var. `./secret/` and the intermediate `./secret.tgz` are gitignored; only `.enc` is committed. Full details: `SECRETS.md`.
