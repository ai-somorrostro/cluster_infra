#!/usr/bin/env bash
# setup_watchdog.sh — Configures the watchdog daemon for the Proxmox i6300esb. Runs INSIDE the VM.
# Used by vm/vm_watchdog.sh, but can be run by hand on VMs without qemu-guest-agent.
set -euo pipefail

usage() {
  cat <<EOF
Usage: sudo $(basename "$0")

Installs the watchdog package, configures it for /dev/watchdog with the
i6300esb module and enables the service. Idempotent.
The hardware is added from the host: vm/vm_watchdog.sh <vmid>
After configuring, the VM must be POWERED OFF and STARTED (a reboot is not enough).
EOF
}

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { usage; exit 0; }
[[ "$(id -u)" -eq 0 ]] || { echo "Error: run it as root" >&2; exit 1; }

echo "[1/4] Installing the watchdog package..."
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
  apt-get -o DPkg::Lock::Timeout=300 -q update
  apt-get -o DPkg::Lock::Timeout=300 -y -q install watchdog
elif command -v dnf >/dev/null; then
  dnf install -y watchdog
elif command -v yum >/dev/null; then
  yum install -y watchdog
else
  echo "Error: unsupported package manager (apt, dnf or yum)" >&2
  exit 1
fi

echo "[2/4] Configuring /etc/watchdog.conf..."
[[ -f /etc/watchdog.conf ]] && cp -a /etc/watchdog.conf /etc/watchdog.conf.bak
if ! grep -q "^watchdog-device" /etc/watchdog.conf 2>/dev/null; then
  cat >>/etc/watchdog.conf <<'EOF'

# Added by setup_watchdog.sh (infra)
watchdog-device = /dev/watchdog
log-dir         = /var/log/watchdog
realtime        = yes
priority        = 1
EOF
fi

echo "[3/4] Kernel module i6300esb..."
echo i6300esb >/etc/modules-load.d/watchdog.conf
if [[ -f /etc/default/watchdog ]] && grep -q "^watchdog_module" /etc/default/watchdog; then
  sed -i 's/^watchdog_module=.*/watchdog_module="i6300esb"/' /etc/default/watchdog
else
  echo 'watchdog_module="i6300esb"' >>/etc/default/watchdog
fi
modprobe i6300esb 2>/dev/null || echo "    (the module will load once the VM has the hardware: power off + start)"

echo "[4/4] Enabling the service..."
systemctl daemon-reload
systemctl enable watchdog
if [[ -e /dev/watchdog ]]; then
  systemctl restart watchdog || true
  echo "[✓] /dev/watchdog present; service: $(systemctl is-active watchdog || true)"
else
  echo "[!] /dev/watchdog does not exist yet: power the VM off and start it from Proxmox"
fi
