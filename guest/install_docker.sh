#!/usr/bin/env bash
# install_docker.sh — Installs Docker CE (official repo) on Ubuntu/Debian. Runs INSIDE the VM.
# Used by vm/vm_apt_install.sh --with-docker, but can also be run by hand.
set -euo pipefail

usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [user...]

Installs docker-ce, docker-compose-plugin and buildx from the official Docker
repository (detects Ubuntu or Debian) and adds the given users to the docker group.
Idempotent: if Docker is already installed it only updates packages and users.
EOF
}

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { usage; exit 0; }
[[ "$(id -u)" -eq 0 ]] || { echo "Error: run it as root" >&2; exit 1; }

# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}" in
  ubuntu | debian) DISTRO="$ID" ;;
  *)
    case "${ID_LIKE:-}" in
      *ubuntu*) DISTRO=ubuntu ;;
      *debian*) DISTRO=debian ;;
      *) echo "Error: unsupported distribution (${ID:-unknown})" >&2; exit 1 ;;
    esac
    ;;
esac

export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -o DPkg::Lock::Timeout=300 -y -q)

echo "[*] Removing conflicting packages (if any)..."
for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  dpkg -s "$p" >/dev/null 2>&1 && "${APT[@]}" remove "$p" || true
done

echo "[*] Setting up the Docker repository ($DISTRO ${VERSION_CODENAME:-})..."
"${APT[@]}" update
"${APT[@]}" install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO} ${VERSION_CODENAME} stable" \
  >/etc/apt/sources.list.d/docker.list

echo "[*] Installing Docker..."
"${APT[@]}" update
"${APT[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

for u in "$@"; do
  if id "$u" >/dev/null 2>&1; then
    usermod -aG docker "$u" && echo "[✓] $u added to the docker group"
  else
    echo "[!] User $u does not exist; not added to docker"
  fi
done

docker --version
echo "[✓] Docker installed"
