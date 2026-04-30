#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Wait until cloud-init/apt daily jobs release dpkg/apt locks.
wait_for_apt_locks() {
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
    || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
    || sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 2
  done
}

wait_for_apt_locks
apt-get update
apt-get install -y \
  qemu-guest-agent \
  curl \
  wget \
  jq \
  htop \
  vim \
  net-tools \
  dnsutils \
  git \
  fail2ban \
  unattended-upgrades \
  nfs-common \
  apt-transport-https \
  ca-certificates \
  gnupg

systemctl enable qemu-guest-agent
