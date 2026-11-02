#!/usr/bin/env bash
# vm_enable_vnc.sh — Enables external VNC access (RealVNC/TightVNC/Remmina) to VMs (formerly vm_enable_external_vnc.sh)
# Reference: https://pve.proxmox.com/wiki/VNC_Client_Access
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options] <vmid|range>...        # display = base + (vmid % 100)
  $(basename "$0") [options] <vmid:port>...         # explicit TCP port (>= 5900)

Adds/replaces '-vnc <bind>:<display>' in the VM 'args' (persistent, keeps the
other args), writes the access info to the VM Notes and reboots it to apply.
TCP port = 5900 + display. You connect to the NODE where the VM runs.

The VNC password is NOT persistent: it is set through the monitor after boot and
is lost when the VM powers off (run the script again with --password).

Proxmox only allows 'args' and the monitor to root@pam with a real session (not
API tokens): run it on a node, or from outside with ssh access to the nodes.

Script options:
  --bind IP          Listen address (default 0.0.0.0)
  --display-base N   Base for the automatic display (default 70)
  --password P       Enables password=on and sets it (max 8 chars)
  --expire S         The password expires after S seconds (requires --password)
  --no-restart       Do not reboot the VM (applied on next boot)

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (vmid or vmid:port per line)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") --password foobar1 120:5977
  $(basename "$0") --display-base 100 120 121 122     # ports 6020, 6021, 6022
  $(basename "$0") --bind 192.168.136.238 120:5977 121:5978
EOF
}

BIND_ADDR="0.0.0.0"
DISPLAY_BASE=70
PASSWORD=""
EXPIRE=""
RESTART=1

while (($# > 0)); do
  case "$1" in
    --bind) need_value "$1" "${2:-}"; BIND_ADDR="$2"; shift 2 ;;
    --display-base) need_value "$1" "${2:-}"; DISPLAY_BASE="$2"; shift 2 ;;
    --password) need_value "$1" "${2:-}"; PASSWORD="$2"; shift 2 ;;
    --expire) need_value "$1" "${2:-}"; EXPIRE="$2"; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

[[ "$DISPLAY_BASE" =~ ^[0-9]+$ ]] || die_usage "--display-base requires a number"
[[ "$BIND_ADDR" =~ ^[0-9.]+$|^[0-9a-fA-F:]+$ ]] || die_usage "--bind requires an IP"
((${#PASSWORD} <= 8)) || die_usage "VNC passwords are limited to 8 characters"
[[ -z "$PASSWORD" || "$PASSWORD" =~ ^[^[:space:]]+$ ]] || die_usage "The VNC password cannot contain spaces"
[[ -z "$EXPIRE" || "$EXPIRE" =~ ^[0-9]+$ ]] || die_usage "--expire requires seconds"
[[ -z "$EXPIRE" || -n "$PASSWORD" ]] || die_usage "--expire requires --password"

prepare_run optional

# merge_args CURRENT_ARGS "-vnc x:y[,password=on]" — drops any previous -vnc and appends the new one
merge_args() {
  python3 - "$1" "$2" <<'PY'
import sys, shlex
tokens = shlex.split(sys.argv[1]) if sys.argv[1].strip() else []
out, i = [], 0
while i < len(tokens):
    if tokens[i] == "-vnc":
        i += 2
        continue
    out.append(tokens[i])
    i += 1
out.extend(shlex.split(sys.argv[2]))
print(shlex.join(out))
PY
}

# notes_with_vnc CURRENT_NOTES "line" — replaces/appends the <!-- vnc-config --> block
notes_with_vnc() {
  python3 - "$1" "$2" <<'PY'
import sys, re
notes, line = sys.argv[1], sys.argv[2]
start, end = "<!-- vnc-config -->", "<!-- /vnc-config -->"
block = f"{start}\n{line}\n{end}"
if start in notes:
    notes = re.sub(re.escape(start) + r".*?" + re.escape(end), lambda _: block, notes, flags=re.DOTALL)
else:
    notes = notes.rstrip("\n") + ("\n\n" if notes.strip() else "") + block
print(notes, end="")
PY
}

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue

  if [[ -n "${VM_VALUES[$VMID]:-}" ]]; then
    PORT="${VM_VALUES[$VMID]}"
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 5900 || PORT > 65535)); then
      vm_fail "invalid port: $PORT (>= 5900)"
      continue
    fi
    DISP=$((PORT - 5900))
  else
    DISP=$((DISPLAY_BASE + VMID % 100))
    PORT=$((5900 + DISP))
  fi
  VNC_ARGS="-vnc ${BIND_ADDR}:${DISP}"
  [[ -n "$PASSWORD" ]] && VNC_ARGS+=",password=on"
  NODE_ADDR="$(node_address "$NODE")"
  echo "  VNC → ${NODE_ADDR}:${PORT} (display ${DISP})"

  CONFIG="$(vm_config "$VMID")" || { vm_fail "could not read the config"; continue; }
  CURRENT_ARGS="$(json_get 'd.get("args","")' <<<"$CONFIG")"
  NOTES="$(json_get 'd.get("description","")' <<<"$CONFIG")"
  [[ "$CURRENT_ARGS" == *-vnc* ]] && echo "  VNC already in args: $CURRENT_ARGS"
  NEW_ARGS="$(merge_args "$CURRENT_ARGS" "$VNC_ARGS")"

  step "Config: args = $NEW_ARGS" pve_root set "/nodes/$NODE/qemu/$VMID/config" --args "$NEW_ARGS" ||
    { vm_fail "could not set args"; continue; }
  NOTE_LINE="VNC: ${NODE_ADDR}:${PORT} (bind ${BIND_ADDR}, display ${DISP})"
  [[ -n "$PASSWORD" ]] && NOTE_LINE+=" - password protected"
  step --warn "VM Notes" pve set "/nodes/$NODE/qemu/$VMID/config" --description "$(notes_with_vnc "$NOTES" "$NOTE_LINE")"

  STATUS="$(vm_current_status "$VMID")"
  if [[ "$STATUS" == running ]]; then
    if ((RESTART)); then
      step "Reboot VM to apply" vm_reboot "$VMID" || { vm_fail "could not reboot"; continue; }
    else
      log_warn "VM running and --no-restart: VNC will be applied on next boot"
    fi
  fi

  if [[ -n "$PASSWORD" ]]; then
    if [[ "$DRY_RUN" == 1 || "$(vm_current_status "$VMID")" == running ]]; then
      step "Set VNC password (not persistent)" pve_root create "/nodes/$NODE/qemu/$VMID/monitor" --command "set_password vnc $PASSWORD -d vnc2" ||
        { vm_fail "could not set the password"; continue; }
      [[ -n "$EXPIRE" ]] && step --warn "Password expiry (${EXPIRE}s)" \
        pve_root create "/nodes/$NODE/qemu/$VMID/monitor" --command "expire_password vnc +${EXPIRE} -d vnc2"
    else
      log_warn "The VM is not running: start it and run the script again to set the password"
    fi
  fi
  vm_ok "${NODE_ADDR}:${PORT}"
done

summary
