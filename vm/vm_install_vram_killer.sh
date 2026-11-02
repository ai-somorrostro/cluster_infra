#!/usr/bin/env bash
# vm_install_vram_killer.sh — Installs/updates/uninstalls the vram-killer service on GPU VMs (formerly install_vram_killer_host.sh)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options] --limit MiB <vmid|range>...
  $(basename "$0") [options] <vmid:MiB>...          # different limit per VM
  $(basename "$0") [options] --uninstall <vmid|range>...

Uploads guest/vram_killer.sh and guest/install_vram_killer.sh to the VM and
leaves the vram-killer service running: when the total VRAM used by GPU
processes exceeds the limit, the most recently started one is killed.
The VM needs the NVIDIA drivers (nvidia-smi).

Script options:
  --limit MiB       Total VRAM limit (8192 = 8 GiB)
  --interval ms     Check interval (default 5000)
  --uninstall       Uninstall the service

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (vmid or vmid:MiB per line)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") --limit 8192 121
  $(basename "$0") 105:20480 106:20480 109:40960
  $(basename "$0") --uninstall 121
EOF
}

LIMIT=""
INTERVAL=5000
UNINSTALL=0

while (($# > 0)); do
  case "$1" in
    --limit) need_value "$1" "${2:-}"; LIMIT="$2"; shift 2 ;;
    --interval) need_value "$1" "${2:-}"; INTERVAL="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

[[ -z "$LIMIT" || "$LIMIT" =~ ^[0-9]+$ ]] || die_usage "--limit requires MiB"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || die_usage "--interval requires milliseconds"

if ((UNINSTALL)); then
  prepare_run none
else
  prepare_run optional
  for v in "${VMIDS[@]}"; do
    l="${VM_VALUES[$v]:-$LIMIT}"
    [[ "$l" =~ ^[0-9]+$ ]] || die_usage "Missing limit for VM $v (use --limit MiB or vmid:MiB)"
  done
fi

TMP=/tmp/vram_killer_install

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without agent"; continue; }

  if ((UNINSTALL)); then
    step "Uninstall vram-killer" guest_sh "$VMID" \
      "systemctl disable --now vram-killer.service 2>/dev/null; rm -f /etc/systemd/system/vram-killer.service && systemctl daemon-reload" ||
      { vm_fail "could not uninstall"; continue; }
    vm_ok "uninstalled"
    continue
  fi

  L="${VM_VALUES[$VMID]:-$LIMIT}"
  if ! guest_sh_query "$VMID" "command -v nvidia-smi >/dev/null"; then
    vm_fail "no nvidia-smi in the VM (install the drivers first: guest/install_nvidia_drivers.sh)"
    continue
  fi
  step "Upload scripts" guest_exec "$VMID" mkdir -p "$TMP" || { vm_fail "could not create $TMP"; continue; }
  if ! guest_upload "$VMID" "$INFRA_ROOT/guest/vram_killer.sh" "$TMP/vram_killer.sh" 0755 ||
    ! guest_upload "$VMID" "$INFRA_ROOT/guest/install_vram_killer.sh" "$TMP/install_vram_killer.sh" 0755; then
    vm_fail "could not upload the scripts"
    continue
  fi
  GUEST_TIMEOUT=120 step "Install service (limit ${L} MiB, every ${INTERVAL} ms)" \
    guest_exec_detached "$VMID" bash "$TMP/install_vram_killer.sh" "$L" "$INTERVAL" ||
    { vm_fail "installation failed"; continue; }
  guest_exec "$VMID" rm -rf "$TMP" || true
  vm_ok "limit ${L} MiB"
done

summary
