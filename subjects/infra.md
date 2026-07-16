## Infra / CI / CD

- TLS terminates at the gateway/load balancer, never on application VMs directly; certs should be Key-Vault-referenced (or equivalent) with auto-renewal — never a manually-uploaded static cert.
- Immutable, per-build (per-commit) parallel deploys with an explicit, separate promotion/cutover step — never deploy-and-cutover atomically. Prune old deploys with a dry-run-by-default cleanup tool.
  ```
  1. deploy.sh: unpacks {version}-{sha} to its own isolated site/container, binds no live traffic.
  2. promote.sh: health-checks the candidate, then repoints the live-alias binding to it.
     Rollback = re-run promote.sh pointing at the previous (still-installed) sha.
  ```
- Branch naming can drive what gets deployed: a `.../main` branch auto-deploys (optionally to its own preview subdomain); a `.../task/work`-style branch does not, and must merge to its own `main` before that merges further up.
  ```bash
  if [[ "$BRANCH" =~ ^([a-z0-9]+)/main$ ]]; then TARGET="${BASH_REMATCH[1]}"
  elif [[ "$BRANCH" == "main" ]]; then TARGET="main"
  else exit 0; fi # non-main branches never deploy
  ```
- Kubernetes minor-version upgrades must be applied one version at a time — skipping versions breaks the upgrade.
- Secrets are set out-of-band as environment/machine-level variables by an admin — deploy tooling itself never handles secret values.
- A small bundle of local secret files that must travel with the repo goes in a gitignored `./secret/`, packed and AES-256 encrypted to the one committed artifact `./secret.tgz.enc` via `scripts/secret_encrypt.sh`/`secret_decrypt.sh` (passphrase from a `REPO_SECRET` env var) — see `SECRETS.md`.
- No dependencies at the root of an npm workspace/monorepo `package.json` — only shared devDependencies; real deps live in the owning workspace package.
  ```json
  {
    "workspaces": ["lib/*", "app/*", "srv/*"],
    "devDependencies": { "typescript": "^5", "turbo": "^2" }
  }
  ```
