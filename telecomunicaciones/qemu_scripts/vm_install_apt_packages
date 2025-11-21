#!/bin/bash

# vm_install_apt_packages - Instala paquetes apt en VMs usando qemu-guest-agent via pvesh

set -e

if [ $# -lt 2 ]; then
    echo "Uso: $0 <paquete1>[,paquete2,...] <vmid1> [vmid2] [vmid3] ..."
    echo "Ejemplo: $0 vim,curl,htop 100 101 102"
    echo "Ejemplo: $0 \"neovim git docker.io\" 100"
    exit 1
fi

PACKAGES=$1
shift
VMIDS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Convertir paquetes separados por comas a espacios
PACKAGES=$(echo "$PACKAGES" | tr ',' ' ')

# Obtener el nombre del nodo actual
NODE=$(hostname)

echo "=========================================="
echo "Instalando paquetes: $PACKAGES"
echo "En ${#VMIDS[@]} VMs..."
echo "Nodo: $NODE"
echo "=========================================="

for VMID in "${VMIDS[@]}"; do
    echo -e "\n${YELLOW}[*]${NC} Procesando VM: $VMID"
    
    # Verificar que la VM existe y está corriendo
    STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format=json 2>/dev/null | grep -oP '"status":"\K[^"]+' || echo "error")
    
    if [ "$STATUS" == "error" ]; then
        echo -e "${RED}[✗]${NC} VM $VMID no existe"
        continue
    fi
    
    if [ "$STATUS" != "running" ]; then
        echo -e "${RED}[✗]${NC} VM $VMID no está corriendo (status: $STATUS)"
        continue
    fi
    
    # Verificar que qemu-guest-agent está disponible
    if ! pvesh get /nodes/$NODE/qemu/$VMID/agent/ping >/dev/null 2>&1; then
        echo -e "${RED}[✗]${NC} qemu-guest-agent no responde en VM $VMID"
        continue
    fi
    
    echo -e "${GREEN}[✓]${NC} qemu-guest-agent activo"
    
    # Actualizar cache de apt
    echo -e "${YELLOW}[*]${NC} Actualizando cache de apt..."
    UPDATE_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command='["apt","update"]' 2>/dev/null)
    UPDATE_PID=$(echo "$UPDATE_OUTPUT" | grep -oP '"pid":\K[0-9]+')
    
    if [ -n "$UPDATE_PID" ]; then
        sleep 3
        if pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid=$UPDATE_PID >/dev/null 2>&1; then
            echo -e "${GREEN}[✓]${NC} Cache actualizado"
        else
            echo -e "${RED}[✗]${NC} Error al actualizar cache"
            continue
        fi
    else
        echo -e "${RED}[✗]${NC} Error al actualizar cache"
        continue
    fi
    
    # Instalar paquetes
    echo -e "${YELLOW}[*]${NC} Instalando paquetes..."
    
    # Construir comando con DEBIAN_FRONTEND
    CMD="DEBIAN_FRONTEND=noninteractive apt install -y $PACKAGES"
    INSTALL_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command="[\"sh\",\"-c\",\"$CMD\"]" 2>/dev/null)
    INSTALL_PID=$(echo "$INSTALL_OUTPUT" | grep -oP '"pid":\K[0-9]+')
    
    if [ -n "$INSTALL_PID" ]; then
        sleep 5
        echo -e "${GREEN}[✓]${NC} Paquetes instalados exitosamente"
        
        # Verificar cada paquete
        for PKG in $PACKAGES; do
            CHECK_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command="[\"dpkg\",\"-l\",\"$PKG\"]" 2>/dev/null)
            CHECK_PID=$(echo "$CHECK_OUTPUT" | grep -oP '"pid":\K[0-9]+')
            sleep 1
            
            if pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid=$CHECK_PID 2>/dev/null | grep -q "^ii"; then
                VERSION=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid=$CHECK_PID 2>/dev/null | grep "^ii" | awk '{print $3}')
                echo -e "  ${GREEN}✓${NC} $PKG ($VERSION)"
            else
                echo -e "  ${YELLOW}!${NC} $PKG (no se pudo verificar)"
            fi
        done
    else
        echo -e "${RED}[✗]${NC} Error al instalar paquetes"
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "=========================================="
