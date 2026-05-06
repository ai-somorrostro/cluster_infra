#!/usr/bin/env bash

# Assumes the virtual disk was already resized in Proxmox.
# This script only expands the partition, LVM volume, and filesystem inside the VM.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/pve-load-env.sh"

VM_IDS="${1:-}"

# Validate arguments.
if [ -z "$VM_IDS" ]; then
  echo "Error: Missing argument. Usage: $0 'vm_id1 vm_id2 vm_id3'"
  exit 1
fi

# Convert VM_IDS into an array.
IFS=' ' read -ra VMS <<< "$VM_IDS"

echo "This script expands the partition, LVM volume, and filesystem inside the VM."
echo "The disk must already be resized in Proxmox."
read -p "Have you already resized the disk in Proxmox? (y/n): " -r
if [[ ! $REPLY =~ ^[sSyY]$ ]]; then
  echo "Resize the disk in Proxmox first, then run this script again."
  exit 0
fi
echo ""

source "${SCRIPT_DIR}/../lib/proxmox-api.sh"
# This legacy script handles per-VM failures with explicit checks/continues.
set +e
set +u
set +o pipefail

echo "Expanding partition/LVM/filesystem on ${#VMS[@]} VM(s)..."
echo "=============================================="

# Iterate over each VM.
for VMID in "${VMS[@]}"; do
  echo ""
  echo "Processing VM $VMID..."
  echo "---------------------------------------------"
  
  # Detect the VM node and name through the Proxmox API.
  if ! VM_INFO=$(pve_find_vm "$VMID"); then
    echo "[ERROR] VM $VMID was not found in the cluster."
    echo "---------------------------------------------"
    continue
  fi
  
  NODE=$(echo "$VM_INFO" | cut -d'|' -f1)
  VM_NAME=$(echo "$VM_INFO" | cut -d'|' -f2)
  VM_TYPE=$(echo "$VM_INFO" | cut -d'|' -f3)
  
  if [ "$NODE" = "N/A" ] || [ -z "$NODE" ]; then
    echo "[ERROR] VM $VMID was not found on any cluster node."
    echo "---------------------------------------------"
    continue
  fi

  if [ "$VM_TYPE" != "qemu" ]; then
    echo "[ERROR] VMID $VMID is not a QEMU VM (type: $VM_TYPE)."
    echo "---------------------------------------------"
    continue
  fi
  
  echo "Node: $NODE | Name: $VM_NAME"
  echo ""

  # Execute commands inside the VM through the qemu-guest-agent API.
    exec_in_vm() {
      local cmd="$1"
      local timeout="${2:-600}"
      local result

      if result=$(pve_guest_exec_wait "$NODE" "$VMID" "$timeout" "sh" "-c" "$cmd"); then
        python3 -c 'import json,sys
data = json.load(sys.stdin).get("data", {})
value = data.get("out-data", "")
if value:
    sys.stdout.write(value)
' <<<"$result"
        return 0
      fi

      local rc=$?
      [ -z "$result" ] || pve_guest_exec_output <<<"$result" >&2
      return "$rc"
    }

  # Try to expand automatically.
  echo "Expanding partition inside the VM..."
    
  # Read VG, LV, and PV directly using LVM commands.
  VG_NAME=$(exec_in_vm "vgs --noheadings -o vg_name 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')
  LV_NAME=$(exec_in_vm "lvs --noheadings -o lv_name 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')
  PV_NAME=$(exec_in_vm "pvs --noheadings -o pv_name 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')

  if [ -n "$VG_NAME" ] && [ -n "$LV_NAME" ] && [ -n "$PV_NAME" ]; then
    LV_PATH="/dev/$VG_NAME/$LV_NAME"
    echo "Detected LVM: VG=$VG_NAME, LV=$LV_NAME, PV=$PV_NAME"

    # Extract disk device and partition number from the PV (example: /dev/sda3 -> /dev/sda and 3).
    DISK_DEV=$(echo "$PV_NAME" | sed 's/[0-9]*$//')
    PART_NUM=$(echo "$PV_NAME" | sed 's/.*\([0-9]\)$/\1/')

    # Step 1: Expand the physical partition to use the full disk.
    echo "Expanding physical partition $PV_NAME..."

    # Try growpart first; it is safer for partition growth.
    if exec_in_vm "which growpart >/dev/null 2>&1" 2>/dev/null >/dev/null; then
      PART_EXPAND_OUTPUT=$(exec_in_vm "growpart $DISK_DEV $PART_NUM 2>&1" 2>/dev/null)
      PART_EXPAND_EXIT=$?
    else
      # If growpart is unavailable, refresh the partition table with partx/partprobe.
      PART_EXPAND_OUTPUT=$(exec_in_vm "partx -u $DISK_DEV 2>&1 || partprobe $DISK_DEV 2>&1" 2>/dev/null)
      PART_EXPAND_EXIT=$?
    fi

    if [ $PART_EXPAND_EXIT -eq 0 ]; then
      echo "[OK] Physical partition updated."
      [ -n "$PART_EXPAND_OUTPUT" ] && [ "$PART_EXPAND_OUTPUT" != "CHANGED: partition=3 start=... old: size=... new: size=..." ] && echo "$PART_EXPAND_OUTPUT"
    else
      echo "[WARN] Partition growth warning; this can be normal if it is already expanded: $PART_EXPAND_OUTPUT"
    fi

    # Give the kernel a moment to detect the changes.
    sleep 2

    # Step 2: Resize the Physical Volume so it sees the new partition size.
    echo "Updating Physical Volume..."
    PV_RESIZE_OUTPUT=$(exec_in_vm "pvresize $PV_NAME 2>&1" 2>/dev/null)
    PV_RESIZE_EXIT=$?

    if [ $PV_RESIZE_EXIT -eq 0 ]; then
      echo "[OK] PV updated."
      [ -n "$PV_RESIZE_OUTPUT" ] && echo "$PV_RESIZE_OUTPUT"
    else
      echo "[WARN] PV update warning: $PV_RESIZE_OUTPUT"
    fi

    # Check real free VG space after pvresize.
    # If the disk was not resized in Proxmox first, there will be no free extents here.
    echo "Checking available VG space..."
    VG_FREE=$(exec_in_vm "vgs --noheadings --units g -o vg_free $VG_NAME 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
    VG_SIZE=$(exec_in_vm "vgs --noheadings --units g -o vg_size $VG_NAME 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
    LV_SIZE=$(exec_in_vm "lvs --noheadings --units g -o lv_size $VG_NAME/$LV_NAME 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
    VG_FREE_BYTES=$(exec_in_vm "vgs --noheadings --units b --nosuffix -o vg_free $VG_NAME 2>/dev/null | awk '{printf \"%.0f\", \$1}'" 2>/dev/null | tr -d '[:space:]')

    echo "  VG total: ${VG_SIZE}G, VG free: ${VG_FREE}G, current LV: ${LV_SIZE}G"

    if [ -z "$VG_FREE_BYTES" ] || [ "$VG_FREE_BYTES" -lt 1048576 ]; then
      echo "[OK] No new free space in the VG. Nothing to expand."
      echo "  If you meant to grow this VM, resize the disk in Proxmox first and rerun this script."
      echo ""
      echo "Current disk state:"
      exec_in_vm "df -h /" 2>/dev/null || echo "Could not read current disk state."
      echo "---------------------------------------------"
      continue
    fi

    # Step 3: Expand the Logical Volume.
    echo "Expanding Logical Volume..."

    LV_EXTEND_OUTPUT=$(exec_in_vm "lvextend -l +100%FREE $LV_PATH 2>&1" 2>/dev/null)
    LV_EXTEND_EXIT=$?

    if [ $LV_EXTEND_EXIT -eq 0 ]; then
      echo "[OK] LV expanded."
      [ -n "$LV_EXTEND_OUTPUT" ] && echo "$LV_EXTEND_OUTPUT"

      # Step 4: Expand the filesystem.
      echo "Expanding filesystem..."
      RESIZE2FS_OUTPUT=$(exec_in_vm "resize2fs $LV_PATH 2>&1" 2>/dev/null)
      RESIZE2FS_EXIT=$?

      if [ $RESIZE2FS_EXIT -eq 0 ]; then
        echo "[OK] Filesystem expanded."
        [ -n "$RESIZE2FS_OUTPUT" ] && echo "$RESIZE2FS_OUTPUT"
      else
        echo "[ERROR] Failed to expand filesystem: $RESIZE2FS_OUTPUT"
      fi
    else
      echo "[ERROR] Failed to expand LV: $LV_EXTEND_OUTPUT"
      echo "VG state:"
      exec_in_vm "vgs $VG_NAME && lvs $VG_NAME/$LV_NAME" 2>/dev/null
      echo ""
      echo "Manual commands:"
      echo "  growpart $DISK_DEV $PART_NUM"
      echo "  pvresize $PV_NAME"
      echo "  lvextend -l +100%FREE $LV_PATH"
      echo "  resize2fs $LV_PATH"
    fi
  else
    echo "[WARN] Could not detect VG/LV/PV using LVM commands."
    echo "  Detected VG: ${VG_NAME:-'N/A'}"
    echo "  Detected LV: ${LV_NAME:-'N/A'}"
    echo "  Detected PV: ${PV_NAME:-'N/A'}"
    echo "  Expand manually with: pvresize /dev/sdaX && lvextend -l +100%FREE /dev/vg/lv && resize2fs /dev/vg/lv"
  fi

  echo ""
  echo "Final disk state:"
  exec_in_vm "df -h /" 2>/dev/null || echo "Could not read final disk state."

  echo "---------------------------------------------"
done

echo ""
echo "Process completed for all VMs."
