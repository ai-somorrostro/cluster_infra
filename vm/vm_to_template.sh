#!/usr/bin/env bash
# vm_to_template.sh — Cleans (sysprep), shuts down and converts VMs into templates, optionally moving their disks
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options] <vmid|range>...
  $(basename "$0") [options] <vmid:new_name>...

For each VM: renames it (optional), runs sysprep inside if it is running
(cloud-init clean, machine-id, SSH host keys, logs, shell histories), shuts it
down, moves its disks from --from to --to (optional) and converts it into a template.

Script options:
  --no-sysprep       Do not clean anything inside the VM
  --force-stop       Hard stop if it does not power off within --wait seconds
  --wait S           Seconds to wait for the shutdown (default 180)
  --name-prefix P    New name = P + current_name
  --name-suffix S    New name = current_name + S
  --from STORAGE     Move the disks that live on this storage...
  --to STORAGE       ...to this one (e.g. --from local-lvm --to ssd-data)

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (vmid or vmid:name per line)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") --wait 240 120 121
  $(basename "$0") 120:ubuntu-24-template
  $(basename "$0") --name-suffix -tpl --from local-lvm --to ssd-data 120 121
EOF
}

SYSPREP=1
FORCE_STOP=0
WAIT=180
NAME_PREFIX=""
NAME_SUFFIX=""
FROM=""
TO=""

while (($# > 0)); do
  case "$1" in
    --no-sysprep) SYSPREP=0; shift ;;
    --sysprep) SYSPREP=1; shift ;;
    --force-stop) FORCE_STOP=1; shift ;;
    --wait) need_value "$1" "${2:-}"; WAIT="$2"; shift 2 ;;
    --name-prefix) need_value "$1" "${2:-}"; NAME_PREFIX="$2"; shift 2 ;;
    --name-suffix) need_value "$1" "${2:-}"; NAME_SUFFIX="$2"; shift 2 ;;
    --from) need_value "$1" "${2:-}"; FROM="$2"; shift 2 ;;
    --to) need_value "$1" "${2:-}"; TO="$2"; shift 2 ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

[[ "$WAIT" =~ ^[0-9]+$ ]] || die_usage "--wait requires seconds"
[[ -z "$FROM$TO" || (-n "$FROM" && -n "$TO") ]] || die_usage "--from and --to go together"

prepare_run optional
[[ -z "$FROM" ]] || echo "Disks: $FROM → $TO"
confirm "The VMs will be converted into templates (cannot be undone). Continue?" || die "Cancelled"

# Cleanup inside the VM. Every line tolerates failures (not every distro has everything).
SYSPREP_SCRIPT='command -v cloud-init >/dev/null 2>&1 && cloud-init clean --logs
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null
rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null
sync
exit 0'

# move_disks VMID — moves the disks on $FROM to $TO (with the VM stopped)
move_disks() {
  local vmid="$1" disks d moved=0
  disks="$(vm_config "$vmid" | json_get "[k for k, v in d.items()
      if __import__('re').match(r'^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]+$', k)
      and 'media=cdrom' not in str(v) and str(v).split(':')[0] == '$FROM']")" || return 1
  for d in $(json_get '" ".join(d)' <<<"$disks"); do
    PVE_TASK_TIMEOUT=3600 step "Move $d: $FROM → $TO" pve_task create "/nodes/$NODE/qemu/$vmid/move_disk" \
      --disk "$d" --storage "$TO" --delete 1 || return 1
    moved=$((moved + 1))
  done
  ((moved > 0)) || echo "  No disk on $FROM"
}

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  if [[ "$VM_TEMPLATE" == 1 ]]; then
    vm_skip "already a template"
    continue
  fi

  NEW_NAME="${VM_VALUES[$VMID]:-}"
  [[ -z "$NEW_NAME" && -n "$NAME_PREFIX$NAME_SUFFIX" ]] && NEW_NAME="${NAME_PREFIX}${VM_NAME}${NAME_SUFFIX}"
  if [[ -n "$NEW_NAME" && "$NEW_NAME" != "$VM_NAME" ]]; then
    step "Rename: $VM_NAME → $NEW_NAME" pve set "/nodes/$NODE/qemu/$VMID/config" --name "$NEW_NAME" ||
      { vm_fail "could not rename (invalid name?)"; continue; }
    VM_NAME="$NEW_NAME"
  fi

  STATUS="$(vm_current_status "$VMID")"
  if [[ "$STATUS" == running ]]; then
    if ((SYSPREP)); then
      vm_require_agent "$VMID" || { vm_fail "sysprep needs the agent (use --no-sysprep)"; continue; }
      step "Sysprep inside the VM" guest_sh "$VMID" "$SYSPREP_SCRIPT" || { vm_fail "sysprep failed"; continue; }
    fi
    step "Shut down VM" vm_shutdown "$VMID" "$WAIT" "$FORCE_STOP" ||
      { vm_fail "did not power off in ${WAIT}s (use --force-stop)"; continue; }
  else
    echo "  VM already stopped ($STATUS)"
  fi

  if [[ -n "$FROM" ]]; then
    move_disks "$VMID" || { vm_fail "moving the disks failed (the VM was NOT converted)"; continue; }
  fi

  step "Convert into template" pve_task create "/nodes/$NODE/qemu/$VMID/template" ||
    { vm_fail "could not convert into template"; continue; }
  vm_ok "template '$VM_NAME'"
done

summary
