# GPUs in the cluster

NVIDIA compute GPUs (RTX A6000 48 GB, A800 40 GB) passed through to VMs with **PCIe passthrough**.

## Full workflow

| Step | Where | Script |
|---|---|---|
| 1. Prepare the node (once per node) | Node | `host/pve_gpu_passthrough.sh --model a6000\|a800 --node <node>`, then reboot the node |
| 2. Assign the GPU to the VM | Proxmox UI | VM → Hardware → Add → PCI Device (*All Functions* if the GPU has audio, like the A6000). Machine `q35` **without vIOMMU** (see below) |
| 3. Drivers in the VM | Inside the VM | `sudo guest/install_nvidia_drivers.sh`, then reboot the VM |
| 4. Limit VRAM (optional, shared VMs) | Node or your machine | `vm/vm_install_vram_killer.sh --limit <MiB> <vmid>` |

> [!WARNING]
> **No vIOMMU in GPU VMs** (`machine: q35`, not `q35,viommu=intel|virtio`). With a vIOMMU every DMA page the
> guest driver maps becomes a VFIO mapping on the node, and several CUDA processes per GPU exhaust them
> (`vfio_container_dma_map(...) = -28 (No space left on device)` in the node syslog). The GPUs then compute
> garbage without any CUDA error (tensors full of zeros), or fail with `Xid 13 Illegal Instruction Encoding`,
> and finally `nvidia_uvm` hangs. One process per GPU works, so it only shows up under load. Found on VM 106
> with MIG on 2026-11-05; fix: `qm set <vmid> --machine q35`, then stop/start the VM.

## 1. Node: `host/pve_gpu_passthrough.sh`

What it does on the node:

- **IOMMU:** adds `amd_iommu=on iommu=pt` to `/etc/kernel/cmdline` (proxmox-boot-tool) or GRUB, unless already there.
- **VFIO:** adds `vfio`, `vfio_iommu_type1` and `vfio_pci` to `/etc/modules`.
- **GPU IDs:** writes `/etc/modprobe.d/vfio-pci-<model>.conf` with `options vfio-pci ids=<GPU>[,<audio>]`. The IDs are detected from `lspci -nn`, including the `.1` function of the same slot.
- **KVM:** `/etc/modprobe.d/kvm.conf` with `ignore_msrs=1`.
- **Host drivers:** `/etc/modprobe.d/blacklist-nvidia-host.conf` (nouveau and nvidia*).
- **initramfs:** `update-initramfs -u -k all`.

Every file it modifies keeps a `.bak` backup. Options:

- `-n` shows the changes without applying them.
- `--node` copies the script to the node over ssh and runs it there (needs ssh as root).
- `--reboot` reboots the node at the end.

After the reboot, `lspci -nnk | grep -A3 'RTX A6000'` must show `Kernel driver in use: vfio-pci`.

> If a node has **two different models**, each `--model` writes its own `vfio-pci-<model>.conf`. Check that the final `ids=` contains every ID (the last `options vfio-pci` line wins).

## 3. VM: `guest/install_nvidia_drivers.sh`

Installs:

- the driver recommended by `ubuntu-drivers` (or `--driver nvidia-driver-XXX`);
- `nvidia-cuda-toolkit`;
- NVIDIA Container Toolkit, configuring Docker if it is installed;
- `nvtop`.

To skip parts: `--no-cuda` and `--no-container-toolkit`.

Check after the reboot:

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

## 4. VRAM limit: vram-killer

For VMs whose GPU is shared by several users. The `vram-killer` service:

1. every interval (5 s by default) adds up the VRAM of every process using the GPU (`nvidia-smi --query-compute-apps`);
2. if the total goes over the limit, it `SIGKILL`s the process that **started last**.

Everything is logged to `/var/log/vram_killer.log`.

```bash
vm/vm_install_vram_killer.sh --limit 8192 121                  # 8 GiB
vm/vm_install_vram_killer.sh --limit 20480 --interval 2000 105 106
vm/vm_install_vram_killer.sh 105:20480 109:40960               # per-VM limit
vm/vm_install_vram_killer.sh --uninstall 121
```

Inside the VM:

```bash
systemctl status vram-killer
tail -f /var/log/vram_killer.log
```

To change the limit, just run the script again: it updates the service.

Tested with a fake `nvidia-smi`: with two 5000 MiB processes and an 8192 MiB limit it kills the most recent one and keeps the other.

## MIG slices per container

To share A800s between several people with guaranteed memory and compute, see [mig.md](mig.md) (`vm/vm_mig_lxd.sh`).

## YOLO

Docker training environment: [`telecomunicaciones/gpu_utils/yolo-training/`](../telecomunicaciones/gpu_utils/yolo-training/README.md).
