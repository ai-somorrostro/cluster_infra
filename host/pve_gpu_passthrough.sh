#!/usr/bin/env bash
# pve_gpu_passthrough.sh — Prepares a Proxmox node for PCIe passthrough of NVIDIA GPUs
# (merges the former pve_pcie_passthrough_a6000.sh and pve_pcie_passthrough_a800.sh)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] --model a6000|a800 | --match 'lspci text'

Configures the NODE to pass GPUs through to VMs: IOMMU (amd_iommu=on iommu=pt),
VFIO modules, vfio-pci with the GPU IDs (and its audio function if it has one),
kvm ignore_msrs, blacklist of the NVIDIA drivers on the host and initramfs.
The node must be rebooted afterwards.

Script options:
  --model M         a6000 (RTX A6000) | a800 (A800 40GB)
  --match TEXT      Text to look for in 'lspci -nn' for other GPUs
  --node NODE       Run on that node over ssh (otherwise on the current machine)
  --reboot          Reboot the node at the end

Common options:
  -c, --cluster N   Cluster from config/clusters.conf (to resolve --node)
  -n, --dry-run     Show what would be done without changing anything
  -h, --help        This help

Examples:
  $(basename "$0") --model a6000 --node kalimdor -n
  $(basename "$0") --model a800 --node northrend --reboot
EOF
}

MODEL=""
MATCH=""
TARGET_NODE=""
REBOOT=0
ORIG_ARGS=("$@")

while (($# > 0)); do
  case "$1" in
    --model) need_value "$1" "${2:-}"; MODEL="$2"; shift 2 ;;
    --match) need_value "$1" "${2:-}"; MATCH="$2"; shift 2 ;;
    --node) need_value "$1" "${2:-}"; TARGET_NODE="$2"; shift 2 ;;
    --reboot) REBOOT=1; shift ;;
    -h | --help | -n | --dry-run | -c | --cluster) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
    *) die_usage "Unknown option: $1" ;;
  esac
done

case "$MODEL" in
  a6000) MATCH="RTX A6000" ;;
  a800) MATCH="A800 40GB" ;;
  "") [[ -n "$MATCH" ]] || die_usage "Give --model a6000|a800 or --match 'text'" ;;
  *) die_usage "Unknown model: $MODEL (use --match for others)" ;;
esac
CONF_NAME="${MODEL:-$(tr -c 'a-zA-Z0-9' '-' <<<"${MATCH,,}" | sed 's/-*$//')}"

# If another node was requested, copy ourselves there and exit with its exit code
args_remote=()
skip=0
for a in "${ORIG_ARGS[@]}"; do
  ((skip)) && { skip=0; continue; }
  [[ "$a" == --node ]] && { skip=1; continue; }
  args_remote+=("$a")
done
run_on_node "$TARGET_NODE" host/pve_gpu_passthrough.sh "${args_remote[@]}"

require_pve_node
printf '%s== GPU passthrough on %s - "%s" ==%s\n' "$C_BOLD" "$(hostname -s)" "$MATCH" "$C_NC"
[[ "$DRY_RUN" == 1 ]] && log_warn "Dry-run mode: nothing will be changed"

# ─── 1. GPU IDs (+ audio function .1 if present) ─────────────────────────────
log_info "[1/5] Detecting GPUs..."
mapfile -t GPU_LINES < <(lspci -nn | grep -i -- "$MATCH" || true)
((${#GPU_LINES[@]} > 0)) || die "No GPU matches '$MATCH' (check: lspci -nn | grep -i nvidia)"

declare -A SEEN=()
IDS=()
for line in "${GPU_LINES[@]}"; do
  echo "    $line"
  slot="${line%% *}"
  for dev in "$slot" "${slot%.*}.1"; do
    l="$(lspci -nn -s "$dev" 2>/dev/null | head -1)"
    [[ -n "$l" ]] || continue
    id="$(grep -oP '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' <<<"$l" | tail -1 | tr -d '[]')"
    if [[ -n "$id" && -z "${SEEN[$id]:-}" ]]; then
      SEEN[$id]=1
      IDS+=("$id")
      [[ "$dev" == "$slot" ]] || echo "    audio: $l"
    fi
  done
done
ALL_IDS="$(IFS=,; echo "${IDS[*]}")"
log_ok "IDs for vfio-pci: $ALL_IDS"

# ─── 2. IOMMU ────────────────────────────────────────────────────────────────
log_info "[2/5] IOMMU (AMD EPYC)..."
IOMMU_FLAGS="amd_iommu=on iommu=pt"
if grep -q amd_iommu /proc/cmdline; then
  log_ok "IOMMU already active in the running kernel"
elif [[ -f /etc/kernel/cmdline ]]; then
  if grep -q amd_iommu /etc/kernel/cmdline; then
    log_ok "Already in /etc/kernel/cmdline (reboot pending)"
  else
    host_write /etc/kernel/cmdline "$(cat /etc/kernel/cmdline) $IOMMU_FLAGS"
    host_run proxmox-boot-tool refresh
    log_ok "Added to /etc/kernel/cmdline (proxmox-boot-tool)"
  fi
else
  if grep -q amd_iommu /etc/default/grub; then
    log_ok "Already in /etc/default/grub (reboot pending)"
  else
    host_run sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${IOMMU_FLAGS}\"/" /etc/default/grub
    host_run update-grub
    log_ok "Added to /etc/default/grub"
  fi
fi

# ─── 3. VFIO ─────────────────────────────────────────────────────────────────
log_info "[3/5] VFIO modules..."
for mod in vfio vfio_iommu_type1 vfio_pci; do
  if grep -qx "$mod" /etc/modules 2>/dev/null; then
    echo "    already present: $mod"
  else
    if [[ "$DRY_RUN" == 1 ]]; then
      host_run sh -c "echo $mod >> /etc/modules"
    else
      echo "$mod" >>/etc/modules
    fi
    echo "    added: $mod"
  fi
done
host_write "/etc/modprobe.d/vfio-pci-${CONF_NAME}.conf" "options vfio-pci ids=${ALL_IDS}"
if ! grep -qs ignore_msrs /etc/modprobe.d/kvm.conf; then
  host_write /etc/modprobe.d/kvm.conf "options kvm ignore_msrs=1 report_ignored_msrs=0"
fi
log_ok "vfio-pci-${CONF_NAME}.conf → ids=${ALL_IDS}"

# ─── 4. Blacklist NVIDIA on the host ─────────────────────────────────────────
log_info "[4/5] Blacklisting NVIDIA drivers on the host..."
host_write /etc/modprobe.d/blacklist-nvidia-host.conf "blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist nvidia_modeset"
log_ok "/etc/modprobe.d/blacklist-nvidia-host.conf"

# ─── 5. initramfs ────────────────────────────────────────────────────────────
log_info "[5/5] Updating initramfs..."
host_run update-initramfs -u -k all
log_ok "initramfs updated"

cat <<EOF

${C_GREEN}Node configured: it must be REBOOTED.${C_NC}
After the reboot check:
  lspci -nnk | grep -A3 '$MATCH'    # Kernel driver in use: vfio-pci
  dmesg | grep -i iommu
Then, on the VM: Hardware → Add → PCI Device → the GPU (tick 'All Functions' if it has audio).
Inside the VM: guest/install_nvidia_drivers.sh
EOF

if ((REBOOT)) && [[ "$DRY_RUN" != 1 ]]; then
  log_warn "Rebooting the node in 5 s (Ctrl+C to cancel)..."
  sleep 5
  reboot
fi
