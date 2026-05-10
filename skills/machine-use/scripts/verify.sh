#!/usr/bin/env bash
# verify.sh — laptop-side health probe for a machine.
#
#   - Read-only. Never mutates the index.
#   - Used as the last gate of install.sh / install-claude.sh / install-codex.sh,
#     by the renderer's machine selector boot probe (every 20 s), and for
#     manual diagnostics.
#   - Three calling patterns:
#       1. --kimi-port P --plane-port P given → probe forwarded ports, via=bridge.
#       2. No flags, ports.json fresh    → read snapshot, via=bridge.
#       3. Otherwise / fallback          → ssh exec to remote loopback, via=remote-loopback.
#   - With --deep, also probes plane's upstream dependency: the SPOT backend
#     at the remote's auth.json base_url. The fast probes only cover whether
#     plane is *running*; a deep probe answers whether plane can do useful
#     work (backend reachable + token accepted).
#
# Usage:
#   verify.sh <name> [--kimi-port P] [--plane-port P] [--deep]
#
# Output (stdout, single JSON):
#   {"ok":bool,"name":"...","via":"bridge|remote-loopback",
#    "ssh":{"ok":bool},"kimi":{"ok":bool,"latencyMs":N},"plane":{...},
#    "backend":{                                  // present only with --deep
#      "baseUrl":         "<url|null>",
#      "reachableFromRemote": true|false|null,    // remote → backend root
#      "authValid":      true|false|null,         // 200 from /auth/user
#      "statusCode":     401|521|...|null,        // last status from /auth/user
#      "message":        "ok|authentication failed (401)|backend unreachable from remote|..."
#    },
#    "verifiedAt":"..."}
#
# Gate is **plane only** — plane is the supervisor and the renderer's
# selectability signal. ssh / kimi / backend results are returned for
# diagnostics but do not affect ok / exit code.
#
# Exit codes:
#   0  ok=true  (plane /healthz returned 200)
#   1  ok=false
#   2  arg error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_TAG="machine-use" source "$SCRIPT_DIR/../../_lib/provisioning.sh"

# ── parse args ───────────────────────────────────────────────────────────────

NAME=""
KIMI_PORT=""
PLANE_PORT=""
DEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kimi-port)  KIMI_PORT="$2"; shift 2 ;;
    --plane-port) PLANE_PORT="$2"; shift 2 ;;
    --deep)       DEEP=1; shift ;;
    -h|--help)
      echo "usage: verify.sh <name> [--kimi-port P] [--plane-port P] [--deep]" >&2
      exit 0 ;;
    --*)
      printf '{"ok":false,"stage":"parse-args","message":"unknown flag: %s"}\n' "$1"
      exit 2 ;;
    *)
      if [[ -z "$NAME" ]]; then NAME="$1"; else
        printf '{"ok":false,"stage":"parse-args","message":"unexpected positional: %s"}\n' "$1"
        exit 2
      fi
      shift ;;
  esac
done

if [[ -z "$NAME" ]]; then
  printf '{"ok":false,"stage":"parse-args","message":"missing <name>"}\n'
  exit 2
fi

PROVISIONING_NAME="$NAME"
export PROVISIONING_NAME

# ── port resolution: flags > snapshot > remote-loopback ──────────────────────

VIA="remote-loopback"
PORTS_SNAPSHOT="$SSH_DIR/$NAME.ports.json"
SNAPSHOT_FRESH_SECS=300

if [[ -n "$KIMI_PORT" && -n "$PLANE_PORT" ]]; then
  VIA="bridge"
elif [[ -f "$PORTS_SNAPSHOT" ]]; then
  # Fresh enough?
  local_now="$(date +%s)"
  snap_mtime="$(stat -c %Y "$PORTS_SNAPSHOT" 2>/dev/null || echo 0)"
  if (( local_now - snap_mtime <= SNAPSHOT_FRESH_SECS )); then
    KIMI_PORT="$(jq -r '.kimi // empty' "$PORTS_SNAPSHOT" 2>/dev/null || true)"
    PLANE_PORT="$(jq -r '.plane // empty' "$PORTS_SNAPSHOT" 2>/dev/null || true)"
    if [[ -n "$KIMI_PORT" && -n "$PLANE_PORT" ]]; then
      VIA="bridge"
    fi
  else
    emit_progress warn "ports-snapshot" "ports.json is stale (>${SNAPSHOT_FRESH_SECS}s); falling back to remote-loopback"
  fi
fi

# ── helpers ──────────────────────────────────────────────────────────────────

probe_localhost_healthz() {
  local port="$1"
  local started ended status
  started="$(date +%s%3N)"
  if status=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/healthz" 2>/dev/null); then
    ended="$(date +%s%3N)"
    if [[ "$status" == "200" ]]; then
      printf '{"ok":true,"latencyMs":%d}' "$((ended - started))"
      return 0
    fi
  fi
  printf '{"ok":false,"latencyMs":null}'
  return 1
}

probe_remote_healthz() {
  local port="$1"
  local started ended out
  started="$(date +%s%3N)"
  if out=$(ssh_run "$NAME" -q -- "curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$port/healthz" 2>/dev/null); then
    ended="$(date +%s%3N)"
    if [[ "$out" == "200" ]]; then
      printf '{"ok":true,"latencyMs":%d}' "$((ended - started))"
      return 0
    fi
  fi
  printf '{"ok":false,"latencyMs":null}'
  return 1
}

# Deep probe: SSH into the remote, read its auth.json, and probe the upstream
# SPOT backend for (a) reachability of the base_url root and (b) acceptance of
# the token at GET /auth/user. The whole thing runs in one ssh_run round-trip
# via bash -s + stdin to avoid quoting the token through argv.
probe_backend_from_remote() {
  local script_output
  if ! script_output=$(ssh_run "$NAME" -q -- bash -s <<'REMOTE_PROBE' 2>/dev/null
set -u
AUTH=~/.openscientist/auth.json
if [ ! -f "$AUTH" ]; then
  printf 'MISSING_AUTH\n'
  exit 0
fi
BASE_URL=$(jq -r '.base_url // empty' "$AUTH" 2>/dev/null || true)
TOKEN=$(jq -r '.token // empty' "$AUTH" 2>/dev/null || true)
if [ -z "$BASE_URL" ]; then
  printf 'NO_BASE_URL\n'
  exit 0
fi
# Probe 1: root reachability (no auth).
ROOT_CODE=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$BASE_URL/" 2>/dev/null || printf '000')
# Probe 2: auth-validating endpoint.
if [ -n "$TOKEN" ]; then
  AUTH_CODE=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$BASE_URL/auth/user" 2>/dev/null || printf '000')
else
  AUTH_CODE='no_token'
fi
printf 'BASE_URL=%s\n' "$BASE_URL"
printf 'ROOT_CODE=%s\n' "$ROOT_CODE"
printf 'AUTH_CODE=%s\n' "$AUTH_CODE"
REMOTE_PROBE
  ); then
    jq -nc '{baseUrl:null, reachableFromRemote:null, authValid:null, statusCode:null, message:"ssh exec failed"}'
    return
  fi

  case "$script_output" in
    *MISSING_AUTH*)
      jq -nc '{baseUrl:null, reachableFromRemote:null, authValid:null, statusCode:null, message:"no auth.json on remote — re-run install.sh"}'
      return ;;
    *NO_BASE_URL*)
      jq -nc '{baseUrl:null, reachableFromRemote:null, authValid:null, statusCode:null, message:"auth.json on remote has no base_url"}'
      return ;;
  esac

  local base_url root_code auth_code
  base_url=$(printf '%s\n' "$script_output" | sed -n 's/^BASE_URL=//p' | head -1)
  root_code=$(printf '%s\n' "$script_output" | sed -n 's/^ROOT_CODE=//p' | head -1)
  auth_code=$(printf '%s\n' "$script_output" | sed -n 's/^AUTH_CODE=//p' | head -1)

  # Reachable: any 1xx/2xx/3xx is fine; 4xx/5xx still counts as "the server
  # is up enough to answer" UNLESS it's a Cloudflare 5xx where the host is
  # marked down — we treat 502/503/521/522/523/524 as unreachable.
  local reachable
  case "$root_code" in
    1??|2??|3??|401|403|404) reachable="true" ;;
    502|503|521|522|523|524|000) reachable="false" ;;
    *)                           reachable="false" ;;
  esac

  local auth_valid auth_msg
  case "$auth_code" in
    200)              auth_valid="true";  auth_msg="ok" ;;
    401|403)          auth_valid="false"; auth_msg="authentication failed ($auth_code) — token expired or invalid; refresh with install.sh" ;;
    no_token)         auth_valid="null";  auth_msg="no token in remote auth.json — re-run install.sh" ;;
    000)              auth_valid="null";  auth_msg="backend unreachable from remote — network or DNS issue" ;;
    5??)              auth_valid="null";  auth_msg="backend returned $auth_code (server-side issue, not the agent's job)" ;;
    *)                auth_valid="null";  auth_msg="auth probe got HTTP $auth_code" ;;
  esac

  jq -nc --arg b "$base_url" --argjson reach "$reachable" \
    --argjson av "$auth_valid" --arg sc "$auth_code" --arg m "$auth_msg" \
    '{baseUrl:$b, reachableFromRemote:$reach, authValid:$av,
      statusCode:(if $sc == "no_token" or $sc == "000" then null else ($sc|tonumber? // null) end),
      message:$m}'
}

# ── stages ───────────────────────────────────────────────────────────────────

# 1. ssh-master (informational; plane reachability is the gate)
ssh_ok=false
if ssh_master_alive "$NAME"; then ssh_ok=true; fi

# 2/3. plane (primary) + kimi (informational) healthz
kimi_json='{"ok":false,"latencyMs":null}'
plane_json='{"ok":false,"latencyMs":null}'

if [[ "$ssh_ok" == "true" ]]; then
  if [[ "$VIA" == "bridge" ]]; then
    if k=$(probe_localhost_healthz "$KIMI_PORT") 2>/dev/null; then kimi_json="$k"; fi
    if p=$(probe_localhost_healthz "$PLANE_PORT") 2>/dev/null; then plane_json="$p"; fi
    # Auto-fallback if the bridge probes both failed.
    if [[ "$(jq -r '.ok' <<<"$kimi_json")" == "false" && "$(jq -r '.ok' <<<"$plane_json")" == "false" ]]; then
      emit_progress warn "via-fallback" "bridge probes failed; retrying via remote-loopback"
      VIA="remote-loopback"
      if k=$(probe_remote_healthz "5494") 2>/dev/null; then kimi_json="$k"; fi
      if p=$(probe_remote_healthz "5495") 2>/dev/null; then plane_json="$p"; fi
    fi
  else
    if k=$(probe_remote_healthz "5494") 2>/dev/null; then kimi_json="$k"; fi
    if p=$(probe_remote_healthz "5495") 2>/dev/null; then plane_json="$p"; fi
  fi
fi

# 4. backend probe (only with --deep). Tests plane's upstream dependency.
#    Skipped silently if ssh is down — there'd be nothing to probe from.
backend_json=""
if (( DEEP )) && [[ "$ssh_ok" == "true" ]]; then
  emit_progress info "deep-backend" "probing backend reachability + auth validity from remote"
  backend_json="$(probe_backend_from_remote)"
elif (( DEEP )); then
  backend_json='{"baseUrl":null,"reachableFromRemote":null,"authValid":null,"statusCode":null,"message":"ssh master down — backend probe skipped"}'
fi

# ── compose output ───────────────────────────────────────────────────────────
#
# Gate on plane only. Plane is the supervisor — if it answers, the machine is
# usable for orchestrating; kimi spawns lazily per session and may not even be
# running idle. SSH / kimi / backend results are returned as diagnostics.

verified_at="$(now_iso)"

ok="true"
[[ "$(jq -r '.ok' <<<"$plane_json")" != "true" ]] && ok="false"

if [[ -n "$backend_json" ]]; then
  result=$(jq -n \
    --argjson ok "$ok" \
    --arg name "$NAME" \
    --arg via "$VIA" \
    --argjson ssh "{\"ok\":$ssh_ok}" \
    --argjson kimi "$kimi_json" \
    --argjson plane "$plane_json" \
    --argjson backend "$backend_json" \
    --arg verifiedAt "$verified_at" \
    '{ok:$ok,name:$name,via:$via,ssh:$ssh,kimi:$kimi,plane:$plane,backend:$backend,verifiedAt:$verifiedAt}')
else
  result=$(jq -n \
    --argjson ok "$ok" \
    --arg name "$NAME" \
    --arg via "$VIA" \
    --argjson ssh "{\"ok\":$ssh_ok}" \
    --argjson kimi "$kimi_json" \
    --argjson plane "$plane_json" \
    --arg verifiedAt "$verified_at" \
    '{ok:$ok,name:$name,via:$via,ssh:$ssh,kimi:$kimi,plane:$plane,verifiedAt:$verifiedAt}')
fi

printf '%s\n' "$result"

[[ "$ok" == "true" ]] || exit 1
