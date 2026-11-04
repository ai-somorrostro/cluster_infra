# Script reference

Every script accepts the common options `-c/--cluster`, `-f/--file`, `-n/--dry-run`, `-y/--yes` and `-h/--help`, plus separate VMIDs, ranges (`120-125`) and, where noted, `vmid:value` (see [script-standard.md](script-standard.md)). `--help` is always the exact reference; this page adds context.

Legend: 🔌 needs the VM running with qemu-guest-agent · 🔁 reboots the VM · 🔑 in `api` mode needs ssh (root@pam-only operation).

---

## vm/vm_change_hostname.sh 🔌 🔁

Changes the hostname inside the VM (`hostnamectl` + the `127.0.1.1` line in `/etc/hosts`), **renames the VM in Proxmox to the same name** and reboots it.

| Option | |
|---|---|
| `vmid:hostname` | Explicit hostname (required unless prefix/suffix) |
| `--name-prefix P` / `--name-suffix S` | New = P + current + S |
| `--keep-vm-name` | Do not rename the VM; sets `preserve_hostname: true` in cloud-init (`99-zz-preserve-hostname.cfg`) |
| `--no-reboot` | Do not reboot |

```bash
vm/vm_change_hostname.sh 120:web01 121:web02
vm/vm_change_hostname.sh --name-prefix lab- 120-125
vm/vm_change_hostname.sh -f hostnames.txt     # lines like 120:web01
```

> **Why it renames the VM:** the Packer template ships `/etc/cloud/cloud.cfg.d/99-proxmox.cfg` with `preserve_hostname: false`, so on every boot cloud-init sets the hostname to the VM name. The old script changed only the hostname and the change was lost on reboot.

## vm/vm_create_users.sh 🔌

Creates the users in a `username:password` file (or resets their password if they exist), adds them to `sudo` and forces a password change on first login.

It also enables SSH password login with the drop-in `/etc/ssh/sshd_config.d/01-password-auth.conf`. It must be `01-`: the template's `99-custom.conf` loses against `50-cloud-init.conf`, because sshd keeps the first value it reads.

| Option | |
|---|---|
| `--users F` | `username:password` file (see `vm/users.txt.example`; the real one is not committed) |
| `--no-expire` | Do not force a password change (formerly `--nopass`, still accepted) |
| `--add-to-docker` | Add the users to the docker group if it exists |
| `--no-ssh-password` | Do not touch SSH |

```bash
vm/vm_create_users.sh --users users.txt 120-130
vm/vm_create_users.sh 140                       # only enables SSH password login
```

Passwords reach `chpasswd` through stdin, so they never show up in `ps` or logs. Replaces `vm_enable_password_ssh.sh`.

## vm/vm_apt_install.sh 🔌

`apt-get update` + `install` of the packages after `--`. Afterwards it checks with `dpkg-query` that each one got installed. It waits for apt locks (never deletes them) and comments out `deb cdrom` lines.

apt and dpkg run detached from the qemu-guest-agent (`systemd-run`), so a package that restarts the agent no longer kills the installation.

| Option | |
|---|---|
| `-- package...` | Packages to install |
| `--with-docker` | Docker CE from the official repo (`guest/install_docker.sh`, detects Ubuntu/Debian) |
| `--docker-user U` | User to add to the docker group (repeatable) |
| `--upgrade` | `apt-get upgrade` |
| `--timeout S` | Max per apt operation (default 900) |

```bash
vm/vm_apt_install.sh 120 121 -- htop jq tree
vm/vm_apt_install.sh --with-docker --docker-user telecomunicaciones 120-125
```

## vm/vm_grow_fs.sh 🔌

Grows the partition, the PV/LV (if LVM) and the root filesystem (ext4/xfs). Replaces `resize_vm.sh` / `vm_resize.sh`.

| Option | |
|---|---|
| `--size +NG` | Grow the disk in Proxmox through the API first |
| `--disk D` | Disk for `--size` (default `scsi0`) |

```bash
vm/vm_grow_fs.sh --size +20G 120 121
vm/vm_grow_fs.sh -y 120          # the disk was already grown in the UI
```

> The Ubuntu installer only gives half of the VG to the root LV. On template VMs, the first run also reclaims that space.

## vm/vm_pip_cache.sh 🔌

Shared pip cache (`/opt/pip-cache`, mode 1777) in `/etc/pip.conf` (with a backup) and `PIP_CACHE_DIR` in `/etc/profile.d`. Installs `python3-pip` if missing. Option: `--dir D`. Replaces `install_pip_cache.sh`.

## vm/vm_enable_vnc.sh 🔁 🔑

Adds `-vnc <bind>:<display>` to the VM `args` (keeping the other args), writes the access info to the VM Notes and reboots the VM. You connect to the **node** running the VM, on port `5900 + display`.

| Option | |
|---|---|
| `vmid:port` | Explicit TCP port (≥ 5900) |
| (no port) | display = `--display-base` (70) + vmid % 100 |
| `--bind IP` | Listen address (default 0.0.0.0) |
| `--password P` | `password=on` and set through the monitor (max 8; **not persistent**: lost on power off) |
| `--expire S` | The password expires after S seconds |
| `--no-restart` | Applied on next boot |

```bash
vm/vm_enable_vnc.sh --password abc12345 120:5977
vm/vm_enable_vnc.sh --display-base 100 120 121      # ports 6020, 6021
```

> Not yet tested end-to-end from outside the nodes (needs ssh as root): see the to-do list in [cluster.md](cluster.md).

## vm/vm_watchdog.sh 🔌 🔁

1. Configures the watchdog daemon **inside** the VM (`guest/setup_watchdog.sh`).
2. Adds `watchdog: model=i6300esb,action=reset` to the config.
3. Powers the VM off and on so the hardware appears (a normal reboot is not enough).

Options: `--action reset|shutdown|poweroff|pause|none`, `--no-guest`, `--no-restart`. If the VM is stopped only step 2 is done; start it and run the script again.

## vm/vm_install_vram_killer.sh 🔌

Installs the `vram-killer` service: if the **total** VRAM used by GPU processes goes over the limit, the most recently started process is killed. Needs `nvidia-smi` in the VM. See [gpu.md](gpu.md).

```bash
vm/vm_install_vram_killer.sh --limit 8192 121
vm/vm_install_vram_killer.sh 105:20480 106:20480     # per-VM limit
vm/vm_install_vram_killer.sh --uninstall 121
```

## vm/vm_to_template.sh 🔌*

Steps:

1. Rename (optional).
2. Sysprep if the VM is running: `cloud-init clean`, `machine-id`, SSH host keys, logs, histories.
3. Shut down.
4. Move the disks from `--from` to `--to` (optional; done **before** converting).
5. Convert into a template.

VMs that already are templates are skipped. Asks for confirmation first.

| Option | |
|---|---|
| `vmid:name` | Rename (replaces `--name`) |
| `--name-prefix` / `--name-suffix` | Pattern-based rename |
| `--no-sysprep` | No cleanup inside |
| `--wait S` / `--force-stop` | Wait for shutdown / hard stop if it does not power off |
| `--from S --to S` | Move disks (e.g. `--from local-lvm --to ssd-data`) |

\* Without `--no-sysprep`, a running VM needs the agent.

---

## vm/vm_mig_lxd.sh 🔌 🔁*

MIG + LXD configurator: carves the A800 GPUs of a VM with MIG and gives each LXD container inside it a GPU slice, users and SSH. It works on **one VM described by a TOML file** (`vm = <id>`), not on VMID lists. Full guide: [mig.md](mig.md).

| Command | |
|---|---|
| `layouts` | Full MIG layouts of an A800/A100 40GB |
| `configure CONFIG [VMID]` | whiptail wizard that writes CONFIG, then `plan` |
| `plan CONFIG [--prune]` | Validation, RAM/disk/CPU checks and diff; changes nothing |
| `apply CONFIG [--prune]` | Confirm and apply; new passwords go to `CONFIG.credentials` |
| `status CONFIG\|VMID` | GPUs, slices, containers, SSH ports |
| `passwd CONFIG CONTAINER USER` | New temporary password |

\* Only when a GPU turns MIG on or off (asks first).

---

## host/pve_gpu_passthrough.sh

Prepares a **node** for NVIDIA GPU passthrough:

- IOMMU;
- VFIO modules;
- `vfio-pci ids=` for the GPU and its audio function;
- `kvm ignore_msrs`;
- nouveau/nvidia blacklist;
- `update-initramfs`.

Merges the former `_a6000` and `_a800` scripts. See [gpu.md](gpu.md).

```bash
host/pve_gpu_passthrough.sh --model a6000 --node kalimdor -n    # see what it would do
host/pve_gpu_passthrough.sh --model a800 --node northrend --reboot
host/pve_gpu_passthrough.sh --match "RTX 4090"                  # on the node itself
```

## guest/

| Script | Does |
|---|---|
| `install_docker.sh [user...]` | Official Docker CE (Ubuntu/Debian). Used by `vm_apt_install --with-docker`. |
| `setup_watchdog.sh` | Watchdog daemon for i6300esb. Used by `vm_watchdog`. |
| `vram_killer.sh` / `install_vram_killer.sh` | VRAM limit service. Used by `vm_install_vram_killer`. |
| `install_nvidia_drivers.sh` | Recommended NVIDIA driver + CUDA + Container Toolkit + nvtop. Run by hand inside the VM. |

All of them can be run by hand inside a VM (`sudo ./script.sh --help`), e.g. on VMs without qemu-guest-agent.

## Old → new

| Before | Now |
|---|---|
| `general_pve_scrips/vm_change_hostname.sh` | `vm/vm_change_hostname.sh`. **Change:** pairs `100 web01` → `100:web01` |
| `general_pve_scrips/vm_create_users.sh` | `vm/vm_create_users.sh`. **Change:** the user file goes as `--users F` |
| `general_pve_scrips/vm_enable_password_ssh.sh` | `vm/vm_create_users.sh <vmid>` |
| `general_pve_scrips/vm_apt_install.sh` | `vm/vm_apt_install.sh` (same syntax) |
| `general_pve_scrips/vm_resize.sh` (`resize_vm.sh`) | `vm/vm_grow_fs.sh`. **Change:** separate VMIDs, not `'100 101'` |
| `general_pve_scrips/install_pip_cache.sh` | `vm/vm_pip_cache.sh`. **Change:** `--dir D` |
| `general_pve_scrips/vm_enable_external_vnc.sh` | `vm/vm_enable_vnc.sh`. **Change:** pairs `120 5977` → `120:5977`; `--display N` → `vmid:port` |
| `general_pve_scrips/vm_watchdog.sh` | `vm/vm_watchdog.sh` + `guest/setup_watchdog.sh` |
| `general_pve_scrips/vm_to_template.sh` | `vm/vm_to_template.sh`. **Change:** `--name X` → `vmid:X` |
| `general_pve_scrips/vm_fix_netplan_dhcp.sh` | Removed: the Packer template already empties `machine-id` (`cleanup.sh`) |
| `gpu_utils/pve_pcie_passthrough_{a6000,a800}.sh` | `host/pve_gpu_passthrough.sh --model ...` |
| `gpu_utils/install_vram_killer_host.sh` | `vm/vm_install_vram_killer.sh`. **Change:** `--limit MiB` |
| `gpu_utils/{vram_killer,install_vram_killer,install_nvidia_drivers}.sh` | `guest/` |
| Credentials via `PROXMOX_API_*` / `.env` / `VARS_FILE` | Unchanged: the same `.env` |
