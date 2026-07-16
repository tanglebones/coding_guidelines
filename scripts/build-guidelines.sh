#!/usr/bin/env bash
# Assemble one or more subject fragments from subjects/manifest.tsv into a
# single combined guidelines doc. `front`/`back` rows (the §0/§1/§7 process
# guidance) are always included; only `body` rows are selectable. Selecting a
# body subject also pulls in its `deps` (e.g. database-sqlite pulls in
# database) — final order always follows the manifest's canonical row order,
# never the order subjects were listed in. A `---` separator is inserted
# between two emitted fragments only when their `group` column differs;
# fragments in the same group are joined by a single blank line — this
# reproduces GUIDELINES.md's existing separator placement exactly when run with
# --subjects all.
#
# Usage:
#   scripts/build-guidelines.sh --subjects all|<slug>[,<slug>...] --out <path> [--source-dir <dir>]
#   scripts/build-guidelines.sh --list
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd "$script_dir/.." && pwd)/subjects"
subjects=""
out=""
list=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subjects) subjects="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --source-dir) source_dir="$2"; shift 2 ;;
    --list) list=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

manifest="$source_dir/manifest.tsv"
if [[ ! -f "$manifest" ]]; then
  echo "error: manifest not found at $manifest" >&2
  exit 1
fi

# Parallel arrays, one entry per manifest row, in canonical file order.
slugs=(); files=(); positions=(); groups=(); deps=()
while IFS=$'\t' read -r slug file position group dep _desc; do
  [[ "$slug" == \#* || -z "$slug" ]] && continue
  slugs+=("$slug"); files+=("$file"); positions+=("$position"); groups+=("$group"); deps+=("$dep")
done < "$manifest"

if (( list )); then
  awk -F'\t' '!/^#/ && NF { printf "%-20s %s\n", $1, $6 }' "$manifest"
  exit 0
fi

if [[ -z "$subjects" ]]; then
  echo "error: --subjects is required (or pass --list)" >&2
  exit 1
fi
if [[ -z "$out" ]]; then
  echo "error: --out is required" >&2
  exit 1
fi

index_of() {
  local needle="$1" i
  for i in "${!slugs[@]}"; do
    [[ "${slugs[$i]}" == "$needle" ]] && { echo "$i"; return 0; }
  done
  return 1
}

# Resolve requested body slugs (+ transitive deps) to a set of manifest indices.
declare -A selected
if [[ "$subjects" == "all" ]]; then
  for i in "${!slugs[@]}"; do
    [[ "${positions[$i]}" == "body" ]] && selected["$i"]=1
  done
else
  IFS=',' read -ra requested <<< "$subjects"
  worklist=("${requested[@]}")
  while (( ${#worklist[@]} > 0 )); do
    slug="${worklist[0]}"; worklist=("${worklist[@]:1}")
    idx="$(index_of "$slug")" || {
      echo "error: unknown subject '$slug'. Valid subjects:" >&2
      awk -F'\t' '!/^#/ && $3 == "body" { print "  " $1 }' "$manifest" >&2
      exit 1
    }
    [[ -n "${selected[$idx]:-}" ]] && continue
    selected["$idx"]=1
    dep_str="${deps[$idx]}"
    if [[ "$dep_str" != "-" ]]; then
      IFS=',' read -ra dep_list <<< "$dep_str"
      worklist+=("${dep_list[@]}")
    fi
  done
fi

# Emit in canonical manifest order: front rows, selected body rows, back rows.
: > "$out"
prev_group=""
first=1
for i in "${!slugs[@]}"; do
  pos="${positions[$i]}"
  if [[ "$pos" == "body" ]]; then
    [[ -n "${selected[$i]:-}" ]] || continue
  fi
  frag="$source_dir/${files[$i]}"
  if [[ ! -f "$frag" ]]; then
    echo "error: fragment file not found: $frag" >&2
    exit 1
  fi
  if (( ! first )); then
    # Each fragment file already ends in its own trailing newline, so only
    # one more newline is needed to open a blank line (not two).
    if [[ "${groups[$i]}" == "$prev_group" ]]; then
      printf '\n' >> "$out"
    else
      printf '\n---\n\n' >> "$out"
    fi
  fi
  cat "$frag" >> "$out"
  prev_group="${groups[$i]}"
  first=0
done

echo "Wrote $out"
