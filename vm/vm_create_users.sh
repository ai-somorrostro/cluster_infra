#!/usr/bin/env bash
# vm_create_users.sh — Creates/resets users on VMs and enables SSH password login
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options] --users file <vmid|range>...
  $(basename "$0") [options] <vmid|range>...          # only enable SSH password login

Creates the users in the file (or resets their password if they exist), adds
them to sudo and, by default, forces a password change on first login. It also
enables SSH password login (replaces the old vm_enable_password_ssh.sh).

User file format: 'username:password' per line (# comments).
See vm/users.txt.example. The real file is NOT committed.

Script options:
  --users F           user:password file
  --no-expire         Do not force a password change on first login (formerly --nopass)
  --add-to-docker     Add the users to the docker group (if it exists)
  --no-ssh-password   Do not touch the SSH configuration

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (one per line, # comments)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") --users users.txt 127 128
  $(basename "$0") --users users.txt --no-expire --add-to-docker 120-125
  $(basename "$0") 130                       # SSH password login only
EOF
}

USERS_FILE=""
EXPIRE=1
ADD_DOCKER=0
SSH_PASSWORD=1

while (($# > 0)); do
  case "$1" in
    --users) need_value "$1" "${2:-}"; USERS_FILE="$2"; shift 2 ;;
    --no-expire | --nopass) EXPIRE=0; shift ;;
    --add-to-docker) ADD_DOCKER=1; shift ;;
    --no-ssh-password) SSH_PASSWORD=0; shift ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

[[ -n "$USERS_FILE" || "$SSH_PASSWORD" == 1 ]] || die_usage "Nothing to do: give --users or drop --no-ssh-password"

# Load and validate the user file before touching any VM
USERS=()
declare -A PASSWORDS=()
if [[ -n "$USERS_FILE" ]]; then
  [[ -f "$USERS_FILE" ]] || die_usage "User file not found: $USERS_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    u="$(sed 's/^[[:space:]"]*//;s/[[:space:]"]*$//' <<<"${line%%:*}")"
    p="$(sed 's/^[[:space:]"]*//;s/[[:space:]"]*$//' <<<"${line#*:}")"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username in $USERS_FILE: '$u'"
    [[ "$line" == *:* && -n "$p" ]] || die "Missing password for '$u' in $USERS_FILE"
    USERS+=("$u")
    PASSWORDS[$u]="$p"
  done <"$USERS_FILE"
  ((${#USERS[@]} > 0)) || die "No users in $USERS_FILE"
fi

prepare_run none
[[ -n "$USERS_FILE" ]] && echo "Users: ${USERS[*]}"

# High-priority drop-in (01-*): sshd keeps the FIRST value it reads, and Ubuntu ships
# 50-cloud-init.conf with PasswordAuthentication no (a 99-* drop-in loses against it).
SSH_SCRIPT='set -e
if grep -qE "^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d" /etc/ssh/sshd_config; then
  printf "PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n" > /etc/ssh/sshd_config.d/01-password-auth.conf
else
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
  sed -i -E "s/^#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/; s/^#?[[:space:]]*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/" /etc/ssh/sshd_config
  grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
fi
mkdir -p /run/sshd
sshd -t
systemctl restart ssh 2>/dev/null || systemctl restart sshd
sshd -T 2>/dev/null | grep -qi "^passwordauthentication yes"'

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without agent"; continue; }

  if ((SSH_PASSWORD)); then
    step "Enable SSH password login" guest_sh "$VMID" "$SSH_SCRIPT" || { vm_fail "could not configure SSH"; continue; }
  fi

  HAS_DOCKER=0
  if ((ADD_DOCKER)); then
    if guest_query "$VMID" getent group docker >/dev/null; then
      HAS_DOCKER=1
    else
      log_warn "--add-to-docker: the docker group does not exist in the VM (is Docker installed?)"
    fi
  fi

  errors=0
  for u in "${USERS[@]}"; do
    echo "  User ${C_BOLD}${u}${C_NC}"
    if guest_query "$VMID" id "$u" >/dev/null; then
      echo "    already exists: resetting the password"
    else
      step "  Create" guest_exec "$VMID" useradd -m -s /bin/bash "$u" || { errors=$((errors + 1)); continue; }
    fi
    GUEST_STDIN="${u}:${PASSWORDS[$u]}"$'\n' step "  Password" guest_exec "$VMID" chpasswd || errors=$((errors + 1))
    step --warn "  sudo group" guest_exec "$VMID" usermod -aG sudo "$u"
    ((HAS_DOCKER)) && step --warn "  docker group" guest_exec "$VMID" usermod -aG docker "$u"
    ((EXPIRE)) && step --warn "  Force change on first login" guest_exec "$VMID" passwd --expire "$u"
  done

  if ((errors > 0)); then
    vm_fail "$errors user(s) with errors"
  else
    msg="${#USERS[@]} user(s)"
    ((SSH_PASSWORD)) && msg+=", SSH password login"
    vm_ok "$msg"
  fi
done

summary
