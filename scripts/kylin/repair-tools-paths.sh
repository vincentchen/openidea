#!/usr/bin/env bash
# Rewrites the absolute paths an installed tool tree remembers, after the tree
# was moved.
#
# Python virtualenvs record where their interpreter lives (the `bin/python`
# symlink, `pyvenv.cfg` and every script's `#!` line), so a tools directory
# built in one place and unpacked in another keeps pointing at the old one.
# The offline language pack is built under a temporary directory and used from
# wherever the user unpacked it, so it calls this once per location.
#
# Usage: repair-tools-paths.sh [root]
#
# `root` is the directory that holds `data/` (default: the parent of this
# script). It must contain `data/.openidea-pack-root`, the path the tree was
# built at; that file is rewritten to `root` afterwards, so moving the tree
# again repairs from the new location.
set -euo pipefail

root=${1:-}
if [ -z "$root" ]; then
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fi
root=$(cd -- "$root" && pwd -P)

stamp="$root/data/.openidea-pack-root"
[ -f "$stamp" ] || exit 0
old=$(cat "$stamp")
[ -n "$old" ] || exit 0
[ "$old" = "$root" ] && exit 0

log() { printf '  %s\n' "$*" >&2; }
log "moving tool paths from $old to $root"

# sed replacement text: `|` delimits, `&` and `\` are special on the right side.
escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
old_re=$(escape "$old")
new_re=$(escape "$root")

# Only small files remember the prefix: venv scripts, pyvenv.cfg and the
# wrapper scripts next to a server. The multi-hundred-megabyte payloads do not,
# so they are never read.
shopt -s nullglob
candidates=(
  "$root"/data/tools/*/venv/pyvenv.cfg
  "$root"/data/tools/*/venv/bin/*
  "$root"/data/tools/*/bin/*
  "$root"/data/tools/*/lib/*.pth
)
shopt -u nullglob
mapfile -d '' files < <(
  [ ${#candidates[@]} -gt 0 ] && grep -lIZ -F -- "$old" "${candidates[@]}" 2>/dev/null || true
)
if [ "${#files[@]}" -gt 0 ]; then
  sed -i -e "s|$old_re|$new_re|g" -- "${files[@]}"
fi
# Note: `grep` found nothing is not an error, so the script cannot just `set -e` on the pipeline.
log "rewrote ${#files[@]} file(s)"

# Virtualenv interpreters are symlinks into the runtime, also absolute.
links=0
while IFS= read -r -d '' link; do
  target=$(readlink -- "$link")
  case "$target" in
    "$old"/*)
      ln -sfn -- "$root${target#"$old"}" "$link"
      links=$((links + 1))
      ;;
  esac
done < <(find "$root/data" -type l -print0 2>/dev/null)
log "repointed $links symlink(s)"

printf '%s\n' "$root" > "$stamp"
