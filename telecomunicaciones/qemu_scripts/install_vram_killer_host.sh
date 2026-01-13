#!/bin/bash
# install_vram_killer_host.sh
# Install vram-killer service in VM from Proxmox host using pvesh
#
# Usage: sudo ./install_vram_killer_host.sh <vmid> <limit_mb> [check_interval]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VMID=$1
LIMIT_MIB_RAW=$2
CHECK_INTERVAL_MS_RAW=${3:-5000}

# Verificar root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Verificar argumentos
if [ -z "$VMID" ] || [ -z "$LIMIT_MIB_RAW" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "Usage: $0 <vmid> <limit_mib> [check_interval_ms]"
    echo ""
    echo "Arguments:"
    echo "  limit_mib         - Total VRAM limit in MiB (mebibytes)"
    echo "                      Examples: 8192 MiB = 8 GiB, 4096 MiB = 4 GiB"
    echo "  check_interval_ms - Check interval in milliseconds (default: 5000 = 5 seconds)"
    echo ""
    echo "Example:"
    echo "  $0 121 8192 5000    # Install in VM 121 with 8192 MiB (8 GiB) limit, check every 5000ms (5s)"
    echo "  $0 121 8192 2000    # Install in VM 121 with 8192 MiB (8 GiB) limit, check every 2000ms (2s)"
    exit 0
fi

# Convertir a decimal para evitar interpretación octal (ej: 0500 -> 500)
# Usar sed para quitar ceros iniciales o forzar base 10
LIMIT_MIB=$(echo "$LIMIT_MIB_RAW" | sed 's/^0*//')
CHECK_INTERVAL_MS=$(echo "$CHECK_INTERVAL_MS_RAW" | sed 's/^0*//')

# Si quedó vacío después de quitar ceros, usar 0
[ -z "$LIMIT_MIB" ] && LIMIT_MIB=0
[ -z "$CHECK_INTERVAL_MS" ] && CHECK_INTERVAL_MS=5000

# Detectar nodo
echo -e "${YELLOW}[*]${NC} Detecting node for VM $VMID..."
NODE=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | \
    python3 -c "import sys, json; \
    vms = json.load(sys.stdin); \
    vm = next((i for i in vms if i.get('vmid') == $VMID), None); \
    print(vm.get('node', '')) if vm else print('')" 2>/dev/null)

if [ -z "$NODE" ]; then
    echo -e "${RED}Error: VM $VMID not found in cluster${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} VM $VMID found on node: $NODE"

# Verificar guest agent
echo -e "${YELLOW}[*]${NC} Checking guest agent..."
AGENT_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null | \
    python3 -c "import sys, json; print(json.load(sys.stdin).get('agent', 0))" 2>/dev/null)

if [ "$AGENT_STATUS" != "1" ]; then
    echo -e "${RED}Error: Guest agent is not running in VM $VMID${NC}"
    echo "Install and enable qemu-guest-agent in the VM first"
    exit 1
fi

echo -e "${GREEN}✓${NC} Guest agent is running"

# Función para ejecutar comandos en la VM
exec_in_vm() {
    local cmd="$1"
    local escaped_cmd=$(echo "$cmd" | sed 's/"/\\"/g')
    
    local out=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "$escaped_cmd" --output-format json 2>/dev/null)
    local pid=$(echo "$out" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('pid', ''))" 2>/dev/null)
    
    if [ -z "$pid" ]; then
        return 1
    fi
    
    local count=0
    while [ $count -lt 120 ]; do
        sleep 1
        local status=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $pid --output-format json 2>/dev/null)
        if echo "$status" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if data.get('exited') else 1)" 2>/dev/null; then
            echo "$status" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('out-data', '')); exit(data.get('exitcode', 1))" 2>/dev/null
            return $?
        fi
        count=$((count+1))
        # Mostrar progreso cada 10 segundos
        if [ $((count % 10)) -eq 0 ]; then
            echo -n "." >&2
        fi
    done
    echo "Timeout waiting for command to complete" >&2
    return 1
}

# Obtener ruta de scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VRAM_KILLER_SCRIPT="$SCRIPT_DIR/vram_killer.sh"
INSTALL_SCRIPT="$SCRIPT_DIR/install_vram_killer.sh"

# Verificar que los scripts existen
if [ ! -f "$VRAM_KILLER_SCRIPT" ] || [ ! -f "$INSTALL_SCRIPT" ]; then
    echo -e "${RED}Error: Scripts not found${NC}"
    exit 1
fi

echo -e "${YELLOW}[*]${NC} Copying scripts to VM..."

# Crear directorio temporal en la VM
TMP_DIR="/tmp/vram_killer_install"
echo -e "${YELLOW}[*]${NC} Creating temp directory..."
TMP_OUTPUT=$(exec_in_vm "mkdir -p $TMP_DIR && echo 'OK'")
if [ $? -ne 0 ] || [ -z "$TMP_OUTPUT" ]; then
    echo -e "${RED}Error: Failed to create temp directory${NC}"
    exit 1
fi

# Copiar scripts usando base64 (método más confiable)
echo -e "${YELLOW}[*]${NC} Uploading vram_killer.sh..."
VRAM_B64=$(cat "$VRAM_KILLER_SCRIPT" | base64)
VRAM_OUTPUT=$(exec_in_vm "echo '$VRAM_B64' | base64 -d > $TMP_DIR/vram_killer.sh && chmod +x $TMP_DIR/vram_killer.sh && echo 'OK'")
if [ $? -ne 0 ] || [ -z "$VRAM_OUTPUT" ]; then
    echo -e "${RED}Error: Failed to upload vram_killer.sh${NC}"
    exit 1
fi

echo -e "${YELLOW}[*]${NC} Uploading install_vram_killer.sh..."
INSTALL_B64=$(cat "$INSTALL_SCRIPT" | base64)
INSTALL_OUTPUT=$(exec_in_vm "echo '$INSTALL_B64' | base64 -d > $TMP_DIR/install_vram_killer.sh && chmod +x $TMP_DIR/install_vram_killer.sh && echo 'OK'")
if [ $? -ne 0 ] || [ -z "$INSTALL_OUTPUT" ]; then
    echo -e "${RED}Error: Failed to upload install_vram_killer.sh${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Scripts copied"

# Instalar servicio
echo -e "${YELLOW}[*]${NC} Installing service in VM..."
INSTALL_RESULT=$(exec_in_vm "cd $TMP_DIR && ./install_vram_killer.sh $LIMIT_MIB $CHECK_INTERVAL_MS" 2>&1)
INSTALL_EXIT=$?

if [ $INSTALL_EXIT -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Service installed successfully"
    echo ""
    echo "$INSTALL_RESULT"
else
    echo -e "${RED}Error: Installation failed (exit code: $INSTALL_EXIT)${NC}"
    echo "$INSTALL_RESULT"
    exit 1
fi

# Verificar que el servicio se creó
echo -e "${YELLOW}[*]${NC} Verifying service installation..."
SERVICE_CHECK=$(exec_in_vm "test -f /etc/systemd/system/vram-killer.service && systemctl is-enabled vram-killer.service 2>&1 && echo 'ENABLED' || echo 'NOT_FOUND'")
if echo "$SERVICE_CHECK" | grep -q "ENABLED"; then
    echo -e "${GREEN}✓${NC} Service verified and enabled"
else
    echo -e "${RED}Error: Service was not created properly${NC}"
    echo "Check output: $SERVICE_CHECK"
    exit 1
fi

# Limpiar
exec_in_vm "rm -rf $TMP_DIR" >/dev/null 2>&1

echo ""
echo "=========================================="
echo -e "${GREEN}Installation completed${NC}"
echo "=========================================="
echo ""
echo "Service is installed and enabled."
echo "It should start automatically on next boot or you can start it now:"
echo "  pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command 'systemctl' --command 'start' --command 'vram-killer'"
