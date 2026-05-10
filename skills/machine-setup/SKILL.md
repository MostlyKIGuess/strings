---
name: machine-setup
description: Provision and retire remote Linux machines that host the OpenScientist agent stack (plane server + kimi-server). Covers the lifecycle that *changes persistent state* — registering a new machine in `~/.openscientist/machines/index.json`, opening the SSH ControlMaster the first time, rsyncing the cloud-run bundle and bringing up systemd services, uninstalling on the remote, and removing from the registry. Use this skill whenever the user says "add / connect / provision / set up / install / bring up / retire" a machine. Day-to-day operation of an already-provisioned machine — listing, switching active, status probes, deep runs, claiming results, and **provider CLI installs (claude, codex)** — lives in the sibling `machine-use` skill.
metadata:
  skill-author: OpenScientist
category: infrastructure
---

# Machine Setup

Provision, install, and retire the machines that run deep runs.

> **Status (2026-05) — index.json holds persistent provisioning facts only.**
> The `status` / `lastError` / `lastProviderError` / `lastVerifiedAt` fields and
> the top-level `active` pointer have been removed. Reachability is probed at
> runtime by the renderer (boot probe + 20 s periodic). `mark_broken` still
> writes `~/.openscientist/machines/<name>.lasterror` (the forensic trail) and
> emits the structured failure JSON on stdout, but does NOT touch index.json.
> Sections below that mention the six-state machine, the reaper, or the
> `status` field as the dropdown gate are superseded — read the renderer's
> `desktop:machine-bridge-state` event for live state.

This skill is the lifecycle complement to `machine-use`. `setup.sh` registers + provisions in one shot; `machine-use` then runs day-to-day operations.

A **machine** is a remote Linux box (or the laptop itself, reserved name `local`) that hosts the OpenScientist agent stack: the plane server (HTTP API on port 5495), the kimi-server (HTTP API on port 5494), and zero or more provider CLIs (claude, codex) installed separately via `machine-use/install-claude.sh` / `install-codex.sh`.

This skill follows the contracts in `frontend/docs/machine-provisioning-spec.md`. Read that doc for the design rationale; this README is the agent-facing reference for *how to drive* the scripts.

## Lifecycle

```
add.sh           → registers ssh creds in index.json; nothing on the remote yet
reconnect-ssh.sh → opens the SSH ControlMaster (idempotent, repairs a dropped one)
install.sh       → rsyncs the bundle, brings up kimi + plane via systemd,
                   verifies via verify.sh; on success writes
                   bundleVersion + provisionedAt + remote.{home,prefix,…}
setup.sh         → wraps add → reconnect-ssh → install in one shot
uninstall.sh     → stops services on remote, clears install dir
                   (keeps the registry entry + services.providers)
remove.sh        → deletes the registry entry (refuses if bundleVersion is set
                   without --force, since that means a real install is live)
```

The renderer's machine selector enables a machine iff its **plane probe** says reachable (`bridgeStates[id].planeReachable === true`). The probe runs at app boot and every 20 s thereafter. `index.json` carries no live state — `status`, `lastError`, `lastProviderError`, `lastVerifiedAt`, and the top-level `active` pointer have all been removed.

## Where things live

| Path | Purpose |
|---|---|
| `~/.openscientist/machines/index.json` | machine registry (authoritative; written via atomic tmp+rename through `_lib/provisioning.sh`'s `index_update`). |
| `~/.openscientist/machines/<name>.lock` | per-machine `flock` for the duration of any setup/install/uninstall script. |
| `~/.openscientist/machines/<name>.lasterror` | forensic floor (spec §3). Append-only NDJSON; mark_broken writes here before any jq invocation. |
| `~/.openscientist/auth.json` | SPOT auth token, synced to remote during install. The synced copy's `base_url` is rewritten to `https://aloo-gobi.fydy.ai` (override via `OPENSCIENTIST_REMOTE_BASE_URL`). Laptop copy is untouched. |
| `~/.openscientist/cloud-run/<arch>/` | **cloud-run bundle** — symlink Electron main maintains at startup. Points at `<app-resources>/cloud-run/` in a packaged app, or `frontend/electron/cloud-run/` in dev. |
| `~/.openscientist/ssh/<name>.sock` | SSH ControlMaster socket. |
| `~/.openscientist/ssh/<name>.ports.json` | renderer-written snapshot of forwarded local ports (used by `verify.sh` pattern 2). |
| `~/.local/share/openscientist/` *(on remote)* | installed binaries + plane dir, laid down by `remote-stage.sh`. |
| `~/.config/systemd/user/{kimi,plane}.service` *(on remote)* | user-level systemd units rendered atomically by `remote-stage.sh` from the bundle's templates. |
| `~/.openscientist/logs/<script>-<ts>.log` *(on remote)* | per-invocation verbose logs. Path appears in every structured outcome. |

## Bundle layout (no `install.sh` inside the bundle)

Per spec §4.2.1, the bundle ships **only artifacts** — no executable orchestration. The laptop-side `install.sh` (this skill) is the single source of truth and pipes `remote-stage.sh` over `ssh bash -s` for the remote work.

```
<bundle>/
├── kimi-server        # PyInstaller binary, executable
├── plane.tar.gz       # plane node bundle (deps autoscanned at build time)
├── manifest.json      # {schemaVersion: 2, bundleVersion: sha256(plane.tar.gz), ...}
└── systemd/
    ├── kimi.service   # template with ${...} placeholders
    └── plane.service  # template with ${...} placeholders
```

`bundleVersion = sha256(plane.tar.gz)` is the canonical version field. `install.sh` reads it from `manifest.json` and writes it into `index.json` so the renderer can show version skew across machines.

## Universal script contract (spec §3)

Every script in this skill obeys:

- **Args:** single positional `<name>`, long-form flags only.
- **Stdout:** ends with one JSON document. Success: `{ok:true, name, stage:"done", ...}`. Failure: `{ok:false, name, stage, message, ...}`.
- **Stderr:** NDJSON progress lines, one per stage transition.
- **Exit 0** iff and only if `ok=true`.
- **Failure path:** `mark_broken` appends a forensic line to `~/.openscientist/machines/<name>.lasterror`, prints the failure JSON on stdout, and exits 1. It does NOT touch `index.json` — live state is the renderer's bridge probe, the durable trail is `<name>.lasterror`.
- **Locking:** `flock` on `<name>.lock` for the duration. A second concurrent invocation fails immediately with `{stage:"lock"}` rather than blocking.

## Scripts

| Script | Purpose | Wrapper budget |
|---|---|---|
| `setup.sh <name> [--from-ssh-config ALIAS] [--host H --user U --key K [--port P]] [--force]` | **Preferred entry point.** Wraps `add` → `reconnect-ssh` → `install` in order. Skips `add` if the machine is already registered. Idempotent: re-running on a fully provisioned machine just re-installs (preserves `services.providers`). | 425s |
| `add.sh <name> [--force]` | Register ssh creds in `index.json`. Does NOT reach the machine. | 15s |
| `reconnect-ssh.sh <name>` | Open or repair the SSH ControlMaster. | 90s |
| `install.sh <name> [--bundle PATH]` | rsync bundle, pipe `remote-stage.sh`, run `verify.sh` from laptop, write `bundleVersion` + `provisionedAt` + `remote.*`. | 360s |
| `remote-stage.sh` | **Not invoked directly.** Piped over stdin by install.sh; runs on the remote. | (caller-bounded) |
| `uninstall.sh <name>` | Stop services on remote, clear install dir, null out `bundleVersion` / `provisionedAt` / `remote.*` (preserves `services.providers`). | 90s |
| `remove.sh <name> [--force]` | Delete from `index.json`. Refuses without `--force` if `bundleVersion` is set (run `uninstall.sh` first). | 5s |

## Workflows

Scripts resolve their own location via `$(dirname "$0")`. After world-model sync they land at `${KIMI_WORK_DIR}/.openscientist/skills/machine-setup/scripts/`.

**Always prefix with `bash`** — `bash $SCRIPTS/setup.sh …`. World-model sync does not preserve the executable bit.

### Set up a new machine

All of these phrasings mean the same thing — run `setup.sh`:

> "add a machine" · "connect a machine" · "provision a machine" · "set up a machine" · "install a machine" · "bring up a machine"

The only exception is if the user *explicitly* says "just register, don't install" — then call `add.sh` directly.

```bash
SCRIPTS=${KIMI_WORK_DIR}/.openscientist/skills/machine-setup/scripts
bash $SCRIPTS/setup.sh osci-math
```

`setup.sh` defaults to `--from-ssh-config <name>`, so any machine in `~/.ssh/config` works with no further input. Pass `--host H --user U --key K [--port P]` to override or supply missing fields.

After `setup.sh` exits 0 with `"ok":true`, ask what's next:

- "Want me to install Claude Code or Codex on this machine? Each is opt-in." → `machine-use` provider scripts.

The renderer opens the SSH ControlMaster automatically when the user picks the machine in the selector — there is no separate activate step for the agent to perform. Do **not** silently chain provider installs.

### Reading structured outcomes

Every script's stdout ends with one JSON document. Parse it directly:

```bash
out=$(bash $SCRIPTS/setup.sh osci-math)
ok=$(printf '%s' "$out" | tail -1 | jq -r .ok)
if [[ "$ok" == "true" ]]; then
  bv=$(printf '%s' "$out" | tail -1 | jq -r .bundleVersion)
  echo "ready @ ${bv:0:16}"
else
  printf '%s' "$out" | tail -1 | jq -r '"\(.stage): \(.message)"'
fi
```

For long-running scripts where your tool harness times out before completion: do **not** assume failure. Two independent signals tell you whether the script actually finished:

1. **`<name>.lock`** — held by `flock` for the duration. If the lock is *not* held (try `flock -n -x ~/.openscientist/machines/<name>.lock -c true && echo released`), the script has exited.
2. **`<name>.lasterror`** — append-only forensic NDJSON. If a new line was appended after your script started, that's a failure outcome you can read.

```bash
NAME=osci-math
LOCK=~/.openscientist/machines/$NAME.lock
until ! flock -n -x "$LOCK" -c true 2>/dev/null; do sleep 3; done
# Lock released — read the structured outcome from <name>.lasterror's last
# line (failure) or from the script's stdout (success). bundleVersion in
# index.json being set means install.sh succeeded at least once.
tail -1 ~/.openscientist/machines/$NAME.lasterror 2>/dev/null | jq .
jq --arg n "$NAME" '.machines[$n] | {bundleVersion, provisionedAt}' ~/.openscientist/machines/index.json
```

Never re-run `setup.sh` / `install.sh` while the lock is held — you'll trip the per-machine `flock` and the new invocation will exit with `{stage:"lock"}` immediately.

### Reading `<name>.lasterror` (forensic floor)

If `mark_broken` ran, `~/.openscientist/machines/<name>.lasterror` has every failure record appended (one JSON line each). The most recent line is at the bottom:

```bash
tail -1 ~/.openscientist/machines/osci-math.lasterror | jq .
```

This file is **immune to jq failures and disk-write contention** — it's written via `printf >>` before any other I/O. It's the authoritative trail for "why did the last setup/install fail."

### Bring back a machine

**Trigger phrases.** Enter this playbook whenever the user names a specific machine and says any of: "isn't working", "can't connect", "is broken", "unreachable", "down", "won't talk to me", "fix \<name\>", "debug \<name\>", "repair \<name\>", "bring back \<name\>", "reconnect \<name\>". Do **not** start this playbook on your own initiative — the renderer has its own boot probe and dropdown indicator; speculating that a machine is broken without the user saying so is out-of-frame.

**Diagnosis primitive: `verify.sh`.** Run it first; it tells you which layer broke. Then choose the cheapest fix.

```bash
SCRIPTS_USE=${KIMI_WORK_DIR}/.openscientist/skills/machine-use/scripts
SCRIPTS_SETUP=${KIMI_WORK_DIR}/.openscientist/skills/machine-setup/scripts
NAME=osci-math

out=$(bash $SCRIPTS_USE/verify.sh "$NAME")
printf '%s\n' "$out" | jq '{ok, ssh:.ssh.ok, kimi:.kimi.ok, plane:.plane.ok, via, message}'
```

Map the result to the right fix. **`verify.sh` gates on plane reachability** — `ok:false` always means plane failed; `ssh` and `kimi` results in the same JSON tell you where to look upstream.

| Symptom from `verify.sh` | What's broken | Cheapest fix |
|---|---|---|
| `ok:false`, `ssh.ok:false` | SSH ControlMaster died or never opened. | `bash $SCRIPTS_SETUP/reconnect-ssh.sh "$NAME"` (no remote work; idempotent). Re-run verify. |
| `ok:false`, `ssh.ok:true`, `plane.ok:false` | Plane process not responding on remote. | `ssh "$NAME" 'systemctl --user restart plane.service kimi.service'`. Wait ~5 s. Re-run verify. |
| Plane still down after the restart above | systemd unit broken, bundle corrupt, or auth missing. | `bash $SCRIPTS_SETUP/install.sh "$NAME"` — re-rsyncs the bundle, re-syncs `auth.json`, rewrites the systemd units, runs `verify.sh` as its last gate. Preserves `services.providers`. ~5 min cold. |
| `verify.sh` exits 2 with `no such machine` | Index entry missing — user removed it or this is a fresh shell. | `bash $SCRIPTS_SETUP/setup.sh "$NAME"` — full register + install. Needs `~/.ssh/config` entry or explicit `--host/--user/--key`. |
| `ok:true` but the user says chat / sync still fails | Machine is reachable, but plane's upstream dependency (the SPOT backend at the remote's `auth.json` `base_url`) is failing. | Re-run with the deep probe: `bash $SCRIPTS_USE/verify.sh "$NAME" --deep`. Read the new `backend.*` block — it tells you exactly which upstream layer is broken (see the table below). |
| `ok:true` but the user reports an unrelated runtime issue (provider CLI, task payload) | Not a machine layer problem at all. | Read `ssh "$NAME" 'journalctl --user -u kimi -u plane -n 100'` for service-level errors. For provider-CLI errors, read `~/.openscientist/machines/<name>.lasterror` (bottom line is most recent). |

**Deep probe — when `--deep` adds `backend.*` to the output:** `verify.sh` by default checks only that plane is *running*. With `--deep`, it additionally tests plane's upstream dependency: the SPOT backend the remote's `auth.json` points at. The `backend` block carries two extra signals:

| `backend.reachableFromRemote` | `backend.authValid` | What's wrong | Fix |
|---|---|---|---|
| `false` (502/503/521/522/523/524/000) | (anything) | SPOT cloud backend is **down or unreachable from the remote**. Network or hosted outage. | Not your job to fix. Tell the user the cloud backend is down (`backend.statusCode` and `backend.message` carry the detail). Suggest they retry in a few minutes or check status. |
| `true` | `false` (401/403) | The remote's auth token is **expired or invalid**. | `bash $SCRIPTS_SETUP/install.sh "$NAME"` — the auth-copy stage re-syncs the laptop's current `auth.json` (with `base_url` rewritten to the cloud) into the remote, mode 600. Plane re-reads auth per request; no restart needed. |
| `true` | `null` (no token, status 000) | Remote `auth.json` is missing/empty or there's a network blip mid-probe. | If `backend.message` says "no auth.json" or "no token" → `install.sh` re-syncs. If it says "backend unreachable" → transient; re-run `--deep`. |
| `true` | `true` | Backend is fine, auth is fine. The user's complaint is downstream of the machine — provider CLI, task payload, or something inside the run itself. | Look at remote service logs (`ssh "$NAME" 'journalctl --user -u kimi -u plane -n 100'`) and the session's `meta.json` / `stdout.log` under `~/.kimi/plane/sessions/<sid>/`. |

**After any fix**, re-run `verify.sh` and confirm `ok:true`. The renderer's dropdown indicator updates on its next 20 s probe, not immediately — tell the user this so they don't think the fix didn't take.

**Telling the user what you found.** When you report back, say (a) which layer was broken (ssh / plane / install / auth), (b) what you ran, (c) the verify result. Don't paste raw JSON — summarize.

**When to give up and ask.** If `install.sh` fails twice in a row with the same `<name>.lasterror` stage, stop. Read the forensic line, summarize the failure, and ask the user how they want to proceed (skip / retry / re-add / replace the remote). Don't keep retrying — that just burns time and obscures the root cause.

### Retire a machine

```bash
SCRIPTS=${KIMI_WORK_DIR}/.openscientist/skills/machine-setup/scripts
bash $SCRIPTS/uninstall.sh osci-math       # stop + clear services on remote, null out bundleVersion
bash $SCRIPTS/remove.sh osci-math          # delete from index (now allowed since bundleVersion is null)
```

`remove.sh` refuses without `--force` when `bundleVersion` is set — that's the persistent signal that a real install is on the remote. Run `uninstall.sh` first, or pass `--force` if you've already cleaned the remote by hand.

## Troubleshooting

| Symptom | Diagnostic | Fix |
|---|---|---|
| `setup.sh` reports `{ok:false, stage:"bundle-resolve"}` | `ls -l ~/.openscientist/cloud-run` | Restart Electron — main maintains the symlink at startup. Do NOT prompt the user for `--bundle` unless they explicitly opted into a custom build. |
| `setup.sh` reports `{stage:"remote-stage", remoteLogTail:"..."}` | `cat ~/.openscientist/machines/<name>.lasterror \| tail -1 \| jq .` | Read the embedded `remoteLogTail` and `serviceLogs.{kimi,plane}`. Common: `Cannot find module 'js-yaml'` means a stale bundle — rebuild via `frontend/scripts/build-cloud-run-bundle.sh` (the new build's smoke test catches missing deps). |
| `setup.sh` reports `{stage:"verify-from-laptop", verifyOutput:"..."}` | `bash ${KIMI_WORK_DIR}/.openscientist/skills/machine-use/scripts/verify.sh <name>` | Run verify.sh standalone for a fresh probe. The remote services may have started but be returning non-200; check `journalctl --user -u kimi -u plane -n 50` over SSH. |
| Tool harness "timed out" before script returned | `flock -n -x ~/.openscientist/machines/<name>.lock -c true && echo released`; `tail -1 ~/.openscientist/machines/<name>.lasterror` | If the lock is released, the script finished. Last lasterror line gives the structured failure outcome (or no recent line if it succeeded). The harness exit code is not authoritative. |
| `{stage:"lock", message:"another op in progress"}` | `ls -l ~/.openscientist/machines/<name>.lock`; `lsof ~/.openscientist/machines/<name>.lock` | Real concurrent invocation: wait. Stale lock from a SIGKILL: delete the lockfile manually if no process holds it (`lsof` returns nothing). |
| Service won't survive reboot | `ssh <name> 'loginctl show-user $USER \| grep Linger'` | `ssh <name> 'sudo loginctl enable-linger $USER'`. `remote-stage.sh` attempts this with passwordless sudo but logs a warning if unavailable. |

## What this skill does NOT do

- **Does not install provider CLIs.** Use `machine-use/install-claude.sh` and `machine-use/install-codex.sh`. Provider installs live in the sibling skill because they're a runtime concern, not a provisioning one.
- **Does not run health probes.** Use `machine-use/verify.sh` (spec §4.5).
- **Does not build the bundle.** That's `frontend/scripts/build-cloud-run-bundle.sh`. This skill consumes a prebuilt bundle from `~/.openscientist/cloud-run/<arch>/`.
- **Does not manage LocalForward rules.** Electron's bridge owns tunnel port allocation; the renderer writes `<name>.ports.json` so verify.sh can find the forwarded ports.
- **Does not rotate auth tokens during normal operation.** Re-run `install.sh` — the auth-copy stage re-syncs `~/.openscientist/auth.json`.
