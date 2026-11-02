#!/usr/bin/env bash
# vm_pip_cache.sh — Sets up a pip cache shared by all users (formerly install_pip_cache.sh)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <vmid|range>...

Creates a shared pip cache directory (mode 1777), sets it in /etc/pip.conf
(with a backup if it existed) and exports PIP_CACHE_DIR in /etc/profile.d.
Installs python3-pip if missing.

Script options:
  --dir D           Cache directory (default /opt/pip-cache)

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (one per line, # comments)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") 100 101 102
  $(basename "$0") --dir /srv/pip-cache 120-125
EOF
}

CACHE_DIR="/opt/pip-cache"

while (($# > 0)); do
  case "$1" in
    --dir) need_value "$1" "${2:-}"; CACHE_DIR="$2"; shift 2 ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

[[ "$CACHE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die_usage "Invalid directory: $CACHE_DIR"

prepare_run none
echo "Cache: $CACHE_DIR"

PIP_CONF=$'[global]\n'"cache-dir = ${CACHE_DIR}"
PROFILE="export PIP_CACHE_DIR=${CACHE_DIR}"

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without agent"; continue; }

  if ! guest_sh_query "$VMID" "command -v pip3 >/dev/null || python3 -m pip --version >/dev/null 2>&1"; then
    GUEST_TIMEOUT=900 step "Install python3-pip" guest_exec_detached "$VMID" \
      env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 sh -c \
      "apt-get -o DPkg::Lock::Timeout=300 -q update && apt-get -o DPkg::Lock::Timeout=300 -y -q install python3-pip" ||
      { vm_fail "could not install pip"; continue; }
  fi

  step "Create $CACHE_DIR (1777)" guest_sh "$VMID" "mkdir -p '$CACHE_DIR' && chmod 1777 '$CACHE_DIR'" ||
    { vm_fail "could not create the directory"; continue; }
  step --warn "Backup /etc/pip.conf" guest_sh "$VMID" "[ ! -f /etc/pip.conf ] || cp -a /etc/pip.conf /etc/pip.conf.bak"
  step "Write /etc/pip.conf" guest_write_file "$VMID" /etc/pip.conf "$PIP_CONF"$'\n' 0644 ||
    { vm_fail "could not write /etc/pip.conf"; continue; }
  step "Write /etc/profile.d/pip-cache.sh" guest_write_file "$VMID" /etc/profile.d/pip-cache.sh "$PROFILE"$'\n' 0644 ||
    { vm_fail "could not write profile.d"; continue; }

  if [[ "$DRY_RUN" != 1 ]]; then
    guest_sh_query "$VMID" "python3 -m pip config list 2>/dev/null || pip3 config list 2>/dev/null" || true
    if grep -q "cache-dir='\?${CACHE_DIR}" <<<"$GUEST_OUT"; then
      echo "  pip config: $(grep cache-dir <<<"$GUEST_OUT")"
    else
      log_warn "pip does not report the cache-dir (may be normal with old pip versions)"
    fi
  fi
  vm_ok "cache-dir = $CACHE_DIR"
done

summary
