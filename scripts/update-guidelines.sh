#!/usr/bin/env bash
# Regenerate GUIDELINES.md from subjects/*.md, then commit and push a
# guidelines change from within this (coding_guidelines) repo. Dry-run by
# default — pass --execute to actually commit and push.
#
# Usage:
#   scripts/update-guidelines.sh -m "commit message" [--execute] [--push=no]
set -euo pipefail

message=""
execute=0
push=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message) message="$2"; shift 2 ;;
    --execute) execute=1; shift ;;
    --no-push) push=0; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ -f scripts/build-guidelines.sh ]]; then
  scripts/build-guidelines.sh --subjects all --out GUIDELINES.md
fi

remote_url="$(git remote get-url origin 2>/dev/null || true)"
if [[ "$remote_url" != *coding_guidelines* ]]; then
  echo "warning: origin ($remote_url) doesn't look like the coding_guidelines repo — continuing anyway" >&2
fi

if git diff --quiet && git diff --cached --quiet; then
  echo "Nothing to commit — working tree is clean."
  exit 0
fi

echo "Plan — changes that would be committed:"
git status --short
echo
git --no-pager diff

if (( ! execute )); then
  echo
  echo "Dry run only — re-run with --execute (and -m \"...\") to commit${push:+ and push}."
  exit 0
fi

if [[ -z "$message" ]]; then
  echo "error: --execute requires -m \"commit message\"" >&2
  exit 1
fi

git add -A
git commit -m "$message"

if (( push )); then
  git push
else
  echo "Committed locally (--no-push given) — push it yourself when ready."
fi
