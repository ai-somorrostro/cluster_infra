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
STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format=json 2>/dev/null | grep -oP '"status":"\K[^"]+' || echo "error")

if [ "$STATUS" == "error" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no existe en nodo $NODE"
    exit 1
fi

if [ "$STATUS" != "running" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no está corriendo (status: $STATUS)"
    exit 1
fi

echo -e "${GREEN}[✓]${NC} VM corriendo"

# Verificar qemu-guest-agent
echo -e "${YELLOW}[*]${NC} Verificando qemu-guest-agent..."
if ! pvesh get /nodes/$NODE/qemu/$VMID/agent/ping >/dev/null 2>&1; then
    echo -e "${RED}[✗]${NC} qemu-guest-agent no responde"
    exit 1
fi

echo -e "${GREEN}[✓]${NC} qemu-guest-agent activo"

# Actualizar cache de apt
echo -e "\n${YELLOW}[*]${NC} Actualizando cache de apt..."
UPDATE_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command='["apt","update"]' 2>/dev/null)
UPDATE_PID=$(echo "$UPDATE_OUTPUT" | grep -oP '"pid":\K[0-9]+')

sleep 3

if pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid=$UPDATE_PID >/dev/null 2>&1; then
    echo -e "${GREEN}[✓]${NC} Cache actualizado"
else
    echo -e "${RED}[✗]${NC} Error al actualizar cache"
    exit 1
fi

# Instalar paquetes
echo -e "\n${YELLOW}[*]${NC} Instalando paquetes..."
CMD="DEBIAN_FRONTEND=noninteractive apt install -y $PACKAGES"
INSTALL_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command="[\"sh\",\"-c\",\"$CMD\"]" 2>/dev/null)
INSTALL_PID=$(echo "$INSTALL_OUTPUT" | grep -oP '"pid":\K[0-9]+')

sleep 5

echo -e "${GREEN}[✓]${NC} Instalación completada"

# Verificar cada paquete
echo -e "\n${YELLOW}[*]${NC} Verificando instalación..."
for PKG in $PACKAGES; do
    CHECK_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command="[\"dpkg\",\"-l\",\"$PKG\"]" 2>/dev/null)
    CHECK_PID=$(echo "$CHECK_OUTPUT" | grep -oP '"pid":\K[0-9]+')
    sleep 1
    
    DPKG_OUTPUT=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid=$CHECK_PID 2>/dev/null || echo "")
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

