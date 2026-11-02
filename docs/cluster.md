# Proxmox cluster — Azeroth

## Nodes

| Node | IP | CPU | RAM |
|---|---|---|---|
| `kalimdor` | 192.168.136.238 | 2x AMD EPYC | 256 GB |
| `eastkingdoms` | 192.168.136.226 | 2x AMD EPYC | 256 GB |
| `northrend` | 192.168.136.178 | 2x AMD EPYC | 256 GB |

## Storage

| Storage | Type | Nodes | Disk | Use |
|---|---|---|---|---|
| `local-lvm` | LVM-Thin | each node (local) | System NVMe | VMs + containers |
| `nvme-vms` | LVM-Thin | all 3 nodes | Secondary NVMe (1.5T) | Fast VMs + containers |
| `ssd-vms` | LVM-Thin | all 3 nodes | ATA SSD #1 (3.6T) | VMs + containers |
| `ssd-data` | NFS (kalimdor) | all 3 nodes | ATA SSD #2 (3.6T) | ISOs, templates, backups |
| *(free)* | — | kalimdor | ATA SSD #3 and #4 (3.6T each) | Reserved for Ceph |

> `ssd-data` is exported over NFS from `kalimdor` and mounted at `/mnt/ssd-data` on the 3 nodes.

## Conventions

- **VM templates** live on `ssd-data`, so they are available on every node.
- **Base Ubuntu 24.04 template:** VM `9001` (`ubuntu-server-24`) on `ssd-data`, built with Packer ([templates.md](templates.md)).
- **Hostname = VM name:** template VMs use cloud-init and regenerate the hostname from the VM name on every boot. Change it with `vm/vm_change_hostname.sh`, which renames both.
- **GPUs:** see [gpu.md](gpu.md).

## Access from the scripts

The `vm/` scripts target this cluster:

- **On a node:** through `pvesh`.
- **From anywhere else:** through the API with the `root@pam!infra` token in `.env`. The token needs *Privilege Separation* disabled.
- **With `config/clusters.conf`:** they also fall back to eastkingdoms and northrend if kalimdor does not answer.

See [script-standard.md](script-standard.md#3-which-cluster-the-scripts-target).

## To do

- Set up **Ceph** with disks `sdc` and `sdd` of every node for distributed storage and HA.
- Automatically install qemu-guest-agent on every VM (new VMs get it from the template; older ones still need checking).
- Automatically install Docker on every VM (`vm/vm_apt_install.sh --with-docker` already does it in batches).
- Registry/database of unique resources assigned to VMs (e.g. VNC ports). For now `vm_enable_vnc.sh` writes them to each VM's Notes.
- **Pending tests of the script refactor.** They need ssh as root to the nodes (`ssh-copy-id root@192.168.136.238`):
  - `vm/vm_enable_vnc.sh` end to end (Proxmox only allows `args` and the monitor to root@pam, not to an API token);
  - the scripts' `ssh` mode (`CLUSTER_azeroth_MODE=ssh`);
  - `host/pve_gpu_passthrough.sh --model a6000 --node kalimdor -n` (dry-run only).
