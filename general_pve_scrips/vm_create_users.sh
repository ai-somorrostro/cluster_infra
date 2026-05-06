#!/usr/bin/env bash

# vm_create_users.sh - Create/reset users on VMs from file user:password
# Uses pvesh on Proxmox nodes, or PROXMOX_API_* + curl from any host (e.g. provisioner).

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/pve-load-env.sh"

USE_PVESH=1
if ! command -v pvesh >/dev/null 2>&1; then
  USE_PVESH=0
fi

# Parse flags
FORCE_PASSWORD_CHANGE=1
ADD_TO_DOCKER=0

while [[ "${1:-}" =~ ^-- ]]; do
  case "$1" in
    --nopass)
      FORCE_PASSWORD_CHANGE=0
      shift 1
      ;;
    --add-to-docker)
      ADD_TO_DOCKER=1
      shift 1
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ $# -lt 2 ]; then
  echo "Usage: $0 [--nopass] [--add-to-docker] <user_file> <vmid1> [vmid2] ..."
  echo "Example: $0 users.txt 127 128"
  echo "Example (no password expiry): $0 --nopass users.txt 127 128"
  echo "Example (add to docker group): $0 --add-to-docker users.txt 127 128"
  echo ""
  echo "File format: username:password (one per line)"
  echo ""
  if [ "$USE_PVESH" -eq 0 ]; then
    echo "Remote mode (no pvesh on this host): set API credentials, e.g.:"
    echo "  export PROXMOX_API_URL=\"https://pve.example.com:8006\""
    echo "  export PROXMOX_API_TOKEN_ID=\"user@pam!tokenid\""
    echo "  export PROXMOX_API_TOKEN_SECRET=\"secret\""
    echo "Credentials: repo .env, VARS_FILE, or default templates/.../variables.pkrvars.hcl"
  fi
  exit 1
fi

USER_FILE=$1
shift 1
VMIDS=("$@")

if [ ! -f "$USER_FILE" ]; then
  echo "Error: file '$USER_FILE' does not exist"
  exit 1
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

init_proxmox_api_curl() {
  if [ -z "$PROXMOX_API_URL" ] || [ -z "$PROXMOX_API_TOKEN_ID" ] || [ -z "$PROXMOX_API_TOKEN_SECRET" ]; then
    cat >&2 <<'EOF'
Missing Proxmox API credentials (pvesh not available on this host).

Set:
  PROXMOX_API_URL          e.g. https://pve.example.com:8006
  PROXMOX_API_TOKEN_ID     e.g. root@pam!provisioner
  PROXMOX_API_TOKEN_SECRET

Or set VARS_FILE to a variables.pkrvars.hcl (see lib/pve-load-env.sh defaults) with:
  proxmox_api_url
  proxmox_api_token_id
  proxmox_api_token_secret
EOF
    return 1
  fi

  PVE_API_URL="${PROXMOX_API_URL%/}"
  PVE_API_URL="${PVE_API_URL%/api2/json}/api2/json"
  PVE_AUTH_HEADER="Authorization: PVEAPIToken=${PROXMOX_API_TOKEN_ID}=${PROXMOX_API_TOKEN_SECRET}"
}

pve_api_get() {
  curl -skS -H "$PVE_AUTH_HEADER" "${PVE_API_URL}${1}"
}

pve_api_post_exec() {
  local path=$1
  shift
  local curl_args=(-skS -X POST -H "$PVE_AUTH_HEADER")
  for arg in "$@"; do
    curl_args+=(--data-urlencode "command=${arg}")
  done
  curl "${curl_args[@]}" "${PVE_API_URL}${path}"
}

wait_for_pid() {
  local pid=$1
  local timeout=$2
  local count=0
  local status=""

  while [ "$count" -lt "$timeout" ]; do
    sleep 1
    if [ "$USE_PVESH" -eq 1 ]; then
      status=$(pvesh get "/nodes/${NODE}/qemu/${VMID}/agent/exec-status" --pid "$pid" --output-format json 2>/dev/null || echo "")
    else
      status=$(pve_api_get "/nodes/${NODE}/qemu/${VMID}/agent/exec-status?pid=${pid}" 2>/dev/null || echo "")
    fi
    if echo "$status" | grep -q '"exited"'; then
      echo "$status"
      return 0
    fi
    count=$((count + 1))
  done
  echo ""
  return 1
}

run_cmd() {
  local cmd_arr=("$@")
  local out=""
  local pid=""
  local res=""
  local exitcode=1

  if [ "$USE_PVESH" -eq 1 ]; then
    local pvesh_args=""
    local escaped_arg
    for arg in "${cmd_arr[@]}"; do
      escaped_arg=$(echo "$arg" | sed 's/"/\\"/g')
      pvesh_args="$pvesh_args --command \"$escaped_arg\""
    done
    out=$(eval pvesh create "/nodes/${NODE}/qemu/${VMID}/agent/exec" "$pvesh_args" --output-format json 2>/dev/null)
  else
    out=$(pve_api_post_exec "/nodes/${NODE}/qemu/${VMID}/agent/exec" "${cmd_arr[@]}" 2>/dev/null || echo "")
  fi

  pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+' || true)
  if [ -z "$pid" ]; then
    return 1
  fi
  res=$(wait_for_pid "$pid" 30)
  exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
  return "$exitcode"
}

if [ "$USE_PVESH" -eq 0 ]; then
  init_proxmox_api_curl || exit 1
fi

# --- Per-VM loop ---
for VMID in "${VMIDS[@]}"; do
  echo -e "\n${YELLOW}=========================================="
  echo "Resolving VM $VMID..."

  if [ "$USE_PVESH" -eq 1 ]; then
    VM_INFO=$(
      pvesh get /cluster/resources --type vm --output-format json \
        | python3 -c "import sys, json
raw = json.load(sys.stdin)
vms = raw if isinstance(raw, list) else raw.get('data', [])
vm = next((i for i in vms if i.get('vmid') == $VMID), None)
print(f\"{vm.get('node', 'N/A')}|{vm.get('name', 'N/A')}\") if vm else print('N/A|N/A')"
    )
  else
    VM_INFO=$(
      pve_api_get "/cluster/resources?type=vm" \
        | python3 -c "import sys, json
raw = json.load(sys.stdin)
vms = raw if isinstance(raw, list) else raw.get('data', [])
vm = next((i for i in vms if i.get('vmid') == $VMID), None)
print(f\"{vm.get('node', 'N/A')}|{vm.get('name', 'N/A')}\") if vm else print('N/A|N/A')"
    )
  fi

  NODE=$(echo "$VM_INFO" | cut -d'|' -f1)
  VM_NAME=$(echo "$VM_INFO" | cut -d'|' -f2)

  if [ "$NODE" = "N/A" ] || [ -z "$NODE" ]; then
    echo -e "${RED}[x]${NC} VM $VMID not found on any cluster node."
    continue
  fi

  echo "Node: $NODE | Name: $VM_NAME | VMID: $VMID"
  echo -e "==========================================${NC}"

  if [ "$USE_PVESH" -eq 1 ]; then
    VM_STATUS=$(pvesh get "/nodes/${NODE}/qemu/${VMID}/status/current" --output-format json 2>/dev/null || echo "")
  else
    VM_STATUS=$(pve_api_get "/nodes/${NODE}/qemu/${VMID}/status/current" 2>/dev/null || echo "")
  fi
  if ! echo "$VM_STATUS" | grep -q '"status":"running"' || ! echo "$VM_STATUS" | grep -q '"agent":1'; then
    echo -e "${RED}[x]${NC} VM not running or QEMU guest agent not ready (need running + agent reported active)"
    continue
  fi

  echo -n "Backup SSH config... "
  run_cmd "cp" "/etc/ssh/sshd_config" "/etc/ssh/sshd_config.bak" && echo -e "${GREEN}[OK]${NC}" || echo -e "${YELLOW}[WARN]${NC}"

  echo -n "Enabling SSH password auth... "
  if run_cmd "sh" "-c" "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config && grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config"; then
    echo -e "${GREEN}[OK]${NC}"
  else
    echo -e "${YELLOW}[WARN]${NC}"
  fi

  echo -n "Restarting SSH... "
  run_cmd "systemctl" "restart" "sshd" >/dev/null 2>&1 || true
  run_cmd "systemctl" "restart" "ssh" >/dev/null 2>&1 || true
  sleep 2
  echo -e "${GREEN}[OK]${NC}"

  DOCKER_EXISTS=0
  if [ "$ADD_TO_DOCKER" -eq 1 ]; then
    echo -n "Checking docker group... "
    if run_cmd "getent" "group" "docker"; then
      DOCKER_EXISTS=1
      echo -e "${GREEN}[OK]${NC}"
    else
      echo -e "${RED}[missing]${NC}"
      echo -e "${YELLOW}[!]${NC} --add-to-docker was set but group docker does not exist in the guest"
    fi
  fi

  echo ""

  while IFS=':' read -r username password || [ -n "$username" ]; do
    username=$(echo "$username" | sed 's/^[[:space:]"]*//;s/[[:space:]"]*$//')
    password=$(echo "$password" | sed 's/^[[:space:]"]*//;s/[[:space:]"]*$//')

    if [ -z "$username" ] || [[ "$username" =~ ^# ]]; then
      continue
    fi

    if [ -z "$password" ]; then
      echo -e "${YELLOW}[!]${NC} $username: missing password, skipping"
      continue
    fi

    echo -e "${YELLOW}User: $username${NC}"

    echo -n "  - Checking... "
    if run_cmd "id" "$username"; then
      echo "already exists"
    else
      echo -n "creating... "
      if run_cmd "useradd" "-m" "-s" "/bin/bash" "$username"; then
        echo -e "${GREEN}[OK]${NC}"
      else
        echo -e "${RED}[ERROR]${NC}"
        continue
      fi
    fi

    echo -n "  - Password... "
    if run_cmd "sh" "-c" "echo '$username:$password' | chpasswd"; then
      echo -e "${GREEN}[OK]${NC}"
    else
      echo -e "${RED}[ERROR]${NC}"
    fi

    echo -n "  - sudo group... "
    if run_cmd "usermod" "-aG" "sudo" "$username"; then
      echo -e "${GREEN}[OK]${NC}"
    else
      echo -e "${YELLOW}[WARN]${NC}"
    fi

    if [ "$DOCKER_EXISTS" -eq 1 ]; then
      echo -n "  - docker group... "
      if run_cmd "usermod" "-aG" "docker" "$username"; then
        echo -e "${GREEN}[OK]${NC}"
      else
        echo -e "${YELLOW}[WARN]${NC}"
      fi
    fi

    if [ "$FORCE_PASSWORD_CHANGE" -eq 1 ]; then
      echo -n "  - Expire password... "
      if run_cmd "passwd" "--expire" "$username"; then
        echo -e "${GREEN}[OK]${NC}"
      else
        echo -e "${YELLOW}[WARN]${NC}"
      fi
    else
      echo "  - Password not expired (--nopass)"
    fi

    echo ""
  done <"$USER_FILE"
done

echo -e "${GREEN}=========================================="
echo "Done"
echo "==========================================${NC}"
