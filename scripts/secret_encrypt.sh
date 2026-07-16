#!/usr/bin/env bash
# Pack ./secret/ into ./secret.tgz and AES-256 encrypt it to ./secret.tgz.enc
# using the REPO_SECRET env var as the passphrase (see SECRETS.md). Deletes
# the plaintext ./secret.tgz afterward; ./secret/ itself is left untouched.
#
# Usage (run from the repo root):
#   REPO_SECRET=... scripts/secret_encrypt.sh
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ -z "${REPO_SECRET:-}" ]]; then
  echo "error: REPO_SECRET env var is not set" >&2
  exit 1
fi

if [[ ! -d secret ]]; then
  echo "error: ./secret directory not found" >&2
  exit 1
fi

tar czf secret.tgz secret
openssl enc -aes-256-cbc -salt -pbkdf2 -in secret.tgz -out secret.tgz.enc -pass env:REPO_SECRET
rm -f secret.tgz

echo "Wrote secret.tgz.enc — commit it. ./secret/ and ./secret.tgz are gitignored."
