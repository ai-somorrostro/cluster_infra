#!/bin/bash

# vm_apt_install.sh - Instala paquetes apt en una VM usando pvesh

set -e

if [ $# -lt 3 ]; then
    echo "Uso: $0 <nodo> <vmid> <paquete1> [paquete2] [paquete3] ..."
    echo "Ejemplo: $0 pve 100 vim curl htop"
    exit 1
fi

NODE=$1
VMID=$2
shift 2
PACKAGES="$@"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "Nodo: $NODE"
echo "VMID: $VMID"
echo "Paquetes: $PACKAGES"
echo "=========================================="

# Verificar que la VM existe y está corriendo
echo -e "\n${YELLOW}[*]${NC} Verificando VM..."
VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)

if [ -z "$VM_STATUS" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no existe en nodo $NODE"
    exit 1
fi

STATUS=$(echo "$VM_STATUS" | grep -oP '"status":"\K[^"]+')
if [ "$STATUS" != "running" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no está corriendo (status: $STATUS)"
    exit 1
fi

echo -e "${GREEN}[✓]${NC} VM corriendo"

# Verificar qemu-guest-agent está habilitado
echo -e "${YELLOW}[*]${NC} Verificando qemu-guest-agent..."
AGENT_ENABLED=$(echo "$VM_STATUS" | grep -oP '"agent":\K[0-9]+' || echo "0")

if [ "$AGENT_ENABLED" == "0" ]; then
    echo -e "${RED}[✗]${NC} qemu-guest-agent no está habilitado"
    exit 1
fi

echo -e "${GREEN}[✓]${NC} qemu-guest-agent activo"

# Función para leer archivo de log de la VM
read_vm_file() {
    local vmid=$1
    local file=$2
    local cat_out=$(pvesh create /nodes/$NODE/qemu/$vmid/agent/exec --command "cat" --command "$file" --output-format json 2>/dev/null)
    local pid=$(echo "$cat_out" | grep -oP '"pid":\K[0-9]+')
    if [ -n "$pid" ]; then
        sleep 1
        pvesh get /nodes/$NODE/qemu/$vmid/agent/exec-status --pid $pid --output-format json 2>/dev/null | grep -oP '"out-data":"\K.*"' | sed 's/\\n/\n/g' | sed 's/\\t/\t/g' | sed 's/\\r//g' | sed 's/^"//' | sed 's/"$//'
    fi
}

# Actualizar cache de apt
echo -e "\n${YELLOW}[*]${NC} Actualizando cache de apt..."
# Redirigimos salida a archivo temporal para debug
UPDATE_CMD="apt-get update > /tmp/apt_update.log 2>&1"
UPDATE_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "$UPDATE_CMD" --output-format json 2>/dev/null)
UPDATE_PID=$(echo "$UPDATE_OUTPUT" | grep -oP '"pid":\K[0-9]+')

if [ -z "$UPDATE_PID" ]; then
    echo -e "${RED}[✗]${NC} Error al ejecutar apt update"
    exit 1
fi

# Esperar y verificar el resultado
for i in {1..30}; do
    sleep 1
    EXEC_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $UPDATE_PID --output-format json 2>/dev/null || echo "")
    if echo "$EXEC_STATUS" | grep -q '"exited"'; then
        break
    fi
    echo -n "."
done
echo ""

EXIT_CODE=$(echo "$EXEC_STATUS" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
if [ "$EXIT_CODE" == "0" ]; then
    echo -e "${GREEN}[✓]${NC} Cache actualizado"
else
    echo -e "${RED}[✗]${NC} Error al actualizar cache (exit code: $EXIT_CODE)"
    echo -e "${YELLOW}--- Output del error ---${NC}"
    read_vm_file $VMID "/tmp/apt_update.log"
    echo -e "${YELLOW}------------------------${NC}"
    exit 1
fi

# Instalar paquetes
echo -e "\n${YELLOW}[*]${NC} Instalando paquetes..."
# Construir el comando de instalación complejo
INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES > /tmp/apt_install.log 2>&1"
INSTALL_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "$INSTALL_CMD" --output-format json 2>/dev/null)
INSTALL_PID=$(echo "$INSTALL_OUTPUT" | grep -oP '"pid":\K[0-9]+')

if [ -z "$INSTALL_PID" ]; then
    echo -e "${RED}[✗]${NC} Error al ejecutar apt install"
    exit 1
fi

# Esperar y verificar el resultado
for i in {1..120}; do # Aumentado tiempo de espera para instalación a 2 minutos
    sleep 1
    EXEC_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $INSTALL_PID --output-format json 2>/dev/null || echo "")
    if echo "$EXEC_STATUS" | grep -q '"exited"'; then
        break
    fi
    echo -n "."
done
echo ""

EXIT_CODE=$(echo "$EXEC_STATUS" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
if [ "$EXIT_CODE" == "0" ]; then
    echo -e "${GREEN}[✓]${NC} Instalación completada"
else
    echo -e "${RED}[✗]${NC} Error al instalar (exit code: $EXIT_CODE)"
    echo -e "${YELLOW}--- Output del error ---${NC}"
    read_vm_file $VMID "/tmp/apt_install.log"
    echo -e "${YELLOW}------------------------${NC}"
    exit 1
fi

# Verificar cada paquete
echo -e "\n${YELLOW}[*]${NC} Verificando instalación..."
for PKG in $PACKAGES; do
    CHECK_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "dpkg" --command "-l" --command "$PKG" --output-format json 2>/dev/null)
    CHECK_PID=$(echo "$CHECK_OUTPUT" | grep -oP '"pid":\K[0-9]+')
    sleep 2
    
    DPKG_OUTPUT=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $CHECK_PID --output-format json 2>/dev/null || echo "")
    if echo "$DPKG_OUTPUT" | grep -q "^ii"; then
        VERSION=$(echo "$DPKG_OUTPUT" | grep "^ii" | awk '{print $3}')
        echo -e "${GREEN}[✓]${NC} $PKG ($VERSION)"
    else
        echo -e "${RED}[✗]${NC} $PKG (no instalado)"
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "=========================================="
