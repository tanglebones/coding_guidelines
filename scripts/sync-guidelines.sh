#!/usr/bin/env bash
# Pull the latest coding_guidelines commit into a consumer repo's submodule
# and commit the pointer bump locally. Dry-run by default — pass --execute
# to actually update and commit. Never pushes on your behalf.
#
# Usage (run from inside the consumer repo):
#   scripts/sync-guidelines.sh [--execute] [--path <submodule-path>]
set -euo pipefail

submodule_path=""
execute=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) execute=1; shift ;;
    --path) submodule_path="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ -z "$submodule_path" && -f .gitmodules ]]; then
  url_key="$(git config -f .gitmodules --get-regexp '\.url$' | awk '/coding_guidelines/{print $1; exit}')"
  if [[ -n "$url_key" ]]; then
    submodule_name="${url_key#submodule.}"
    submodule_name="${submodule_name%.url}"
    submodule_path="$(git config -f .gitmodules --get "submodule.$submodule_name.path")"
  fi
fi
submodule_path="${submodule_path:-.guidelines}"

if [[ ! -d "$submodule_path" ]]; then
  echo "error: submodule path '$submodule_path' not found — pass --path explicitly" >&2
  exit 1
fi

before_sha="$(git -C "$submodule_path" rev-parse HEAD)"

echo "Fetching latest guidelines into $submodule_path ..."
git submodule update --remote --recursive "$submodule_path" >/dev/null

after_sha="$(git -C "$submodule_path" rev-parse HEAD)"

if [[ "$before_sha" == "$after_sha" ]]; then
  echo "Already up to date ($before_sha)."
  # revert the harmless local checkout git submodule update may have touched
  git submodule update "$submodule_path" >/dev/null 2>&1 || true
  exit 0
fi

echo "Plan:"
echo "  $submodule_path: ${before_sha:0:12} -> ${after_sha:0:12}"
echo
echo "New guideline commits:"
git -C "$submodule_path" log --oneline "$before_sha..$after_sha"

if (( ! execute )); then
  echo
  echo "Dry run only — submodule checkout above was fetched but not committed."
  echo "Re-run with --execute to commit the pointer bump."
  git submodule update "$submodule_path" >/dev/null 2>&1 || true
  exit 0
fi

git add "$submodule_path"
git commit -m "chore: sync coding guidelines ${before_sha:0:12}..${after_sha:0:12}"

echo
echo "Committed locally. Review and push when ready:"
echo "  git show --stat HEAD"
echo "  git push"
