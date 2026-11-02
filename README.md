# infra — Azeroth Proxmox cluster scripts

Scripts and templates to manage the **Azeroth** Proxmox cluster (kalimdor, eastkingdoms, northrend) and its VMs.

Every script follows the same standard ([docs/script-standard.md](docs/script-standard.md)). They all:

- are used the same way;
- target Azeroth by default;
- work on many VMs at once;
- have `--help` and `--dry-run`;
- keep going when one VM fails instead of aborting the whole batch.

## Getting started

```bash
cp .env.example .env        # Proxmox API URL + token — .env is gitignored
vm/vm_change_hostname.sh --help
vm/vm_change_hostname.sh -n 120:web01        # dry-run: shows what it would do
```

- **On a Proxmox node** no `.env` is needed: the scripts use `pvesh` directly.
- **Anywhere else** (WSL, the `provisioner` VM, a container) they use the API with the `.env` token.
- **Optional:** `config/clusters.conf` adds several clusters and fallback nodes. See [docs/script-standard.md](docs/script-standard.md#3-which-cluster-the-scripts-target).

Requirements:

- **On your machine:** `bash`, `python3` and `curl`.
- **In the VMs:** `qemu-guest-agent`, already included in the templates.
- **Exception:** `vm_enable_vnc.sh` touches `args` and the monitor, which Proxmox only allows to root@pam with a real session (not to tokens). Run it on a node or with ssh access to the nodes.

## I want to...

| Task | Script |
|---|---|
| Change the hostname of VMs | `vm/vm_change_hostname.sh 120:web01 121:web02` |
| Create users (students) on VMs | `vm/vm_create_users.sh --users users.txt 120-130` |
| Enable SSH password login | `vm/vm_create_users.sh 120` |
| Install packages / Docker | `vm/vm_apt_install.sh --with-docker 120 -- htop git` |
| Grow the disk of VMs | `vm/vm_grow_fs.sh --size +20G 120` |
| Shared pip cache | `vm/vm_pip_cache.sh 120-125` |
| External VNC to a VM | `vm/vm_enable_vnc.sh --password abc12345 120:5977` |
| Hardware watchdog (reset if the VM hangs) | `vm/vm_watchdog.sh 120` |
| Limit VRAM on GPU VMs | `vm/vm_install_vram_killer.sh --limit 8192 105` |
| Turn VMs into templates | `vm/vm_to_template.sh 120:my-template` |
| Prepare a node for GPU passthrough | `host/pve_gpu_passthrough.sh --model a6000 --node kalimdor` |
| NVIDIA drivers inside a VM | `guest/install_nvidia_drivers.sh` (inside the VM) |
| Build the Ubuntu 24.04 VM template | `templates/VMs/ubuntu-server-24-http/` ([docs/templates.md](docs/templates.md)) |
| Build the Ubuntu LXC template | `templates/containers/ubuntu-lxc/` ([docs/templates.md](docs/templates.md)) |

## Layout

```
.env.example   Proxmox API credentials (copy to .env)
config/        clusters.conf(.example): optional multi-cluster / fallback nodes
lib/           pve_common.sh: shared library of the vm/ and host/ scripts
               proxmox-api.sh, pve-load-env.sh: API helpers and .env loader (also used by templates/)
vm/            run on a node or on your machine and act on VMs
host/          configure a Proxmox node (GPU passthrough)
guest/         run INSIDE the VMs (the vm/ scripts upload them when needed)
templates/     VMs/ (Packer) and containers/ (LXC + Ansible)
motds/         login banner installed by the templates
telecomunicaciones/  WireGuard VPN on MikroTik and the YOLO training environment
docs/          documentation
```

## Documentation

- [docs/script-standard.md](docs/script-standard.md): the standard, the library and how to write a new script
- [docs/vm-scripts.md](docs/vm-scripts.md): reference of every script with examples, and the old → new mapping
- [docs/cluster.md](docs/cluster.md): the Azeroth cluster (nodes, storage, conventions, to-do)
- [docs/gpu.md](docs/gpu.md): GPUs (passthrough, drivers, VRAM limit)
- [docs/templates.md](docs/templates.md): VM and LXC templates
- [docs/vpn.md](docs/vpn.md): WireGuard VPN for students (MikroTik)

## Maintenance

```bash
make check     # bash -n + shellcheck + check that no secrets are committed
```

Credentials are never committed. These are all in `.gitignore`, and `make secrets` checks it:

- `.env` and `config/clusters.conf`
- `users.txt` and `groups.txt`
- `*.pkrvars.hcl` and `http/user-data`
- the WireGuard configs

Project language is English (`.cursor/rules/english-code-and-logs.mdc`).
