#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

wait_for_apt() {
  cloud-init status --wait >/dev/null 2>&1 || true

  while pgrep -x apt >/dev/null 2>&1 \
    || pgrep -x apt-get >/dev/null 2>&1 \
    || pgrep -x dpkg >/dev/null 2>&1 \
    || pgrep -x unattended-upgrade >/dev/null 2>&1 \
    || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
    || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
    || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
    || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 2
  done
}

wait_for_apt
apt-get update
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  cowsay \
  curl \
  dnsutils \
  fail2ban \
  fortune-mod \
  git \
  gnupg \
  htop \
  jq \
  lolcat \
  net-tools \
  nfs-common \
  qemu-guest-agent \
  unattended-upgrades \
  vim \
  wget

systemctl enable qemu-guest-agent
