# Using This Repo as a Submodule

This repo (`coding_guidelines`) is meant to be a single source of truth for
coding conventions, `.editorconfig`, `.gitignore`, and `rustfmt.toml`, shared
across many other repos. The recommended way to embed it is a **git
submodule**: each consumer repo gets a `.guidelines/` folder that is a real,
independent clone of this repo pinned to one commit, plus a couple of files
at its own root that point at it.

Four scripts under `scripts/` cover the whole lifecycle:

| Script | Run it from | Purpose |
|---|---|---|
| `scripts/setup-submodule.sh` | a **consumer** repo, once | Add this repo as a submodule, wire up `.editorconfig`/`.gitignore`/`rustfmt.toml`, and generate that repo's own combined guidelines file from selected subjects. |
| `scripts/build-guidelines.sh` | anywhere, as needed | Assemble selected `subjects/*.md` into one combined file. Used internally by the other three scripts; `--list` prints available subject slugs. |
| `scripts/update-guidelines.sh` | **this** repo, after editing | Regenerate `GUIDELINES.md`, then commit and push a guidelines change here. |
| `scripts/sync-guidelines.sh` | a **consumer** repo, periodically | Pull the latest guidelines commit into the submodule, bump the pointer, and regenerate the consumer's combined file to match. |

All four are **dry-run by default** — they print the plan and make no
changes until you pass `--execute` (matching the dry-run convention in
`GUIDELINES.md` §1). None of them push a consumer repo's `main` on your
behalf; `sync-guidelines.sh` only commits the submodule-pointer bump locally
and reminds you to review + push.

## Choosing subjects

The guideline content is split into per-area/language fragments under
`subjects/*.md` (see the subject index in `README.md`), rather than one
monolithic file — see `README.md`'s "Why subject fragments, not Claude Code
Skills" section for the reasoning. Each consumer repo selects only the
subjects it actually uses:

```bash
scripts/setup-submodule.sh --execute --subjects backend-rust,database,infra
```

`--subjects all` (the default) includes everything. `scripts/build-guidelines.sh
--list` prints all available slugs. Selecting a subject with dependencies
(e.g. `database-sqlite` depends on `database`) automatically pulls those in
too — the `§0`/`§1`/`§7` process guidance is always included regardless of
selection, since it applies no matter the stack.

## One-time setup in a consumer repo

Copy `scripts/setup-submodule.sh` into the consumer repo (or run it straight
from a checkout of this repo, passing `--target <consumer-repo-path>`), then:

```bash
./setup-submodule.sh --execute --subjects <slug>[,<slug>...]
```

Omit `--subjects` to get everything, or omit `--file` to be prompted
interactively for the combined file's name (default `GUIDELINES.md`).

This:
1. Runs `git submodule add -b main <this-repo-url> .guidelines`.
2. Copies `.guidelines/.editorconfig` → `.editorconfig`,
   `.guidelines/.gitignore` → `.gitignore`, and
   `.guidelines/rustfmt.toml` → `rustfmt.toml` at the consumer repo's root,
   **only if the consumer repo doesn't already have its own**. If it already
   has one, the script leaves it alone and prints the one-line `cat` command
   to fold the shared rules in by hand — automatically merging into an
   existing file would risk silently dropping repo-specific entries.

   These are plain copies, not symlinks: a symlink into a submodule trips a
   real git quirk (spurious "too many levels of symbolic links" warnings on
   some platforms) and breaks outright in a CI checkout or clone that skips
   `--recurse-submodules`. The tradeoff is the copies go stale if the
   submodule is synced later — re-run the `cat` command above (or just
   re-copy the file) after a `sync-guidelines.sh` if you want the root files
   to pick up a change.
3. Generates the combined guidelines file (e.g. `GUIDELINES.md`) from the
   selected subjects, and records the filename + subject list in
   `.guidelines-config` at the consumer repo's root so `sync-guidelines.sh`
   knows what to regenerate later.
4. Wires up `CLAUDE.md` to actually load it: appends an `@<file>` import line
   (creating `CLAUDE.md` if it doesn't exist yet). This step exists because
   Claude Code only auto-loads `CLAUDE.md` itself — an arbitrarily-named file
   sitting at the repo root is otherwise never read automatically. Pass
   `--no-claude-import` to skip this and wire it up by hand instead.
5. Stages and commits the new `.gitmodules`, submodule, generated file,
   `.guidelines-config`, and (unless skipped) `CLAUDE.md` in one commit. It
   does not push — review the commit and push yourself.

Fresh clones of the consumer repo need submodules initialized explicitly:

```bash
git clone --recurse-submodules <consumer-repo-url>
# or, after a plain clone:
git submodule update --init --recursive
```

CI pipelines need the same `--recurse-submodules` (or an explicit
`git submodule update --init` step) or the `.guidelines/` folder will check
out empty.

## Changing a guideline

Edit the relevant `subjects/*.md` fragment / `.editorconfig` / `.gitignore` /
`rustfmt.toml` in *this* repo as normal (never hand-edit `GUIDELINES.md` —
it's generated and gets overwritten), then from this repo's root:

```bash
scripts/update-guidelines.sh -m "tighten the Rust error-handling guidance" --execute
```

Without `--execute` it just shows `git status`/`git diff` for what would be
committed — use that to sanity-check before committing for real.

### Editing directly from within a consumer repo's submodule checkout

`.guidelines/` inside a consumer repo is a real, independent git repo (its
own `.git` file, remote, and branch) — `scripts/update-guidelines.sh` works
unmodified from inside it, since `git rev-parse --show-toplevel` correctly
resolves to the submodule's own root, not the consumer repo's. Run it from
`<consumer-repo>/.guidelines` exactly as above; it commits and pushes to
*this* repo's remote, not the consumer repo's.

**One extra step afterward**: the consumer repo still has the *old* commit
recorded as its submodule pointer, so it now shows `.guidelines` as
"modified" — a fresh clone of the consumer repo would check out the old
commit until that's fixed. Commit the bump in the consumer repo too:

```bash
cd <consumer-repo-root>
git add .guidelines
git commit -m "chore: bump coding_guidelines pointer"
git push
```

(`scripts/sync-guidelines.sh` is built for the opposite direction — pulling
something already pushed to origin into a stale local submodule — so it's
not quite the right tool for this "I just edited in place" case; a plain
manual commit is simplest here.)

## Pulling the latest guidelines into a consumer repo

From the consumer repo's root, periodically (or when you know an update
landed here):

```bash
scripts/sync-guidelines.sh --execute
```

This fetches the submodule's tracked branch (`main`), fast-forwards the
`.guidelines/` pointer to the latest commit, and — only if the pointer
actually moved — regenerates the combined guidelines file recorded in
`.guidelines-config` (if `setup-submodule.sh` was used to opt into one) from
the updated fragments, then commits the pointer bump + regenerated file
locally. It prints a reminder to push; it never pushes for you. Repos that
predate `.guidelines-config` (or never opted in) just get the pointer bump,
unchanged from before.

## Removing the submodule (if you ever need to)

Submodule removal isn't scripted here since it's rare and destructive.
The manual steps, in order:

```bash
git submodule deinit -f .guidelines
git rm -f .guidelines
rm -rf .git/modules/.guidelines
```

Then remove the `.editorconfig`/`.gitignore`/`rustfmt.toml`/combined
guidelines file/`.guidelines-config` at the consumer repo's root if
`setup-submodule.sh` created them there and nothing else has since started
relying on them, and drop the `@<file>` import line from `CLAUDE.md`.
