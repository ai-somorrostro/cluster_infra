#!/usr/bin/env bash
# vm_grow_fs.sh — Grows the root partition, LVM and filesystem of VMs (formerly resize_vm.sh / vm_resize.sh)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <vmid|range>...

Expands, inside the VM, the partition, the PV/LV (if LVM is used) and the root
filesystem (ext4 or xfs) so they take the whole disk.

With --size it first grows the disk in Proxmox; without --size it assumes the
disk was already grown from the UI (asks for confirmation, unless -y).

Script options:
  --size +NG        Grow the disk in Proxmox (e.g. +20G) before expanding
  --disk D          Disk to grow with --size (default scsi0)

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (one per line, # comments)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") --size +20G 120 121
  $(basename "$0") -y 120            # the disk was already grown in the UI
EOF
}

SIZE=""
DISK="scsi0"

while (($# > 0)); do
  case "$1" in
    --size) need_value "$1" "${2:-}"; SIZE="$2"; shift 2 ;;
    --disk) need_value "$1" "${2:-}"; DISK="$2"; shift 2 ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

[[ -z "$SIZE" || "$SIZE" =~ ^\+[0-9]+[KMGT]?$ ]] || die_usage "--size must be relative, e.g. +20G"
[[ "$DISK" =~ ^(scsi|virtio|sata|ide)[0-9]+$ ]] || die_usage "Invalid disk: $DISK"

prepare_run none
if [[ -z "$SIZE" ]]; then
  confirm "Have you already grown the disk of these VMs in Proxmox?" ||
    die "Grow it in Proxmox first or use --size +NG"
fi

# Script run inside the VM
# shellcheck disable=SC2016  # expanded inside the VM
GROW_SCRIPT='set -e
SRC=$(findmnt -n -o SOURCE /)
FSTYPE=$(findmnt -n -o FSTYPE /)
command -v growpart >/dev/null || { echo "growpart is missing (package cloud-guest-utils)" >&2; exit 1; }
grow_part() {
  part="$1"
  disk="/dev/$(lsblk -no PKNAME "$part" | head -1)"
  num=$(cat "/sys/class/block/$(basename "$(readlink -f "$part")")/partition")
  out=$(growpart "$disk" "$num" 2>&1) || echo "$out" | grep -q NOCHANGE || { echo "$out" >&2; exit 1; }
  echo "$out"
}
if lvs "$SRC" >/dev/null 2>&1; then
  VG=$(lvs --noheadings -o vg_name "$SRC" | tr -d " ")
  for PV in $(pvs --noheadings -o pv_name -S vg_name="$VG" | tr -d " "); do
    grow_part "$PV"
    pvresize "$PV"
  done
  lvextend -r -l +100%FREE "$SRC" || echo "The LV already used the whole VG"
else
  grow_part "$SRC"
  case "$FSTYPE" in
    ext*) resize2fs "$SRC" ;;
    xfs) xfs_growfs / ;;
    *) echo "Unsupported filesystem: $FSTYPE" >&2; exit 1 ;;
  esac
fi
df -h / | tail -1'

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without agent"; continue; }

  if [[ -n "$SIZE" ]]; then
    step "Grow $DISK in Proxmox ($SIZE)" pve set "/nodes/$NODE/qemu/$VMID/resize" --disk "$DISK" --size "$SIZE" ||
      { vm_fail "could not grow the disk in Proxmox"; continue; }
    sleep 2
  fi

  guest_query "$VMID" df -h / >/dev/null && echo "  Before: $(tail -1 <<<"$GUEST_OUT")"
  GUEST_TIMEOUT=180 step "Expand partition / LVM / filesystem" guest_sh "$VMID" "$GROW_SCRIPT" ||
    { vm_fail "could not expand (see message)"; continue; }
  guest_query "$VMID" df -h / >/dev/null && echo "  After:  $(tail -1 <<<"$GUEST_OUT")"
  vm_ok "$(awk '{print "/ = " $2 " (" $5 " used)"}' <<<"$(tail -1 <<<"$GUEST_OUT")")"
done

summary
