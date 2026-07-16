# Local Secrets Convention (`./secret/`)

Repos sometimes need a small bundle of local secret files (certs, API keys,
service-account JSON, etc.) that must never land in git as plaintext but
still need to travel with the repo. The convention here is a single
gitignored directory, packed and AES-256 encrypted to one committed file:

| Path | Tracked in git? | What it is |
|---|---|---|
| `./secret/` | No (gitignored) | Plaintext directory — put whatever files you need in here. |
| `./secret.tgz` | No (gitignored) | Ephemeral intermediate archive — created and deleted by the scripts, never meant to persist. |
| `./secret.tgz.enc` | **Yes** | The only artifact meant to be committed — `secret.tgz` encrypted with AES-256-CBC. |

Two scripts under `scripts/` cover the round trip:

| Script | Purpose |
|---|---|
| `scripts/secret_encrypt.sh` | tars `./secret/` → `./secret.tgz`, encrypts it to `./secret.tgz.enc` with `openssl`, deletes the plaintext `.tgz`. |
| `scripts/secret_decrypt.sh` | decrypts `./secret.tgz.enc` → `./secret.tgz`, untars it to `./secret/`, deletes the plaintext `.tgz`. |

Both require a `REPO_SECRET` environment variable holding the passphrase —
set it out-of-band (shell env, CI secret store), never hardcode it or commit
it anywhere.

## Usage

```bash
# after adding/editing files in ./secret/
REPO_SECRET=... scripts/secret_encrypt.sh
git add secret.tgz.enc
git commit -m "update encrypted secrets"

# on a fresh clone / another machine
REPO_SECRET=... scripts/secret_decrypt.sh
```

`secret_decrypt.sh` refuses to overwrite an existing `./secret/` directory
unless you pass `--force`, so it won't silently clobber local edits that
haven't been re-encrypted yet.

## Why AES-256-CBC via `openssl`, not something fancier

`openssl enc -aes-256-cbc -salt -pbkdf2` needs no extra dependency (`openssl`
is assumed present everywhere these guidelines apply) and a single shared
passphrase is the right shape for "one secret per repo/environment,"
matching how `REPO_SECRET` is meant to be distributed (CI secret store,
password manager, etc.) — this isn't a per-user/multi-recipient scheme.

## Rotating `REPO_SECRET`

There's no in-place re-key: decrypt with the old passphrase, then re-encrypt
with the new one.

```bash
REPO_SECRET="$OLD" scripts/secret_decrypt.sh --force
REPO_SECRET="$NEW" scripts/secret_encrypt.sh
git add secret.tgz.enc
git commit -m "rotate REPO_SECRET"
```
