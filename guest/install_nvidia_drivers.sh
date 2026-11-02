#!/usr/bin/env bash
# install_nvidia_drivers.sh — Installs NVIDIA drivers, CUDA toolkit and NVIDIA Container Toolkit on Ubuntu. Runs INSIDE the VM.
# Requirement: the GPU passed through to the VM (host/pve_gpu_passthrough.sh on the node).
set -euo pipefail

usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [--driver nvidia-driver-XXX] [--no-cuda] [--no-container-toolkit]

Installs the driver recommended by ubuntu-drivers (or the given one), Ubuntu's
CUDA toolkit, NVIDIA Container Toolkit (configuring Docker if present) and nvtop.
Reboot the VM afterwards.

Options:
  --driver PKG             Specific driver package (default: the recommended one)
  --no-cuda                Do not install nvidia-cuda-toolkit
  --no-container-toolkit   Do not install NVIDIA Container Toolkit
EOF
}

DRIVER=""
CUDA=1
CTK=1
while (($# > 0)); do
  case "$1" in
    --driver) DRIVER="${2:?--driver requires a package}"; shift 2 ;;
    --no-cuda) CUDA=0; shift ;;
    --no-container-toolkit) CTK=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || { echo "Error: run it as root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
APT=(apt-get -o DPkg::Lock::Timeout=300 -y -q)

echo "[1/6] Checking the GPU..."
lspci | grep -i nvidia || {
  echo "Error: no NVIDIA GPU visible. Check the passthrough in Proxmox." >&2
  exit 1
}

echo "[2/6] Dependencies..."
"${APT[@]}" update
"${APT[@]}" install build-essential dkms "linux-headers-$(uname -r)" ubuntu-drivers-common curl gpg

echo "[3/6] Driver..."
if [[ -z "$DRIVER" ]]; then
  DRIVER="$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3; exit}')"
  DRIVER="${DRIVER:-nvidia-driver-535}"
fi
echo "    $DRIVER"
"${APT[@]}" install "$DRIVER"
printf '# infra: install_nvidia_drivers.sh\noptions nvidia NVreg_EnableGpuFirmware=0\n' >/etc/modprobe.d/nvidia.conf

if ((CUDA)); then
  echo "[4/6] CUDA toolkit..."
  "${APT[@]}" install nvidia-cuda-toolkit
else
  echo "[4/6] CUDA toolkit: skipped"
fi

if ((CTK)); then
  echo "[5/6] NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
    gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  "${APT[@]}" update
  "${APT[@]}" install nvidia-container-toolkit
  if command -v docker >/dev/null; then
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    echo "    Docker configured with the NVIDIA runtime"
  else
    echo "    Docker is not installed: afterwards run 'nvidia-ctk runtime configure --runtime=docker'"
  fi
else
  echo "[5/6] NVIDIA Container Toolkit: skipped"
fi

echo "[6/6] nvtop..."
"${APT[@]}" install nvtop || echo "    nvtop not available in the repositories"

cat <<EOF

[✓] Done. REBOOT the VM and check:
  nvidia-smi
  nvcc --version
  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
To limit VRAM per VM: vm/vm_install_vram_killer.sh (from the host)
EOF
