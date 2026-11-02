#!/usr/bin/env bash
# install_vram_killer.sh — Installs/updates/uninstalls the vram-killer systemd service. Runs INSIDE the VM.
# From the host: vm/vm_install_vram_killer.sh --limit <MiB> <vmid>...
set -euo pipefail

SERVICE=/etc/systemd/system/vram-killer.service
TARGET=/usr/local/bin/vram_killer.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage:
  sudo $(basename "$0") <limit_MiB> [interval_ms]   # install or update
  sudo $(basename "$0") uninstall                   # uninstall

Copies vram_killer.sh (from the same directory) to $TARGET and creates the
vram-killer service (starts at boot and restarts if it dies).

Examples:
  sudo $(basename "$0") 8192          # 8 GiB, checking every 5 s
  sudo $(basename "$0") 8192 2000     # every 2 s
EOF
}

case "${1:-}" in
  "" | -h | --help) usage; exit 0 ;;
esac
[[ "$(id -u)" -eq 0 ]] || { echo "Error: run it as root" >&2; exit 1; }

if [[ "$1" == uninstall || "$1" == remove ]]; then
  if [[ ! -f "$SERVICE" ]]; then
    echo "vram-killer is not installed"
    exit 0
  fi
  systemctl disable --now vram-killer.service 2>/dev/null || true
  rm -f "$SERVICE"
  systemctl daemon-reload
  echo "[✓] vram-killer uninstalled (/var/log/vram_killer.log is kept)"
  exit 0
fi

LIMIT_MIB="$1"
INTERVAL_MS="${2:-5000}"
[[ "$LIMIT_MIB" =~ ^[0-9]+$ && "$INTERVAL_MS" =~ ^[0-9]+$ ]] || { echo "Error: limit and interval must be numbers" >&2; exit 1; }
LIMIT_MIB=$((10#$LIMIT_MIB))
INTERVAL_MS=$((10#$INTERVAL_MS))

[[ -f "$SCRIPT_DIR/vram_killer.sh" ]] || { echo "Error: vram_killer.sh not found in $SCRIPT_DIR" >&2; exit 1; }
command -v nvidia-smi >/dev/null || { echo "Error: nvidia-smi not available (NVIDIA drivers installed?)" >&2; exit 1; }

install -m 0755 "$SCRIPT_DIR/vram_killer.sh" "$TARGET"

if [[ -f "$SERVICE" ]]; then
  echo "[*] Updating vram-killer (limit ${LIMIT_MIB} MiB, every ${INTERVAL_MS} ms)"
  systemctl stop vram-killer.service 2>/dev/null || true
else
  echo "[*] Installing vram-killer (limit ${LIMIT_MIB} MiB, every ${INTERVAL_MS} ms)"
fi

cat >"$SERVICE" <<EOF
[Unit]
Description=VRAM Killer - kills the most recent process if total VRAM goes over ${LIMIT_MIB} MiB
After=network.target

[Service]
Type=simple
ExecStart=${TARGET} daemon ${LIMIT_MIB} ${INTERVAL_MS}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vram-killer.service
sleep 2
if systemctl is-active --quiet vram-killer.service; then
  echo "[✓] vram-killer active"
else
  echo "[!] vram-killer is not active: systemctl status vram-killer" >&2
  exit 1
fi

cat <<EOF

Useful commands:
  systemctl status vram-killer
  journalctl -u vram-killer -f
  tail -f /var/log/vram_killer.log
  sudo $0 <new_limit_MiB> [interval_ms]   # change the limit
  sudo $0 uninstall
EOF
