# Using This Repo as a Submodule

This repo (`coding_guidelines`) is meant to be a single source of truth for
`README.md`, `.editorconfig`, and `.gitignore` conventions, shared across many
other repos. The recommended way to embed it is a **git submodule**: each
consumer repo gets a `.guidelines/` folder that is a real, independent clone
of this repo pinned to one commit, plus a couple of files at its own root
that point at it.

Three scripts under `scripts/` cover the whole lifecycle:

| Script | Run it from | Purpose |
|---|---|---|
| `scripts/setup-submodule.sh` | a **consumer** repo, once | Add this repo as a submodule and wire up `.editorconfig`/`.gitignore`. |
| `scripts/update-guidelines.sh` | **this** repo, after editing | Commit and push a guidelines change here. |
| `scripts/sync-guidelines.sh` | a **consumer** repo, periodically | Pull the latest guidelines commit into the submodule and bump the pointer. |

All three are **dry-run by default** — they print the plan and make no
changes until you pass `--execute` (matching the dry-run convention in
`README.md` §1). None of them push a consumer repo's `main` on your behalf;
`sync-guidelines.sh` only commits the submodule-pointer bump locally and
reminds you to review + push.

## One-time setup in a consumer repo

Copy `scripts/setup-submodule.sh` into the consumer repo (or run it straight
from a checkout of this repo, passing `--target <consumer-repo-path>`), then:

```bash
./setup-submodule.sh --execute
```

This:
1. Runs `git submodule add -b main <this-repo-url> .guidelines`.
2. Copies `.guidelines/.editorconfig` → `.editorconfig` and
   `.guidelines/.gitignore` → `.gitignore` at the consumer repo's root,
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
3. Stages and commits the new `.gitmodules`, submodule, and copied files in
   one commit. It does not push — review the commit and push yourself.

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

Edit `README.md` / `.editorconfig` / `.gitignore` in *this* repo as normal,
then from this repo's root:

```bash
scripts/update-guidelines.sh -m "tighten the Rust error-handling guidance" --execute
```

Without `--execute` it just shows `git status`/`git diff` for what would be
committed — use that to sanity-check before committing for real.

## Pulling the latest guidelines into a consumer repo

From the consumer repo's root, periodically (or when you know an update
landed here):

```bash
scripts/sync-guidelines.sh --execute
```

This fetches the submodule's tracked branch (`main`), fast-forwards the
`.guidelines/` pointer to the latest commit, and — only if the pointer
actually moved — commits that bump locally with the range of new guideline
commits in the message. It prints a reminder to push; it never pushes for
you.

## Removing the submodule (if you ever need to)

Submodule removal isn't scripted here since it's rare and destructive.
The manual steps, in order:

```bash
git submodule deinit -f .guidelines
git rm -f .guidelines
rm -rf .git/modules/.guidelines
```

Then remove the `.editorconfig`/`.gitignore` symlinks (or replace them with
real files) if `setup-submodule.sh` created them.
