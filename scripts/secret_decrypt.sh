#!/usr/bin/env bash
# Decrypt ./secret.tgz.enc (AES-256, REPO_SECRET passphrase, see SECRETS.md)
# to ./secret.tgz and unpack it to ./secret/. Refuses to clobber an existing
# ./secret/ unless --force is passed.
#
# Usage (run from the repo root):
#   REPO_SECRET=... scripts/secret_decrypt.sh [--force]
set -euo pipefail

force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ -z "${REPO_SECRET:-}" ]]; then
  echo "error: REPO_SECRET env var is not set" >&2
  exit 1
fi

if [[ ! -f secret.tgz.enc ]]; then
  echo "error: ./secret.tgz.enc not found" >&2
  exit 1
fi

if [[ -d secret && "$force" -eq 0 ]]; then
  echo "error: ./secret already exists — pass --force to overwrite" >&2
  exit 1
fi

openssl enc -d -aes-256-cbc -pbkdf2 -in secret.tgz.enc -out secret.tgz -pass env:REPO_SECRET
rm -rf secret
tar xzf secret.tgz
rm -f secret.tgz

echo "Decrypted secret.tgz.enc -> ./secret/"
