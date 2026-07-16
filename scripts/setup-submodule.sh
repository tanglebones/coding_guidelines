#!/usr/bin/env bash
# Add coding_guidelines as a submodule of a consumer repo, wire up
# .editorconfig/.gitignore/rustfmt.toml, and generate a combined guidelines
# file from the selected --subjects (see subjects/manifest.tsv, or --list).
# The combined file's name/subjects are recorded in .guidelines-config so
# sync-guidelines.sh can regenerate it later. Dry-run by default — pass
# --execute to apply.
#
# Usage (run from inside the consumer repo, or pass --target):
#   scripts/setup-submodule.sh [--execute] [--target <path>] \
#     [--path <submodule-path>] [--remote <url>] [--branch <branch>] \
#     [--subjects all|<slug>[,<slug>...]] [--file <name>]
#   scripts/setup-submodule.sh --list   # print available subject slugs
#
# --file names the generated combined-guidelines file (default GUIDELINES.md).
# If omitted and running interactively, you'll be prompted for a name. The
# consumer repo's CLAUDE.md is created (or has a line appended) importing it
# via "@<file>" — Claude Code only auto-loads CLAUDE.md itself, not arbitrary
# filenames, so this import line is what actually gets it loaded every
# session. Pass --no-claude-import to skip that and wire it up by hand instead.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
remote="git@github.com:tanglebones/coding_guidelines.git"
branch="main"
submodule_path=".guidelines"
target="$(pwd)"
subjects="all"
file=""
claude_import=1
execute=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) execute=1; shift ;;
    --target) target="$2"; shift 2 ;;
    --path) submodule_path="$2"; shift 2 ;;
    --remote) remote="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --subjects) subjects="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --no-claude-import) claude_import=0; shift ;;
    --list) exec "$script_dir/build-guidelines.sh" --list ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$file" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Guidelines file name [GUIDELINES.md]: " file
  fi
  file="${file:-GUIDELINES.md}"
fi

if ! git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "error: $target is not inside a git repo" >&2
  exit 1
fi
target="$(git -C "$target" rev-parse --show-toplevel)"

echo "Plan:"
echo "  target repo:      $target"
echo "  submodule remote: $remote (branch: $branch)"
echo "  submodule path:   $submodule_path"
echo "  guidelines file:  $file (subjects: $subjects)"

if [[ -e "$target/$submodule_path" ]]; then
  echo "error: $target/$submodule_path already exists — refusing to overwrite" >&2
  exit 1
fi

copy_editorconfig=1
copy_gitignore=1
copy_rustfmt=1
[[ -e "$target/.editorconfig" ]] && copy_editorconfig=0
[[ -e "$target/.gitignore" ]] && copy_gitignore=0
[[ -e "$target/rustfmt.toml" ]] && copy_rustfmt=0

# Copied, not symlinked: a symlinked .gitignore/.editorconfig pointing through
# a submodule boundary trips a real git quirk (spurious "too many levels of
# symbolic links" warnings on some platforms) and breaks outright in CI/clones
# that skip --recurse-submodules. The tradeoff is these copies go stale if the
# submodule is synced later — re-run the `cat` command below when that matters.
if (( copy_editorconfig )); then
  echo "  would copy:      $submodule_path/.editorconfig -> .editorconfig"
else
  echo "  .editorconfig already exists — leaving as-is. To fold in the shared"
  echo "    rules by hand: cat $submodule_path/.editorconfig >> .editorconfig"
fi

if (( copy_gitignore )); then
  echo "  would copy:      $submodule_path/.gitignore -> .gitignore"
else
  echo "  .gitignore already exists — leaving as-is. To fold in the shared"
  echo "    rules by hand: cat $submodule_path/.gitignore >> .gitignore"
fi

if (( copy_rustfmt )); then
  echo "  would copy:      $submodule_path/rustfmt.toml -> rustfmt.toml"
else
  echo "  rustfmt.toml already exists — leaving as-is. To fold in the shared"
  echo "    rules by hand: cat $submodule_path/rustfmt.toml >> rustfmt.toml"
fi

echo "  would generate:  $submodule_path/subjects/{...} -> $file"
if (( claude_import )); then
  echo "  would wire up:   CLAUDE.md to import @$file"
fi

if (( ! execute )); then
  echo
  echo "Dry run only — re-run with --execute to apply."
  exit 0
fi

git -C "$target" submodule add -b "$branch" "$remote" "$submodule_path"

if (( copy_editorconfig )); then
  cp "$target/$submodule_path/.editorconfig" "$target/.editorconfig"
fi
if (( copy_gitignore )); then
  cp "$target/$submodule_path/.gitignore" "$target/.gitignore"
fi
if (( copy_rustfmt )); then
  cp "$target/$submodule_path/rustfmt.toml" "$target/rustfmt.toml"
fi

"$target/$submodule_path/scripts/build-guidelines.sh" \
  --subjects "$subjects" \
  --source-dir "$target/$submodule_path/subjects" \
  --out "$target/$file"

{
  echo "file=$file"
  echo "subjects=$subjects"
} > "$target/.guidelines-config"

if (( claude_import )); then
  import_line="@$file"
  if [[ -f "$target/CLAUDE.md" ]]; then
    grep -qxF "$import_line" "$target/CLAUDE.md" || printf '\n%s\n' "$import_line" >> "$target/CLAUDE.md"
  else
    printf '%s\n' "$import_line" > "$target/CLAUDE.md"
  fi
fi

git -C "$target" add .gitmodules "$submodule_path" "$file" .guidelines-config
(( copy_editorconfig )) && git -C "$target" add .editorconfig
(( copy_gitignore )) && git -C "$target" add .gitignore
(( copy_rustfmt )) && git -C "$target" add rustfmt.toml
(( claude_import )) && git -C "$target" add CLAUDE.md

git -C "$target" commit -m "Add coding_guidelines as a submodule at $submodule_path"

echo
echo "Done. Review the commit, then push it yourself:"
echo "  git -C \"$target\" show --stat HEAD"
echo "  git -C \"$target\" push"
