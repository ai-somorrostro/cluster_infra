#!/bin/bash
# install_vram_killer.sh
# Install/Update/Uninstall vram-killer service
#
# Install/Update: sudo ./install_vram_killer.sh <limit_mb> [check_interval]
# Uninstall:      sudo ./install_vram_killer.sh uninstall

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LIMIT_MIB=${1:-8192}
CHECK_INTERVAL_MS=${2:-5000}

# Verificar root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Modo desinstalar
if [ "$1" == "uninstall" ] || [ "$1" == "remove" ]; then
    if [ ! -f /etc/systemd/system/vram-killer.service ]; then
        echo "Service vram-killer is not installed"
        exit 0
    fi
    echo "Stopping and removing vram-killer service..."
    systemctl stop vram-killer.service 2>/dev/null || true
    systemctl disable vram-killer.service 2>/dev/null || true
    rm -f /etc/systemd/system/vram-killer.service
    systemctl daemon-reload
    echo "Service uninstalled. Log file /var/log/vram_killer.log was not removed."
    exit 0
fi

# Verificar argumentos
if [ -z "$1" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "Usage:"
    echo "  Install/Update: $0 <limit_mib> [check_interval_ms]"
    echo "  Uninstall:      $0 uninstall"
    echo ""
    echo "Arguments:"
    echo "  limit_mib         - Total VRAM limit in MiB (mebibytes)"
    echo "                      Examples: 8192 MiB = 8 GiB, 4096 MiB = 4 GiB"
    echo "  check_interval_ms - Check interval in milliseconds (default: 5000 = 5 seconds)"
    echo ""
    echo "Examples:"
    echo "  $0 8192 5000   # Install/update with 8192 MiB (8 GiB) limit, check every 5000ms (5s)"
    echo "  $0 8192 2000   # Install/update with 8192 MiB (8 GiB) limit, check every 2000ms (2s)"
    echo "  $0 uninstall   # Uninstall service"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VRAM_KILLER_SCRIPT="$SCRIPT_DIR/vram_killer.sh"

# Verificar que el script existe
if [ ! -f "$VRAM_KILLER_SCRIPT" ]; then
    echo -e "${RED}Error: vram_killer.sh not found in $SCRIPT_DIR${NC}"
    exit 1
fi

# Hacer ejecutable
chmod +x "$VRAM_KILLER_SCRIPT"

# Verificar si ya está instalado
if [ -f /etc/systemd/system/vram-killer.service ]; then
    echo "Service already installed. Updating configuration..."
    systemctl stop vram-killer.service 2>/dev/null || true
    echo "=========================================="
    echo "Updating VRAM Killer Service"
    echo "=========================================="
else
    echo "=========================================="
    echo "Installing VRAM Killer Service"
    echo "=========================================="
fi
echo "VRAM limit: ${LIMIT_MIB} MiB"
echo "Check interval: ${CHECK_INTERVAL_MS}ms"
echo ""

# Crear servicio systemd
cat > /etc/systemd/system/vram-killer.service <<EOF
[Unit]
Description=VRAM Killer - Kills processes when total VRAM exceeds limit (kills latest)
After=network.target

[Service]
Type=simple
ExecStart=$VRAM_KILLER_SCRIPT daemon $LIMIT_MIB $CHECK_INTERVAL_MS
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Recargar systemd
systemctl daemon-reload

# Habilitar servicio
systemctl enable vram-killer.service

# Iniciar servicio
systemctl start vram-killer.service
sleep 2

echo ""
echo "=========================================="
echo "Installation/Update completed"
echo "=========================================="
echo ""
echo "Useful commands:"
echo "  Status:        sudo systemctl status vram-killer"
echo "  Logs:          sudo journalctl -u vram-killer -f"
echo "  Log file:      tail -f /var/log/vram_killer.log"
echo "  Stop:          sudo systemctl stop vram-killer"
echo "  Restart:       sudo systemctl restart vram-killer"
echo "  Update limit:  sudo $0 <new_limit_mb> [check_interval]"
echo "  Uninstall:     sudo $0 uninstall"
