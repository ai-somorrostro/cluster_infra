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
LIMIT_MIB=$2
CHECK_INTERVAL_MS=${3:-5000}

# Verificar root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Verificar argumentos
if [ -z "$VMID" ] || [ -z "$LIMIT_MB" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
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
    while [ $count -lt 30 ]; do
        sleep 1
        local status=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $pid --output-format json 2>/dev/null)
        if echo "$status" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if data.get('exited') else 1)" 2>/dev/null; then
            echo "$status" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('out-data', '')); exit(data.get('exitcode', 1))" 2>/dev/null
            return $?
        fi
        count=$((count+1))
    done
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
exec_in_vm "mkdir -p $TMP_DIR" >/dev/null 2>&1

# Copiar scripts usando base64 (método más confiable)
echo -e "${YELLOW}[*]${NC} Uploading vram_killer.sh..."
cat "$VRAM_KILLER_SCRIPT" | base64 | exec_in_vm "cat > $TMP_DIR/vram_killer.sh.b64 && base64 -d $TMP_DIR/vram_killer.sh.b64 > $TMP_DIR/vram_killer.sh && chmod +x $TMP_DIR/vram_killer.sh && rm $TMP_DIR/vram_killer.sh.b64" >/dev/null 2>&1

echo -e "${YELLOW}[*]${NC} Uploading install_vram_killer.sh..."
cat "$INSTALL_SCRIPT" | base64 | exec_in_vm "cat > $TMP_DIR/install_vram_killer.sh.b64 && base64 -d $TMP_DIR/install_vram_killer.sh.b64 > $TMP_DIR/install_vram_killer.sh && chmod +x $TMP_DIR/install_vram_killer.sh && rm $TMP_DIR/install_vram_killer.sh.b64" >/dev/null 2>&1

echo -e "${GREEN}✓${NC} Scripts copied"

# Instalar servicio
echo -e "${YELLOW}[*]${NC} Installing service in VM..."
INSTALL_OUTPUT=$(exec_in_vm "cd $TMP_DIR && ./install_vram_killer.sh $LIMIT_MIB $CHECK_INTERVAL_MS" 2>&1)

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Service installed successfully"
    echo ""
    echo "$INSTALL_OUTPUT"
else
    echo -e "${RED}Error: Installation failed${NC}"
    echo "$INSTALL_OUTPUT"
    exit 1
fi

# Limpiar
exec_in_vm "rm -rf $TMP_DIR" >/dev/null 2>&1

echo ""
echo "=========================================="
echo -e "${GREEN}Installation completed${NC}"
echo "=========================================="
echo ""
echo "To check status from host:"
echo "  pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command 'systemctl' --command 'status' --command 'vram-killer'"
echo ""
echo "To view logs:"
echo "  pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command 'tail' --command '-f' --command '/var/log/vram_killer.log'"
