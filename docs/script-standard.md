# Script standard

Every script in the repo follows these rules. The `vm/` and `host/` scripts also use the shared library `lib/pve_common.sh`.

## 1. Where each script goes

| Folder | Runs on | Does | Prefix |
|---|---|---|---|
| `vm/` | A node or your machine | Acts on VMs through the API and qemu-guest-agent | `vm_` |
| `host/` | A node, or your machine with `--node` (runs it over ssh) | Configures the node itself | `pve_` |
| `guest/` | Inside the VM | Installers and services. The `vm/` scripts upload and run them | free |

Names are `snake_case`, end in `.sh` and are executable. Data files with secrets are **never** committed: commit a `*.example` instead.

Language: code, comments, output, usage text and docs in **English** (`.cursor/rules/english-code-and-logs.mdc`).

## 2. Command-line contract (`vm/`)

```
vm_<thing>.sh [options] <vmid | range | vmid:value>...
vm_<thing>.sh [options] -f file
```

| Item | Rule |
|---|---|
| VMIDs | Separate arguments: `100 101`. Ranges: `100-110` (max 500). Duplicates are ignored. |
| Per-VM value | `vmid:value`, e.g. `120:web01` (hostname), `120:5977` (VNC port), `105:20480` (MiB). |
| `-f FILE` | One entry per line, same syntax. Blank lines and lines starting with `#` are ignored. |
| Node | **Never asked for**: found through `/cluster/resources`. |
| `-c, --cluster` | Target cluster (see §3). |
| `-n, --dry-run` | Shows every change (API call or command in the VM) without making it. Reads still happen. |
| `-y, --yes` | No confirmations. |
| `-h, --help` | Help with examples. |
| `--` | Everything after it is free arguments (e.g. packages for `vm_apt_install`). |
| Script options | Always long: `--name-prefix`, `--with-docker`... |
| Errors | A failing VM is recorded and the script moves on to the next one. |
| Output | Header `== VM 120 (web01) @ kalimdor ==`, steps `Description... [OK]/[WARN]/[ERROR]` and a summary table at the end. |
| Exit code | `0` all OK · `1` usage/environment error · `2` some VM failed. |

## 3. Which cluster the scripts target

The target is chosen in this order:

1. **`config/clusters.conf` exists** (copied from `config/clusters.conf.example`). The cluster is `-c/--cluster`, then `$PVE_CLUSTER`, then `DEFAULT_CLUSTER` (`azeroth`). Each cluster lists its nodes in order; if kalimdor is down, eastkingdoms is used.
2. **No `clusters.conf`, running on a Proxmox node:** `pvesh` on that node.
3. **No `clusters.conf`, elsewhere:** the API from `.env` (`PROXMOX_API_URL`, `PROXMOX_API_TOKEN_ID`, `PROXMOX_API_TOKEN_SECRET`). `.env` is loaded by `lib/pve-load-env.sh`, which can also read a Packer `variables.pkrvars.hcl` through `VARS_FILE`. The cluster name comes from `/cluster/status`.

Transport (`CLUSTER_<name>_MODE` in `clusters.conf`):

| Mode | How | When |
|---|---|---|
| `local` | `pvesh` directly | Running on a node of that cluster |
| `api` | `curl` + API token (`CLUSTER_<n>_API_TOKEN`, `$PVE_API_TOKEN`, or `.env` for the default cluster) | From outside |
| `ssh` | `ssh root@node pvesh ...` | From outside, without a token |
| `auto` (default) | `local` on a node of the cluster, otherwise `api` if there is a token, otherwise `ssh` | — |

- **Visible target:** every run starts with `Cluster: azeroth (via kalimdor, api)`.
- **Safety:** if the cluster is **not** the default one, the script asks for confirmation before changing anything (unless `-y`).
- **Root-only operations:** Proxmox only allows config `args` and the `monitor` to `root@pam` with a real session, not to tokens. `pve_root` does those over ssh in `api` mode.

## 4. The `lib/pve_common.sh` library

| Function | What for |
|---|---|
| `parse_common_opt "$@"` | Handles common options and VMIDs. Goes in the `*)` branch of the script's `case`, followed by `shift "$COMMON_SHIFT"`. |
| `need_value OPT VAL` | Checks a script option got a value. |
| `prepare_run none\|optional\|required` | Validates `vmid:value` (forbidden / optional / required), loads the cluster, prints the target and confirms. |
| `pve get\|create\|set\|delete PATH [--key value]` | API call over the right transport. Returns the `data` JSON. In dry-run, non-`get` calls are only shown. |
| `pve_task ...` | Like `pve`, but if a UPID comes back it waits for the task and checks it ended OK. |
| `pve_root ...` | For root@pam-only operations (`args`, monitor). |
| `json_get 'EXPR'` | Evaluates a Python expression over the stdin JSON (`d`). |
| `vm_begin VMID` | Finds the VM (`NODE`, `VM_NAME`, `VM_STATUS`, `VM_TEMPLATE`) and prints the header; marks it failed if missing. |
| `vm_require_agent VMID` | VM running, agent enabled and answering. |
| `vm_config`, `vm_current_status`, `vm_shutdown`, `vm_start`, `vm_reboot` | VM helpers. |
| `node_address NODE` | Node IP (from `clusters.conf` or `/cluster/status`). |
| `guest_exec VMID cmd args...` | Runs in the VM **without shell or eval**. Sets `GUEST_OUT`, `GUEST_ERR` and `GUEST_RC`. Timeout via `GUEST_TIMEOUT=S`; stdin via `GUEST_STDIN=...` (passwords never show up in `ps`). |
| `guest_query` | Like `guest_exec` but also runs in dry-run. Read-only commands only. |
| `guest_sh` / `guest_sh_query` | The same through `sh -c 'script'`. |
| `guest_exec_detached` | For apt, dpkg and installers. Runs in a `systemd-run` unit, so it survives a package restarting the qemu-guest-agent. |
| `guest_write_file` / `guest_upload` | Write or upload files to the VM (base64, max ~45 KiB). |
| `step [--warn] "Desc" cmd...` | Step with `[OK]/[ERROR]` (or `[WARN]` without failing). On failure it shows the last error lines. |
| `vm_ok` / `vm_fail` / `vm_skip "message"` | Result of the current VM. |
| `summary` | Final table and `exit 0/2`. |
| `confirm "...?"` | y/N question. Skipped with `-y` or in dry-run. |
| `run_on_node NODE script args` | For `host/`: if not on NODE, copies itself over ssh and runs there. |
| `host_run` / `host_write` | For `host/`: run or write on the node honoring `--dry-run` (with a `.bak` backup). |

`lib/proxmox-api.sh` is a separate set of API helpers used by `templates/containers/ubuntu-lxc/build.sh`. Both libraries read the same `.env`.

### Lessons learned (handled in the library)

- **Non-ASCII characters in `agent/exec`** (`✓`, `—`, `→`) hang the qemu-guest-agent until the VM is rebooted. `guest_exec` rejects them; send content with `guest_write_file` (base64).
- **`agent/file-write` with UTF-8** fails with *Wide character*. The library base64-encodes it and sends `encode=0`.
- **Agent output arrives as latin-1.** It is decoded back to UTF-8.
- **apt or dpkg restarting the qemu-guest-agent** (needrestart, or an upgrade of the agent itself): systemd kills the whole agent cgroup, apt included, and dpkg is left half-configured. Always use `guest_exec_detached` + `NEEDRESTART_SUSPEND=1`.
- **apt locks** are never deleted. The scripts wait with `-o DPkg::Lock::Timeout=300`.
- **cloud-init:** template VMs regenerate the hostname from the **VM name** on every boot (`99-proxmox.cfg`: `preserve_hostname: false`).
- **sshd keeps the FIRST value it reads**, so a `99-*.conf` drop-in loses against Ubuntu's `50-cloud-init.conf`. Use `01-*.conf`.
- **Ubuntu 24 with `ssh.socket`:** `/run/sshd` does not exist until the first connection, and `sshd -t` fails. Create it first.

## 5. Writing a new script

```bash
#!/usr/bin/env bash
# vm_thing.sh — One-line description
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <vmid|range>...

What it does, in two or three lines.

Script options:
  --my-option X     ...

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (one per line, # comments)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") 120 121
EOF
}

MY_OPTION=""
while (($# > 0)); do
  case "$1" in
    --my-option) need_value "$1" "${2:-}"; MY_OPTION="$2"; shift 2 ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

prepare_run none   # or optional / required if it accepts vmid:value

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without agent"; continue; }
  step "Do something" guest_exec "$VMID" command arg || { vm_fail "something failed"; continue; }
  vm_ok "short summary"
done

summary
```

Checklist:

- `--help` with examples.
- Tried with `-n`.
- Tried on a disposable VM.
- `make check` clean.
- Added to [vm-scripts.md](vm-scripts.md) and to the README table.

`guest/` scripts do not use the library: they use `set -euo pipefail`, have a `usage`, check for root, and are idempotent.
