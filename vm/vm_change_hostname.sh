#!/usr/bin/env bash
# vm_change_hostname.sh — Changes the hostname of one or more VMs (via qemu-guest-agent)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options] <vmid:hostname>...
  $(basename "$0") [options] --name-prefix P | --name-suffix S <vmid|range>...
  $(basename "$0") [options] -f file        # 'vmid:hostname' lines

Changes the hostname inside the VM (hostnamectl + /etc/hosts), renames the VM in
Proxmox to the same name and reboots it.

On cloud-init VMs (the ones built from the Packer template) Proxmox regenerates
the hostname from the VM NAME on every boot, so both must match. With
--keep-vm-name the VM is not renamed and preserve_hostname is set in cloud-init
so the change survives reboots.

Script options:
  --name-prefix P   New hostname = P + current_hostname
  --name-suffix S   New hostname = current_hostname + S
  --keep-vm-name    Do not rename the VM in Proxmox (sets preserve_hostname in cloud-init)
  --no-reboot       Do not reboot the VM at the end

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (one per line, # comments)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") 100:webserver01
  $(basename "$0") 100:web01 101:web02 102:web03
  $(basename "$0") --name-prefix prod- 100-102
  $(basename "$0") --keep-vm-name -f hostnames.txt
EOF
}

NAME_PREFIX=""
NAME_SUFFIX=""
RENAME_VM=1
REBOOT=1

while (($# > 0)); do
  case "$1" in
    --name-prefix) need_value "$1" "${2:-}"; NAME_PREFIX="$2"; shift 2 ;;
    --name-suffix) need_value "$1" "${2:-}"; NAME_SUFFIX="$2"; shift 2 ;;
    --keep-vm-name) RENAME_VM=0; shift ;;
    --no-reboot) REBOOT=0; shift ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

if [[ -n "$NAME_PREFIX$NAME_SUFFIX" ]]; then
  prepare_run none
else
  prepare_run required
fi

HOSTNAME_RE='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'

# shellcheck disable=SC2016  # expanded inside the VM; the hostname arrives as $1
HOSTS_SCRIPT='if grep -q "^127\.0\.1\.1" /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$1/" /etc/hosts
else
  printf "127.0.1.1\t%s\n" "$1" >> /etc/hosts
fi'

# Named 99-zz-* so it is read after the template's 99-proxmox.cfg (preserve_hostname: false)
CLOUDINIT_SCRIPT='[ -d /etc/cloud/cloud.cfg.d ] || exit 0
printf "preserve_hostname: true\n" > /etc/cloud/cloud.cfg.d/99-zz-preserve-hostname.cfg'

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without agent"; continue; }

  guest_query "$VMID" hostname || { vm_fail "could not read the current hostname"; continue; }
  CURRENT="${GUEST_OUT//[$'\r\n']/}"
  if [[ -n "$NAME_PREFIX$NAME_SUFFIX" ]]; then
    NEW="${NAME_PREFIX}${CURRENT}${NAME_SUFFIX}"
  else
    NEW="${VM_VALUES[$VMID]}"
  fi
  echo "  Hostname: ${CURRENT} → ${NEW}"

  if [[ ! "$NEW" =~ $HOSTNAME_RE ]]; then
    vm_fail "invalid hostname: '$NEW'"
    continue
  fi
  if [[ "$CURRENT" == "$NEW" ]]; then
    vm_skip "already named '$NEW'"
    continue
  fi

  step "hostnamectl set-hostname" guest_exec "$VMID" hostnamectl set-hostname "$NEW" || { vm_fail "hostnamectl failed"; continue; }
  step --warn "Backup /etc/hosts" guest_exec "$VMID" cp -a /etc/hosts /etc/hosts.bak
  step "Update /etc/hosts" guest_exec "$VMID" sh -c "$HOSTS_SCRIPT" sh "$NEW" || { vm_fail "/etc/hosts not updated"; continue; }
  if ((!RENAME_VM)); then
    if vm_config "$VMID" | grep -q cloudinit; then
      log_warn "cloud-init VM with --keep-vm-name: without preserve_hostname it would be renamed back to '$VM_NAME' on reboot"
    fi
    step --warn "cloud-init: preserve_hostname" guest_sh "$VMID" "$CLOUDINIT_SCRIPT"
  fi

  if [[ "$DRY_RUN" != 1 ]]; then
    guest_query "$VMID" hostname || true
    if [[ "${GUEST_OUT//[$'\r\n']/}" != "$NEW" ]]; then
      vm_fail "after the change the hostname is '${GUEST_OUT//[$'\r\n']/}'"
      continue
    fi
  fi

  if ((RENAME_VM)) && [[ "$VM_NAME" != "$NEW" ]]; then
    step --warn "Rename VM in Proxmox ($VM_NAME → $NEW)" pve set "/nodes/$NODE/qemu/$VMID/config" --name "$NEW"
  fi
  if ((REBOOT)); then
    step --warn "Reboot VM" vm_reboot "$VMID"
  fi
  vm_ok "'$CURRENT' → '$NEW'"
done

summary
