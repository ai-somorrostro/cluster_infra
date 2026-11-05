# MIG + LXD: GPU slices per container

`vm/vm_mig_lxd.sh` turns a GPU VM into a host of LXD containers where each container gets its own **MIG slice** (or a whole GPU), its users and SSH access. Meant for inference and lab work: no NVIDIA or Proxmox licenses are needed.

```
Proxmox node ──PCI passthrough──> GPU VM (NVIDIA driver + MIG + LXD)
                                    ├─ container lab-ana  → MIG 1g.5gb  (GPU 0)
                                    ├─ container grupo-a  → MIG 2g.10gb (GPU 1)
                                    └─ container big-model → GPU 2 whole
```

## MIG in 1 minute

An A800/A100 40GB splits into **7 compute slices** and **8 memory slots of 5 GB**. A profile `Ng.XXgb` is N/7 of the compute and XX GB of memory (with its share of L2 cache and bandwidth):

| Profile | Compute | Memory | Per GPU |
|---|---|---|---|
| `1g.5gb` | 1/7 | 5 GB | 7 |
| `1g.10gb` | 1/7 | 10 GB | 4 |
| `2g.10gb` | 2/7 | 10 GB | 3 |
| `3g.20gb` | 3/7 | 20 GB | 2 |
| `4g.20gb` | 4/7 | 20 GB | 1 |
| `7g.40gb` | 7/7 | 40 GB | 1 |

- MIG is **per GPU**: some GPUs can be carved and others stay whole.
- MIG mode covers the whole GPU; capacity without an instance is unusable. That is why the tool only accepts **full layouts** (nothing more fits). List them with `vm/vm_mig_lxd.sh layouts`; the ones marked *idle compute* fill the memory but leave compute unused (e.g. `4x1g.10gb`).
- Each slice has its own memory and compute: a container cannot use or crash another one's GPU. MIG is CUDA only (no graphics).
- Not supported by the RTX A6000 (kalimdor); only the A800 (eastkingdoms, northrend).

## Workflow

```bash
vm/vm_mig_lxd.sh layouts                                  # full layouts and what they give
vm/vm_mig_lxd.sh configure config/mig/gpu2.toml 106       # wizard (whiptail), writes the TOML
vm/vm_mig_lxd.sh plan config/mig/gpu2.toml                # checks + diff, changes nothing
vm/vm_mig_lxd.sh apply config/mig/gpu2.toml               # confirm, apply
vm/vm_mig_lxd.sh status config/mig/gpu2.toml              # GPUs, slices, containers, SSH ports
vm/vm_mig_lxd.sh passwd config/mig/gpu2.toml lab-ana ana  # new temporary password
```

`apply` is idempotent: running it again with the same file does nothing. Edit the TOML (by hand or with `configure`), run `plan` to see the diff and `apply` again.

New users get a random temporary password that must be changed on first login. It is printed at the end of `apply` and appended to `config/mig/<name>.credentials` (mode 600, gitignored). Users connect with `ssh -p <port> <user>@<VM IP>`, have `sudo` inside their container and see only their slice in `nvidia-smi`.

## Config file

See [`config/mig/example.toml`](../config/mig/example.toml). Real files (`config/mig/*.toml`) are gitignored: they hold people's names and the repo is public.

| Key | Meaning |
|---|---|
| `vm` | VMID of the GPU VM |
| `storage_device` | Empty disk of the VM for the LXD btrfs pool (an extra Proxmox disk) |
| `ssh_port_base` | First SSH port (each container gets the next free one) |
| `memory_reserve` | RAM kept for the VM itself (default `max(8GB, 10%)`) |
| `max_cpu_overcommit` | Requested vCPUs / VM vCPUs allowed before failing (default 2.0) |
| `[gpus]` | `index = "layout"` or `"whole"`. GPUs not listed are not touched |
| `[defaults]` | `cpu`, `memory`, `disk`, `image`, `software` for every container |
| `[[containers]]` | `name`, `gpu`, `profile` (MIG GPUs only), `users`, and any default to override |

### `[lab]`: one container per person

For a class, list the people instead of writing one `[[containers]]` each:

```toml
[gpus]
0 = "7x1g.5gb"
1 = "7x1g.5gb"
2 = "7x1g.5gb"

[lab]
profile = "1g.5gb"                       # same slice for everybody
users = ["profe"]                        # optional inline users (first)
users_file = "../people/iabd-2026.txt"   # relative to the TOML
```

| Key | Meaning |
|---|---|
| `profile` | MIG profile of every lab container (required) |
| `gpus` | GPUs to use (default: every MIG GPU whose layout has `profile`) |
| `prefix` | Container name = prefix + user, `_` → `-` (default `lab-`: `lab-ane-perez`) |
| `users`, `users_file` | People: inline and/or a file with one per line (`#` comments). `nombre.apellido` becomes the Linux user `nombre_apellido` |
| `cpu`, `memory`, `disk`, `image`, `software` | Override `[defaults]` for the lab |

User lists per course live in `config/people/<course>.txt` (gitignored; see `config/people/example.txt`). The wrapper reads `users_file` **on this machine** and sends the VM a self-contained copy, so the list never has to exist in the VM.

GPUs are filled in order (GPU 0 first), after the slices taken by `[[containers]]`. A container that already exists keeps its GPU, so adding or removing people does not move anybody else. If there are more people than free slices, `plan` says who is left without one. The wizard (`configure`) does not edit `[lab]` yet.

`software`: `python` (python3, pip, venv, build tools), `uv`, `apt:PKG`, `pip:PKG`. Sizes: `GB` means GiB.

## Checks before changing anything

`plan`, `apply` and the wizard check the config against the live VM:

- **Layouts:** each one fits and fills its GPU; the GPU supports MIG.
- **Slices:** no more containers per profile than instances in the layout; one container per whole GPU.
- **RAM (blocks):** sum of the containers' `memory` ≤ VM RAM − reserve. No overcommit.
- **Disk (blocks):** sum of the disk quotas + 2 GB per container ≤ 95% of the LXD pool.
- **CPU (warns):** more vCPUs than the VM has only slows things down; above `max_cpu_overcommit` it blocks.

```
Resources:
  Resource  VM total  Reserved  Requested  Free after  Status
  RAM       94GB      9GB       8GB        77GB        OK
  Disk      1024GB    51GB      44GB       929GB       OK
  CPU       16        -         4          12          OK
```

If something does not fit, `apply` refuses and says what to change: lower the limits, give the VM more RAM in Proxmox, or grow its disk. The limits are also enforced at runtime (`limits.memory.enforce=hard`, no swap, btrfs disk quotas): a container that runs out of RAM gets OOM-killed inside itself, the VM and the other containers keep running.

## What `apply` sets up in the VM

The first time:

- **LXD** (snap 5.21 LTS), a **btrfs** pool `miglxd` on `storage_device`, the `lxdbr0` NAT bridge and the `miglxd` profile (NVIDIA runtime with compute/utility only, hard memory limit, no swap, no autostart).
- **`mig-lxd-boot.service`**: MIG instances are lost on every reboot; at boot it recreates the layouts from `/etc/mig-lxd/config.toml`, rebinds each container to its slice and starts it. Each container keeps its slice across reboots (same GPU and placement).
- **NVIDIA persistence mode** (`nvidia-persistenced --persistence-mode`): without it the driver tears a GPU down when the last process exits, and re-initialising a passthrough GPU can fail (`WPR2 already up`: the GPU disappears from `nvidia-smi` until the VM restarts).
- **No KMS** (`nvidia-drm modeset=0`, in `/etc/modprobe.d/nvidia-kms.conf` and any other name that a file in `/lib` or `/usr/lib/modprobe.d` uses to set `modeset=1` (`ubuntu-drivers` writes `nvidia-kms.conf`); only a file with the same name replaces it, a different name would be read too and `modeset=1` would win). Takes effect at the next VM restart.
- **Package hold** on the kernel and the NVIDIA driver (`apt-mark hold` + unattended-upgrades blacklist). An automatic kernel upgrade without its NVIDIA module leaves the VM without GPUs (it happened to VM 106). Upgrade them by hand, together, and reboot.
- **Docker coexistence:** Docker sets the `FORWARD` policy to `DROP`; rules in `DOCKER-USER` let the LXD bridge through.

Per container: `ubuntu:24.04`, its slice (`gputype=mig` with the MIG UUID, or `gputype=physical`), CPU/RAM/disk limits, SSH on its port (LXD proxy device from the VM IP), password login, the users and the software.

State lives in the containers themselves (`user.miglxd.*` keys: GPU, profile, slot, SSH port, users). Containers without those keys are never touched.

## Changing things

| Change | What happens |
|---|---|
| Add a container or a user | Created; existing containers keep running |
| CPU / RAM / disk of a container | Applied live (disk shrink fails if the data does not fit) |
| Layout of a GPU (MIG already on) | Containers on that GPU are stopped, the GPU is re-carved live, they are rebound and started |
| MIG on/off for a GPU | Needs a **VM restart**: `apply` sets the mode, asks to restart the VM from Proxmox (that resets the GPU cleanly) and then continues by itself |
| Remove a container from the file | Kept (warning) unless `apply --prune`: then its `/home` is archived to `/var/lib/mig-lxd/archive/` and it is deleted |
| Remove a user from the file | Not deleted (warning) |

## Load test: `vm/vm_mig_bench.sh`

Runs the same workload (for example the notebooks of a course) in many containers at the same moment, each on its own slice, and measures how the VM holds up. Config: `config/bench/<name>.toml` (gitignored; see `config/bench/example.toml`).

```bash
vm/vm_mig_bench.sh prepare config/bench/rag-s2.toml                          # once
vm/vm_mig_bench.sh run config/bench/rag-s2.toml -s gpu --containers lab-profe   # baseline, 1 container
vm/vm_mig_bench.sh run config/bench/rag-s2.toml -s gpu                       # all at once
vm/vm_mig_bench.sh run config/bench/rag-s2.toml -s gpu --gpu 0               # the 7 slices of one GPU
vm/vm_mig_bench.sh report config/bench/results/*rag-s2-gpu*.json             # compare with the baseline
vm/vm_mig_bench.sh clean config/bench/rag-s2.toml
```

| Step | What it does |
|---|---|
| `prepare` | Uploads `[source.files]` (never `.env`), clones `[source].git` at `ref` into `/opt/mig-bench/<name>/src` and runs `[setup].commands` there (for example `uv sync --no-install-project`). The warm-up then runs every item once on a **free MIG slice** with internet access: it downloads the models into `HF_HOME` and leaves a tree with every cache in `.../warm` |
| `run -s SCENARIO` | Mounts `/opt/mig-bench/<name>` **read-only** in the selected containers, copies the tree (`from = "source"` or `"warmup"`) to `/root/mig-bench/<name>/work` and starts the items in all of them together (offline: `[run].offline_env`) |
| `clean` | Removes the mounts, the work dirs and `/opt/mig-bench/<name>`; the results stay in `/var/lib/mig-bench/<name>/results` |

During a run the VM samples every 3 s:

- VRAM per MIG slice (`nvidia-smi -q -x`);
- temperature, power, SM clock and throttle reasons per GPU;
- RAM per container (cgroup `memory.current`) and its OOM kills;
- CPU, load and free RAM of the VM.

The report gives, per item, how many containers finished it without errors and the min / median / max time. Next to it come the 1-container time and the slowdown, the errors grouped by `[errors]` class (for example `oom_gpu` or `cache_miss`), and the peaks of every metric. Results are copied to `config/bench/results/` (gitignored, they name the containers).

Notes:

- The users' `/home` is never touched; the containers' users notice the load while a run lasts.
- Run the items with `--allow-errors` (nbconvert): a failing cell is counted instead of stopping the notebook.
- The venv in `/opt` uses the VM's `/usr/bin/python3.12`, which is the same path in the `ubuntu:24.04` containers.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Several containers on one GPU get wrong results (tensors full of zeros, no error), `CUDA error: an illegal instruction was encountered`, `Xid 13 ... Illegal Instruction Encoding` + `Xid 43` in `dmesg`, then processes stuck in `nvidia_uvm` (`blocked for more than 120 seconds`) and `nvidia-smi` hangs | The VM has a **vIOMMU** (`machine: q35,viommu=intel`). Every DMA page of the guest driver becomes a VFIO mapping on the node; with several CUDA processes per GPU they run out (`vfio_container_dma_map(...) = -28 (No space left on device)` in the node syslog) and the GPUs read garbage. Fix: `qm set <vmid> --machine q35` and stop/start the VM (stuck processes cannot be killed: `qm stop`). One process per GPU works with a vIOMMU, so it shows up only under load. `vm_mig_lxd.sh` and `vm_mig_bench.sh` warn about it |
| `REBOOT REQUIRED: MIG mode change pending` | Expected when turning MIG on/off: accept the restart (or restart the VM from Proxmox and run `apply` again) |
| A GPU disappears from `nvidia-smi`, `dmesg` shows `WPR2 already up` / `RmInitAdapter failed` | The GPU was reset or re-initialised from inside the VM. Restart the VM **from Proxmox**. Never use `nvidia-smi -r` in a passthrough VM |
| `nvidia-smi` fails in the VM after updates | Kernel without NVIDIA module: see [gpu.md](gpu.md); the hold prevents it |
| A container has no GPU after a reboot | `systemctl status mig-lxd-boot` and `journalctl -u mig-lxd-boot` in the VM |
| Containers without network and Docker installed | Re-run `apply` (it re-adds the `DOCKER-USER` rules), or reboot the VM |
| Logs of an apply | `/var/log/mig-lxd/` in the VM (the path is printed at the end) |

Inside the VM the engine can also be used by hand: `sudo python3 /opt/mig-lxd/mig_lxd.py status | plan FILE | apply FILE`.
