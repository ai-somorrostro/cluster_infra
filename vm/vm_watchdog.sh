#!/usr/bin/env bash
# vm_watchdog.sh — Adds a hardware watchdog (i6300esb) to VMs and configures the daemon inside
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <vmid|range>...

1. Configures the watchdog daemon INSIDE the VM (guest/setup_watchdog.sh via agent)
2. Adds 'watchdog: model=i6300esb,action=<action>' to the VM config
3. Powers the VM off and on so the hardware shows up

If the VM is stopped or has no agent, only step 2 is done: start it and run the
script again (or run guest/setup_watchdog.sh inside it by hand).

Script options:
  --action A        reset | shutdown | poweroff | pause | none (default reset)
  --no-guest        Do not configure anything inside the VM
  --no-restart      Do not power cycle the VM (hardware appears on the next cold boot)

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (one per line, # comments)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") 120 121
  $(basename "$0") --action poweroff --no-restart 130-135
EOF
}

ACTION=reset
GUEST=1
RESTART=1

while (($# > 0)); do
  case "$1" in
    --action) need_value "$1" "${2:-}"; ACTION="$2"; shift 2 ;;
    --no-guest) GUEST=0; shift ;;
    --no-restart) RESTART=0; shift ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

[[ "$ACTION" =~ ^(reset|shutdown|poweroff|pause|none)$ ]] || die_usage "Invalid action: $ACTION"

prepare_run none
WATCHDOG="model=i6300esb,action=${ACTION}"
GUEST_SCRIPT="$INFRA_ROOT/guest/setup_watchdog.sh"

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  STATUS="$(vm_current_status "$VMID")"
  CURRENT="$(vm_config "$VMID" | json_get 'd.get("watchdog","")')" || CURRENT=""
  [[ -n "$CURRENT" ]] && echo "  Current watchdog: $CURRENT"

  GUEST_DONE=0
  if ((GUEST)); then
    if [[ "$STATUS" == running ]] && vm_require_agent "$VMID" 2>/dev/null; then
      step "Upload setup_watchdog.sh" guest_upload "$VMID" "$GUEST_SCRIPT" /tmp/setup_watchdog.sh 0755 ||
        { vm_fail "could not upload the script"; continue; }
      GUEST_TIMEOUT=900 step "Configure watchdog inside the VM" guest_exec_detached "$VMID" bash /tmp/setup_watchdog.sh ||
        { vm_fail "configuration inside the VM failed"; continue; }
      guest_exec "$VMID" rm -f /tmp/setup_watchdog.sh || true
      GUEST_DONE=1
    else
      log_warn "VM stopped or without agent: the daemon is not configured inside (run again with the VM running)"
    fi
  fi

  if [[ "$CURRENT" != "$WATCHDOG" ]]; then
    step "Config: watchdog $WATCHDOG" pve set "/nodes/$NODE/qemu/$VMID/config" --watchdog "$WATCHDOG" ||
      { vm_fail "could not add the watchdog to the config"; continue; }
    if [[ "$STATUS" == running ]]; then
      if ((RESTART)); then
        step "Shut down VM" vm_shutdown "$VMID" 180 1 || { vm_fail "could not shut down"; continue; }
        step "Start VM" vm_start "$VMID" || { vm_fail "could not start"; continue; }
      else
        log_warn "--no-restart: the watchdog will show up after powering the VM off and on"
      fi
    fi
  else
    echo "  The config already had $WATCHDOG"
  fi

  msg="$WATCHDOG"
  ((GUEST && !GUEST_DONE)) && msg+=" (still needs configuring inside the VM)"
  vm_ok "$msg"
done

summary
