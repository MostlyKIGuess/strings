#!/usr/bin/env bash
# list.sh — print all machines as a JSON array (including the reserved "local" row).
#
# Reports persistent provisioning record only. Live reachability is the
# renderer's job (boot probe + bridge state); this script does not surface it.
source "$(dirname "$0")/_common.sh"
ensure_index

jq_index '
  [{name: "local", host: null, bundleVersion: null}]
  + (.machines | to_entries | map({
      name:          .key,
      host:          (.value.ssh.host // null),
      bundleVersion: (.value.bundleVersion // null)
    }))
'
