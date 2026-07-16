### Bash / Shell

- Always `set -euo pipefail`.
- Set `MSYS2_ARG_CONV_EXCL="*"` for any script that must also run correctly under Windows/msys2 (msys2 otherwise mangles arguments containing colons, e.g. `C:\path` or Docker image refs).
- Scripts that write/transfer data should be idempotent — use marker/`.done`/`.ctl` files, and only write the completion marker **after** the underlying work is fully done, never before.
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  if [[ ! -d "$dest" && ! -e "$dest.done" ]]; then
    mkdir "$dest"
    extract_archive "$archive" "$dest"
    touch "$dest.done"   # only written once the extraction actually succeeded
  fi
  ```
