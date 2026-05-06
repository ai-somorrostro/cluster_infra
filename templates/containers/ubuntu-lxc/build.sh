#!/usr/bin/env bash
#
# Build a Proxmox LXC template remotely from any machine/LXC with API access.
# No local pct/pveam required.
#
# Requirements:
#   - PROXMOX_API_URL / PROXMOX_API_TOKEN_ID / PROXMOX_API_TOKEN_SECRET
#     (autoloaded from repo .env by lib/pve-load-env.sh)
#   - ansible + ansible-playbook + ssh client
#

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/proxmox-api.sh"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BUILD_VMID="${BUILD_VMID:-11000}"
HOSTNAME_BUILD="${HOSTNAME_BUILD:-lxc-ubuntu-24-04-template}"
PVE_NODE="${PVE_NODE:-${PROXMOX_NODE:-kalimdor}}"
STOCK_TEMPLATE_NAME="${STOCK_TEMPLATE_NAME:-lxc-ubuntu-24.04-template-somo}"
STOCK_FILE="${STOCK_FILE:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-ssd-data}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"
FINAL_STORAGE="${FINAL_STORAGE:-ssd-data}"
ROOTFS_SIZE="${ROOTFS_SIZE:-8}" # GB
BRIDGE="${BRIDGE:-vmbr0}"
DEFAULT_SSH_PUBKEY=""
if [ -f "${REPO_ROOT}/ssh-keys/flea.pub" ]; then
  DEFAULT_SSH_PUBKEY="${REPO_ROOT}/ssh-keys/flea.pub"
else
  DEFAULT_SSH_PUBKEY="$HOME/.ssh/id_ed25519.pub"
fi
SSH_PUBKEY="${SSH_PUBKEY:-$DEFAULT_SSH_PUBKEY}"
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-${SCRIPT_DIR}/playbook.yml}"
SSH_USER="${SSH_USER:-root}"
DEBUG="${DEBUG:-0}"
PROVISION_SSH_PRIVKEY="${PROVISION_SSH_PRIVKEY:-}"
PROVISION_SSH_PUBKEY_CONTENT=""
ANSIBLE_LANG="${ANSIBLE_LANG:-C.UTF-8}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()     { echo -e "\n\033[1;34m==>\033[0m $*"; }
debug()   { [ "$DEBUG" = "1" ] && echo -e "\033[2;37m[debug]\033[0m $*" >&2 || true; }
require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
hash_password_sha512() {
  local raw_password="$1"
  openssl passwd -6 -stdin <<<"$raw_password"
}

api_status_code() {
  local method="$1"
  local path="$2"
  shift 2
  debug "api_status_code ${method} ${path}"
  curl -sk -o /dev/null -w "%{http_code}" -X "$method" -H "$PVE_AUTH_HEADER" "$@" "${PVE_API_URL}${path}"
}

api_data_get() {
  local path="$1"
  debug "api_data_get ${path}"
  pve_api GET "$path" \
    | python3 -c 'import json,sys; data=json.load(sys.stdin).get("data"); print(json.dumps(data if data is not None else []))'
}

pick_online_node() {
  api_data_get "/cluster/resources?type=node" \
    | python3 -c 'import json,sys
items = json.load(sys.stdin)
for item in items:
    if item.get("status") == "online":
        print(item.get("node",""))
        raise SystemExit(0)
raise SystemExit(1)'
}

resolve_stock_file() {
  local candidate="${STOCK_FILE:-}"
  if [ -n "$candidate" ]; then
    echo "$candidate"
    return 0
  fi

  api_data_get "/nodes/${PVE_NODE}/storage/${TEMPLATE_STORAGE}/content?content=vztmpl" \
    | python3 - "$STOCK_TEMPLATE_NAME" <<'PY'
import json
import sys

needle = sys.argv[1]
items = json.load(sys.stdin)
matches = []
for item in items:
    volid = item.get("volid", "")
    if ":vztmpl/" not in volid:
        continue
    filename = volid.split(":vztmpl/", 1)[1]
    if needle in filename:
        matches.append(filename)

if not matches:
    raise SystemExit(1)

matches.sort()
print(matches[-1])
PY
}

get_ct_ip() {
  api_data_get "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}/interfaces" \
    | python3 -c 'import json,sys
items = json.load(sys.stdin)
for iface in items:
    if iface.get("name") != "eth0":
        continue
    # Newer Proxmox can expose addresses under "ip-addresses".
    for entry in iface.get("ip-addresses", []):
        if entry.get("ip-address-type") != "inet":
            continue
        addr = (entry.get("ip-address") or "").strip()
        if addr and not addr.startswith("127.") and not addr.startswith("169.254."):
            print(addr)
            raise SystemExit(0)
    # Fallback shape: plain "inet" string, e.g. "192.168.1.10/24".
    inet = iface.get("inet")
    if isinstance(inet, str):
        addr = inet.split("/", 1)[0].strip()
        if addr and not addr.startswith("127.") and not addr.startswith("169.254."):
            print(addr)
            raise SystemExit(0)
raise SystemExit(1)'
}

wait_for_ip() {
  local ip=""
  for _ in $(seq 1 60); do
    ip="$(get_ct_ip || true)"
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_ssh() {
  local ip="$1"
  local ssh_args=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=2
    -o BatchMode=yes
  )
  ssh_args+=(-i "$PROVISION_SSH_PRIVKEY")
  for _ in $(seq 1 60); do
    if ssh "${ssh_args[@]}" "${SSH_USER}@${ip}" true 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ "$DEBUG" = "1" ]; then
  set -x
  trap 'echo "[debug] failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
fi

require curl
require python3
require ssh
require ansible
require ansible-playbook
if [ -n "${ADMIN_PASSWORD:-}" ] && [ -z "${ADMIN_PASSWORD_HASH:-}" ]; then
  require openssl
  log "Hashing ADMIN_PASSWORD for Ansible user setup"
  ADMIN_PASSWORD_HASH="$(hash_password_sha512 "${ADMIN_PASSWORD}")"
  export ADMIN_PASSWORD_HASH
fi
[[ -f "$SSH_PUBKEY" ]] || { echo "SSH pubkey not found at $SSH_PUBKEY" >&2; exit 1; }
[[ -f "$ANSIBLE_PLAYBOOK" ]] || { echo "Playbook not found at $ANSIBLE_PLAYBOOK" >&2; exit 1; }
debug "repo_root=${REPO_ROOT}"
debug "pve_api_url=${PVE_API_URL}"
debug "requested_node=${PVE_NODE:-<auto>}"
debug "template_storage=${TEMPLATE_STORAGE}"
debug "rootfs_storage=${ROOTFS_STORAGE}"
debug "final_storage=${FINAL_STORAGE}"
debug "rootfs_size_gb=${ROOTFS_SIZE}"
debug "ssh_pubkey_path=${SSH_PUBKEY}"
debug "ansible_playbook=${ANSIBLE_PLAYBOOK}"
debug "ansible_lang=${ANSIBLE_LANG}"

if [ -z "$PROVISION_SSH_PRIVKEY" ]; then
  _provision_key_dir="$(mktemp -d)"
  PROVISION_SSH_PRIVKEY="${_provision_key_dir}/provision_key"
  trap 'rm -rf "${_provision_key_dir}"' EXIT
  ssh-keygen -t ed25519 -N "" -C "lxc-build-provision" -f "$PROVISION_SSH_PRIVKEY" >/dev/null
fi
[[ -f "$PROVISION_SSH_PRIVKEY" ]] || { echo "Provision private key not found at $PROVISION_SSH_PRIVKEY" >&2; exit 1; }
[[ -f "${PROVISION_SSH_PRIVKEY}.pub" ]] || { echo "Provision public key not found at ${PROVISION_SSH_PRIVKEY}.pub" >&2; exit 1; }
PROVISION_SSH_PUBKEY_CONTENT="$(<"${PROVISION_SSH_PRIVKEY}.pub")"
debug "provision_ssh_privkey_path=${PROVISION_SSH_PRIVKEY}"

if [ -z "$PVE_NODE" ]; then
  log "Selecting online Proxmox node"
  PVE_NODE="$(pick_online_node || true)"
fi
[[ -n "$PVE_NODE" ]] || { echo "Could not resolve Proxmox node. Set PVE_NODE." >&2; exit 1; }

log "Using node: ${PVE_NODE}"
STOCK_FILE="$(resolve_stock_file || true)"
[[ -n "$STOCK_FILE" ]] || {
  echo "No template match for '${STOCK_TEMPLATE_NAME}' in ${TEMPLATE_STORAGE}. Set STOCK_FILE or preload template." >&2
  exit 1
}
log "Stock template: ${STOCK_FILE}"
debug "resolved_stock_file=${STOCK_FILE}"

SSH_PUBKEY_CONTENT="$(<"$SSH_PUBKEY")"
[[ -n "$SSH_PUBKEY_CONTENT" ]] || { echo "SSH pubkey file is empty: $SSH_PUBKEY" >&2; exit 1; }
debug "ssh_pubkey_size_bytes=$(wc -c <"$SSH_PUBKEY" | tr -d ' ')"

# ---------------------------------------------------------------------------
# 1. Remove old build CT if it already exists
# ---------------------------------------------------------------------------
if [ "$(api_status_code GET "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}/status/current")" = "200" ]; then
  log "Removing existing CT ${BUILD_VMID}"

  if upid="$(pve_api POST "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}/status/stop" | pve_json_data)"; then
    [ -n "$upid" ] && pve_wait_task "$PVE_NODE" "$upid" 180 || true
  fi

  upid="$(pve_api DELETE "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}?purge=1" | pve_json_data)"
  pve_wait_task "$PVE_NODE" "$upid" 300
fi

# ---------------------------------------------------------------------------
# 2. Create + start build CT
# ---------------------------------------------------------------------------
log "Creating build CT ${BUILD_VMID}"
create_upid="$(
  pve_api POST "/nodes/${PVE_NODE}/lxc" \
    --data-urlencode "vmid=${BUILD_VMID}" \
    --data-urlencode "ostemplate=${TEMPLATE_STORAGE}:vztmpl/${STOCK_FILE}" \
    --data-urlencode "hostname=${HOSTNAME_BUILD}" \
    --data-urlencode "cores=2" \
    --data-urlencode "memory=1024" \
    --data-urlencode "swap=512" \
    --data-urlencode "rootfs=${ROOTFS_STORAGE}:${ROOTFS_SIZE}" \
    --data-urlencode "net0=name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --data-urlencode "features=nesting=1" \
    --data-urlencode "ssh-public-keys=${PROVISION_SSH_PUBKEY_CONTENT}" \
    --data-urlencode "unprivileged=1" \
    --data-urlencode "onboot=0" \
    | pve_json_data
)"
pve_wait_task "$PVE_NODE" "$create_upid" 600

log "Starting CT ${BUILD_VMID}"
start_upid="$(pve_api POST "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}/status/start" | pve_json_data)"
pve_wait_task "$PVE_NODE" "$start_upid" 180

# ---------------------------------------------------------------------------
# 3. Wait for IP + SSH
# ---------------------------------------------------------------------------
log "Waiting for container network"
IP="$(wait_for_ip || true)"
[[ -n "$IP" ]] || { echo "Container never reported an IP address"; exit 1; }
log "Container IP: ${IP}"
debug "container_ip=${IP}"

# ---------------------------------------------------------------------------
# 4. Bootstrap and run Ansible
# ---------------------------------------------------------------------------
log "Waiting for SSH from stock template"
wait_for_ssh "$IP" || { echo "SSH did not become ready on ${IP}" >&2; exit 1; }

log "Bootstrapping python + openssh via Ansible raw"
LANG="${ANSIBLE_LANG}" LC_ALL="${ANSIBLE_LANG}" LC_CTYPE="${ANSIBLE_LANG}" PYTHONUTF8=1 PYTHONIOENCODING=UTF-8 ANSIBLE_HOST_KEY_CHECKING=False \
  ansible -i "${IP}," -u "${SSH_USER}" --private-key "${PROVISION_SSH_PRIVKEY}" -m raw -a "
    set -e
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 python3-apt openssh-server >/dev/null
    systemctl enable --now ssh >/dev/null
  " all

log "Running Ansible playbook"
LANG="${ANSIBLE_LANG}" LC_ALL="${ANSIBLE_LANG}" LC_CTYPE="${ANSIBLE_LANG}" PYTHONUTF8=1 PYTHONIOENCODING=UTF-8 ANSIBLE_HOST_KEY_CHECKING=False \
  ADMIN_SSH_PUBKEY="${SSH_PUBKEY_CONTENT}" \
  ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH:-}" \
  ansible-playbook -i "${IP}," -u "${SSH_USER}" --private-key "${PROVISION_SSH_PRIVKEY}" "${ANSIBLE_PLAYBOOK}"

# ---------------------------------------------------------------------------
# 5. Cleanup + convert to template
# ---------------------------------------------------------------------------
log "Cleaning machine identity/cache before templating"
LANG="${ANSIBLE_LANG}" LC_ALL="${ANSIBLE_LANG}" LC_CTYPE="${ANSIBLE_LANG}" PYTHONUTF8=1 PYTHONIOENCODING=UTF-8 ANSIBLE_HOST_KEY_CHECKING=False \
  ansible -i "${IP}," -u "${SSH_USER}" --private-key "${PROVISION_SSH_PRIVKEY}" -m raw -a "
    set -e
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /tmp/* /var/tmp/*
    rm -f /etc/ssh/ssh_host_*
    ssh-keygen -A
    : > /etc/machine-id
    rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true
    history -c || true
  " all

log "Stopping CT ${BUILD_VMID}"
stop_upid="$(pve_api POST "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}/status/stop" | pve_json_data)"
pve_wait_task "$PVE_NODE" "$stop_upid" 180

if [ "$FINAL_STORAGE" != "$ROOTFS_STORAGE" ]; then
  log "Moving rootfs from ${ROOTFS_STORAGE} to ${FINAL_STORAGE}"
  move_upid="$(
    pve_api POST "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}/move_volume" \
      --data-urlencode "volume=rootfs" \
      --data-urlencode "storage=${FINAL_STORAGE}" \
      --data-urlencode "delete=1" \
      | pve_json_data
  )"
  pve_wait_task "$PVE_NODE" "$move_upid" 600
fi

log "Converting CT ${BUILD_VMID} to template"
template_upid="$(pve_api POST "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}/template" | pve_json_data)"
if [ -n "$template_upid" ]; then
  pve_wait_task "$PVE_NODE" "$template_upid" 180
else
  # Some Proxmox versions complete this endpoint synchronously and return no UPID.
  template_flag_ready=0
  for _ in $(seq 1 10); do
    if pve_api GET "/nodes/${PVE_NODE}/lxc/${BUILD_VMID}/config" \
        | python3 -c 'import json,sys; cfg=json.load(sys.stdin).get("data", {}); sys.exit(0 if str(cfg.get("template", 0)) == "1" else 1)'; then
      template_flag_ready=1
      break
    fi
    sleep 1
  done
  if [ "$template_flag_ready" -ne 1 ]; then
    echo "Template conversion did not return a task id and template flag is not set." >&2
    exit 1
  fi
fi

cat <<EOF

============================================================
 Done!
 Node:          ${PVE_NODE}
 Template VMID: ${BUILD_VMID}
 Clone with:    pct clone ${BUILD_VMID} <NEW_VMID> --hostname my-new-ct --full
============================================================
EOF
