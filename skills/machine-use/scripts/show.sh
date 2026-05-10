#!/usr/bin/env bash
# show.sh <name> — print full record for one machine.
#
# Reports persistent provisioning record only. Live reachability is the
# renderer's job (boot probe + bridge state); this script does not surface it.
source "$(dirname "$0")/_common.sh"
ensure_index

name="${1:-}"
[[ -z "$name" ]] && die "usage: show.sh <name>"

if [[ "$name" == "local" ]]; then
  jq -n '{name:"local"}'
  exit 0
fi

machine_exists "$name" || die "no such machine: $name"
machine_get "$name" | jq --arg n "$name" '. + {name: $n}'
