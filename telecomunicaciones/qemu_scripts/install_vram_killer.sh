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

LIMIT_MIB_RAW=${1:-8192}
CHECK_INTERVAL_MS_RAW=${2:-5000}

# Convertir a decimal para evitar interpretación octal (ej: 0500 -> 500)
# Usar sed para quitar ceros iniciales
LIMIT_MIB=$(echo "$LIMIT_MIB_RAW" | sed 's/^0*//')
CHECK_INTERVAL_MS=$(echo "$CHECK_INTERVAL_MS_RAW" | sed 's/^0*//')

# Si quedó vacío después de quitar ceros, usar valores por defecto
[ -z "$LIMIT_MIB" ] && LIMIT_MIB=8192
[ -z "$CHECK_INTERVAL_MS" ] && CHECK_INTERVAL_MS=5000

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

# Copiar script a ubicación permanente
INSTALL_DIR="/usr/local/bin"
mkdir -p "$INSTALL_DIR"
cp "$VRAM_KILLER_SCRIPT" "$INSTALL_DIR/vram_killer.sh"
chmod +x "$INSTALL_DIR/vram_killer.sh"
VRAM_KILLER_SCRIPT="$INSTALL_DIR/vram_killer.sh"

# Verificar si ya está instalado
if [ -f /etc/systemd/system/vram-killer.service ]; then
    echo "Service already installed. Stopping and updating..."
    systemctl stop vram-killer.service 2>/dev/null || true
    systemctl disable vram-killer.service 2>/dev/null || true
    rm -f /etc/systemd/system/vram-killer.service
    systemctl daemon-reload
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
echo "Script location: $VRAM_KILLER_SCRIPT"
echo ""

# Crear servicio systemd
# IMPORTANTE: Usar comillas para asegurar que los argumentos se pasen correctamente
cat > /etc/systemd/system/vram-killer.service <<EOF
[Unit]
Description=VRAM Killer - Kills processes when total VRAM exceeds limit (kills latest)
After=network.target

[Service]
Type=simple
ExecStart=$VRAM_KILLER_SCRIPT daemon ${LIMIT_MIB} ${CHECK_INTERVAL_MS}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Verificar que el servicio se creó correctamente
echo "Verifying service file..."
cat /etc/systemd/system/vram-killer.service | grep ExecStart

# Recargar systemd (importante después de modificar el servicio)
systemctl daemon-reload

# Verificar que el servicio tiene la ruta correcta
SERVICE_EXEC=$(systemctl show vram-killer.service -p ExecStart --value | awk '{print $1}')
if [ "$SERVICE_EXEC" != "$VRAM_KILLER_SCRIPT" ]; then
    echo -e "${RED}Error: Service ExecStart path mismatch!${NC}"
    echo "Expected: $VRAM_KILLER_SCRIPT"
    echo "Got: $SERVICE_EXEC"
    exit 1
fi

# Verificar que los argumentos son correctos
SERVICE_ARGS=$(systemctl show vram-killer.service -p ExecStart --value | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print ""}')
echo "Service will execute: $VRAM_KILLER_SCRIPT $SERVICE_ARGS"

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
