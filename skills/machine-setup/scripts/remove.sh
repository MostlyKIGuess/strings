#!/usr/bin/env bash
# remove.sh <name> [--force]
# Deletes a machine from index.json. Refuses if it has a `bundleVersion`
# (i.e. install.sh ran successfully) unless --force is passed — that's the
# only persistent signal we keep that says "the remote was actually
# provisioned". Does NOT touch the remote — run uninstall.sh first to clean
# up there.
source "$(dirname "$0")/_common.sh"
ensure_index

name=""
force=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -*)      die "unknown flag: $arg" ;;
    *)       [[ -z "$name" ]] && name="$arg" || die "usage: remove.sh <name> [--force]" ;;
  esac
done

[[ -z "$name" ]] && die "usage: remove.sh <name> [--force]"
[[ "$name" == "local" ]] && die 'cannot remove reserved machine "local"'
machine_exists "$name" || die "no such machine: $name"

if [[ "$force" -ne 1 ]]; then
  bundle="$(machine_field "$name" "bundleVersion")"
  if [[ -n "$bundle" && "$bundle" != "null" ]]; then
    die "$name has bundleVersion=$bundle (run uninstall.sh first or pass --force)"
  fi
fi

updated="$(jq_index --arg n "$name" 'del(.machines[$n])')"
write_index "$updated"

# Clean the dangling ssh socket if any.
sock="$(ssh_sock "$name")"
if [[ -S "$sock" ]]; then
  ssh -O exit -S "$sock" "check-$name" 2>/dev/null || true
  rm -f "$sock"
fi

log "removed machine: $name"
