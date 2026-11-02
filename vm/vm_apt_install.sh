#!/usr/bin/env bash
# vm_apt_install.sh — Installs apt packages (and optionally Docker) on one or more VMs
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <vmid|range>... [-- package...]

Installs packages with apt-get inside the VMs (via qemu-guest-agent). Waits for
the apt locks to be released instead of deleting them, and checks afterwards with
dpkg-query that every package got installed.

Script options:
  --with-docker      Also install Docker CE (guest/install_docker.sh)
  --docker-user U    User to add to the docker group (repeatable)
  --upgrade          Also run apt-get upgrade
  --timeout S        Max seconds per apt operation (default 900)

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -f, --file F      Read VMs from a file (one per line, # comments)
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") 100 101 102 -- vim curl htop
  $(basename "$0") --with-docker --docker-user telecomunicaciones 120-125
  $(basename "$0") --with-docker 100 -- git make
EOF
}

WITH_DOCKER=0
DOCKER_USERS=()
UPGRADE=0
APT_TIMEOUT=900

while (($# > 0)); do
  case "$1" in
    --with-docker) WITH_DOCKER=1; shift ;;
    --docker-user) need_value "$1" "${2:-}"; DOCKER_USERS+=("$2"); shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --timeout) need_value "$1" "${2:-}"; [[ "$2" =~ ^[0-9]+$ ]] || die_usage "--timeout requires seconds"; APT_TIMEOUT="$2"; shift 2 ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done

PACKAGES=("${EXTRA_ARGS[@]}")
((${#PACKAGES[@]} > 0 || WITH_DOCKER || UPGRADE)) || die_usage "Give packages after '--', --with-docker or --upgrade"
for p in "${PACKAGES[@]}"; do
  [[ "$p" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+:=~_-]*$ ]] || die_usage "Invalid package name: '$p'"
done

prepare_run none
((${#PACKAGES[@]} > 0)) && echo "Packages: ${PACKAGES[*]}"

DOCKER_SCRIPT="$INFRA_ROOT/guest/install_docker.sh"
# apt/dpkg go through guest_exec_detached (systemd-run): if a package restarts the
# qemu-guest-agent, apt does not die with it. NEEDRESTART_SUSPEND avoids needless restarts.
APT=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -o DPkg::Lock::Timeout=300 -y -q)

for VMID in "${VMIDS[@]}"; do
  vm_begin "$VMID" || continue
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without agent"; continue; }

  step --warn "Disable 'deb cdrom' in sources.list" guest_sh "$VMID" \
    "[ ! -f /etc/apt/sources.list ] || sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list"
  step --warn "Internet connectivity" guest_sh_query "$VMID" \
    "getent hosts deb.debian.org >/dev/null || getent hosts archive.ubuntu.com >/dev/null"
  GUEST_TIMEOUT=$APT_TIMEOUT step --warn "dpkg --configure -a" guest_exec_detached "$VMID" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 dpkg --configure -a
  GUEST_TIMEOUT=$APT_TIMEOUT step "apt-get update" guest_exec_detached "$VMID" "${APT[@]}" update || { vm_fail "apt-get update failed"; continue; }

  if ((UPGRADE)); then
    GUEST_TIMEOUT=$APT_TIMEOUT step "apt-get upgrade" guest_exec_detached "$VMID" "${APT[@]}" upgrade || { vm_fail "apt-get upgrade failed"; continue; }
  fi

  if ((${#PACKAGES[@]} > 0)); then
    GUEST_TIMEOUT=$APT_TIMEOUT step "apt-get install ${PACKAGES[*]}" guest_exec_detached "$VMID" "${APT[@]}" install "${PACKAGES[@]}" ||
      { vm_fail "apt-get install failed"; continue; }
    if [[ "$DRY_RUN" != 1 ]]; then
      missing=()
      for p in "${PACKAGES[@]}"; do
        # shellcheck disable=SC2016  # ${Status} is the dpkg-query format, not a variable
        if ! guest_query "$VMID" dpkg-query -W -f='${Status}' "${p%%=*}" >/dev/null || [[ "$GUEST_OUT" != "install ok installed" ]]; then
          missing+=("$p")
        fi
      done
      ((${#missing[@]} == 0)) || { vm_fail "not installed: ${missing[*]}"; continue; }
    fi
  fi

  if ((WITH_DOCKER)); then
    step "Upload install_docker.sh" guest_upload "$VMID" "$DOCKER_SCRIPT" /tmp/install_docker.sh 0755 || { vm_fail "could not upload the Docker installer"; continue; }
    GUEST_TIMEOUT=$APT_TIMEOUT step "Install Docker" guest_exec_detached "$VMID" env NEEDRESTART_SUSPEND=1 bash /tmp/install_docker.sh "${DOCKER_USERS[@]}" ||
      { vm_fail "Docker installation failed"; continue; }
    guest_exec "$VMID" rm -f /tmp/install_docker.sh || true
  fi

  msg="${#PACKAGES[@]} package(s)"
  ((WITH_DOCKER)) && msg+=" + Docker"
  vm_ok "$msg"
done

summary
