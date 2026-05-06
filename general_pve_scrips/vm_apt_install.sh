#!/usr/bin/env bash

# vm_apt_install.sh - Install apt packages on VMs through the Proxmox API.
# Can run from a provisioner container; does not require local pvesh/qm.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/pve-load-env.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DOCKER=0
VMIDS=()
PACKAGES=()

usage() {
  echo "Usage: $0 [--with-docker] <vmid1> [vmid2] ... -- <package1> [package2] ..."
  echo "Example: $0 100 101 102 -- vim curl htop"
  echo "Example: $0 --with-docker 100 -- vim curl htop"
  echo ""
  echo "Credentials:"
  echo "  export PROXMOX_API_URL=https://pve:8006/api2/json"
  echo "  export PROXMOX_API_TOKEN_ID='root@pam!infra'"
  echo "  export PROXMOX_API_TOKEN_SECRET='...'"
  echo ""
  echo "You can also use VARS_FILE=variables.pkrvars.hcl as a fallback."
}

shell_join() {
  python3 - "$@" <<'PY'
import shlex
import sys

try:
    print(shlex.join(sys.argv[1:]))
except AttributeError:
    print(" ".join(shlex.quote(arg) for arg in sys.argv[1:]))
PY
}

parse_args() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
  esac

  if [ $# -lt 3 ]; then
    usage
    exit 1
  fi

  if [ "${1:-}" = "--with-docker" ]; then
    INSTALL_DOCKER=1
    shift
  fi

  local parsing_vmids=1
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then
      parsing_vmids=0
      continue
    fi

    if [ "$parsing_vmids" -eq 1 ]; then
      VMIDS+=("$arg")
    else
      PACKAGES+=("$arg")
    fi
  done

  if [ ${#VMIDS[@]} -eq 0 ]; then
    echo -e "${RED}Error:${NC} You must specify at least one VMID" >&2
    exit 1
  fi

  if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo -e "${RED}Error:${NC} You must specify at least one package" >&2
    exit 1
  fi
}

guest_run() {
  local timeout="$1"
  shift

  local result
  if result="$(pve_guest_exec_wait "$NODE" "$VMID" "$timeout" "$@")"; then
    [ -z "$result" ] || pve_guest_exec_output <<<"$result"
    return 0
  fi

  local rc=$?
  [ -z "$result" ] || pve_guest_exec_output <<<"$result"
  return "$rc"
}

guest_run_quiet() {
  guest_run "$@" >/dev/null 2>&1
}

vm_status_fields() {
  python3 -c 'import json,sys
data = json.load(sys.stdin).get("data", {})
print("|".join([
    str(data.get("status", "unknown")),
    str(data.get("agent", 0)),
]))'
}

detect_vm() {
  local vm_info

  if ! vm_info="$(pve_find_vm "$VMID")"; then
    echo -e "${RED}[ERROR]${NC} VM $VMID was not found in the cluster."
    return 1
  fi

  NODE="$(echo "$vm_info" | cut -d'|' -f1)"
  VM_NAME="$(echo "$vm_info" | cut -d'|' -f2)"
  VM_TYPE="$(echo "$vm_info" | cut -d'|' -f3)"

  if [ "$VM_TYPE" != "qemu" ]; then
    echo -e "${RED}[ERROR]${NC} VMID $VMID is not a QEMU VM (type: $VM_TYPE)."
    return 1
  fi
}

verify_vm_ready() {
  local status_json fields status agent

  status_json="$(pve_vm_status_json "$NODE" "$VMID")"
  fields="$(vm_status_fields <<<"$status_json")"
  status="$(echo "$fields" | cut -d'|' -f1)"
  agent="$(echo "$fields" | cut -d'|' -f2)"

  if [ "$status" != "running" ]; then
    echo -e "${RED}[ERROR]${NC} VM $VMID is not running (status: $status)"
    return 1
  fi

  echo -e "${GREEN}[OK]${NC} VM is running"

  if [ "$agent" = "0" ] || [ "$agent" = "False" ] || [ "$agent" = "None" ]; then
    echo -e "${RED}[ERROR]${NC} qemu-guest-agent is not enabled in Proxmox"
    return 1
  fi

  echo -e "${GREEN}[OK]${NC} qemu-guest-agent is enabled"

  if ! guest_run_quiet 30 "true"; then
    echo -e "${RED}[ERROR]${NC} qemu-guest-agent is not responding inside the VM"
    return 1
  fi

  echo -e "${GREEN}[OK]${NC} qemu-guest-agent is responding"
}

install_docker() {
  echo -e "\n${YELLOW}[*]${NC} Installing Docker using the official method..."

  echo -e "${YELLOW}[*]${NC} Installing prerequisites..."
  if ! guest_run_quiet 300 "sh" "-c" "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl"; then
    echo -e "${RED}[ERROR]${NC} Failed to install prerequisites"
    return 1
  fi
  echo -e "${GREEN}[OK]${NC} Prerequisites installed"

  echo -e "${YELLOW}[*]${NC} Configuring Docker repository..."
  if ! guest_run_quiet 60 "install" "-m" "0755" "-d" "/etc/apt/keyrings"; then
    echo -e "${RED}[ERROR]${NC} Failed to create /etc/apt/keyrings"
    return 1
  fi

  if ! guest_run_quiet 120 "sh" "-c" "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"; then
    echo -e "${RED}[ERROR]${NC} Failed to download Docker GPG key"
    return 1
  fi

  if ! guest_run_quiet 30 "chmod" "a+r" "/etc/apt/keyrings/docker.asc"; then
    echo -e "${RED}[ERROR]${NC} Failed to set GPG key permissions"
    return 1
  fi

  local repo_cmd
  repo_cmd='echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list'
  if ! guest_run_quiet 60 "sh" "-c" "$repo_cmd"; then
    echo -e "${RED}[ERROR]${NC} Failed to add Docker repository"
    return 1
  fi
  echo -e "${GREEN}[OK]${NC} Repository configured"

  echo -e "${YELLOW}[*]${NC} Updating apt cache..."
  if ! guest_run_quiet 600 "apt-get" "update"; then
    echo -e "${RED}[ERROR]${NC} Failed to update apt"
    return 1
  fi
  echo -e "${GREEN}[OK]${NC} Cache updated"

  echo -e "${YELLOW}[*]${NC} Installing Docker packages..."
  if ! guest_run_quiet 900 "sh" "-c" "DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"; then
    echo -e "${RED}[ERROR]${NC} Failed to install Docker"
    return 1
  fi
  echo -e "${GREEN}[OK]${NC} Docker installed"

  echo -e "${YELLOW}[*]${NC} Verifying Docker installation..."
  if guest_run 30 "docker" "--version"; then
    echo -e "${GREEN}[OK]${NC} Docker installed correctly"
    return 0
  fi

  echo -e "${RED}[ERROR]${NC} Docker is not responding correctly"
  return 1
}

process_vm() {
  echo -e "\n${YELLOW}==========================================${NC}"
  echo "Detecting VM $VMID location..."

  if ! detect_vm; then
    return 0
  fi

  echo "Node: $NODE | Name: $VM_NAME"
  echo "VMID: $VMID"
  echo "Packages: ${PACKAGES[*]}"
  echo -e "${YELLOW}==========================================${NC}"

  echo -e "\n${YELLOW}[*]${NC} Verifying VM..."
  if ! verify_vm_ready; then
    return 0
  fi

  echo -e "\n${YELLOW}[*]${NC} Applying preventive sources.list fixes..."
  if guest_run_quiet 30 "sh" "-c" "sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list 2>/dev/null || true"; then
    echo -e "${GREEN}[OK]${NC} sources.list fixed (CDROM disabled if present)"
  else
    echo -e "${YELLOW}[WARN]${NC} Could not modify sources.list (non-critical)"
  fi

  echo -e "${YELLOW}[*]${NC} Checking internet connectivity..."
  if guest_run_quiet 30 "ping" "-c" "1" "8.8.8.8"; then
    echo -e "${GREEN}[OK]${NC} Internet OK"
  else
    echo -e "${YELLOW}[WARN]${NC} Ping failed; continuing in case apt uses a proxy or ICMP is blocked"
  fi

  echo -e "${YELLOW}[*]${NC} Cleaning stale locks..."
  guest_run_quiet 60 "sh" "-c" "rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* /var/lib/dpkg/lock-frontend" || true
  guest_run_quiet 180 "dpkg" "--configure" "-a" || true

  echo -e "\n${YELLOW}[*]${NC} Updating apt cache..."
  if ! guest_run 900 "apt-get" "update"; then
    echo -e "${RED}[ERROR]${NC} apt update failed"
    return 0
  fi
  echo -e "${GREEN}[OK]${NC} Cache updated"

  echo -e "\n${YELLOW}[*]${NC} Installing packages..."
  local install_cmd
  install_cmd="DEBIAN_FRONTEND=noninteractive apt-get install -y $(shell_join "${PACKAGES[@]}")"
  if ! guest_run 1200 "sh" "-c" "$install_cmd"; then
    echo -e "${RED}[ERROR]${NC} apt install failed"
    return 0
  fi
  echo -e "${GREEN}[OK]${NC} Installation completed"

  echo -e "\n${YELLOW}[*]${NC} Verifying installation..."
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if guest_run_quiet 30 "dpkg-query" "-W" "-f=\${Status}" "$pkg"; then
      echo -e "${GREEN}[OK]${NC} $pkg installed"
    else
      echo -e "${RED}[ERROR]${NC} $pkg does not look installed"
    fi
  done

  if [ "$INSTALL_DOCKER" -eq 1 ]; then
    install_docker || true
  fi

  echo -e "\n${YELLOW}[*]${NC} VM $VMID processed"
}

parse_args "$@"
source "${SCRIPT_DIR}/../lib/proxmox-api.sh"

for VMID in "${VMIDS[@]}"; do
  if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[ERROR]${NC} Invalid VMID: $VMID"
    continue
  fi

  NODE=""
  VM_NAME=""
  VM_TYPE=""
  process_vm
done

echo -e "\n${GREEN}==========================================${NC}"
echo "Process completed"
echo -e "==========================================${NC}"
