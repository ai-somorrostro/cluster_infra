#!/bin/bash

# vm_dhcp_renew - Renueva la IP de VMs usando qemu-guest-agent via pvesh

set -e

if [ $# -lt 1 ]; then
    echo "Uso: $0 <vmid1> [vmid2] [vmid3] ..."
    echo "Ejemplo: $0 100 101 102"
    exit 1
fi

VMIDS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Obtener el nombre del nodo actual
NODE=$(hostname)

echo "=========================================="
echo "Renovando DHCP en ${#VMIDS[@]} VMs..."
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
    
    # Obtener la interfaz de red principal
    ROUTE_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command='["ip","route","show","default"]' 2>/dev/null)
    PID=$(echo "$ROUTE_OUTPUT" | grep -oP '"pid":\K[0-9]+')
    
    sleep 1
    
    INTERFACE=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid=$PID 2>/dev/null | grep -oP 'dev \K\S+' | head -n1)
    
    if [ -z "$INTERFACE" ]; then
        echo -e "${RED}[✗]${NC} No se pudo detectar la interfaz de red"
        continue
    fi
    
    echo -e "${YELLOW}[*]${NC} Interfaz detectada: $INTERFACE"
    
    # Release DHCP
    echo -e "${YELLOW}[*]${NC} Liberando IP..."
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command="[\"dhclient\",\"-r\",\"$INTERFACE\"]" >/dev/null 2>&1 || echo -e "${YELLOW}[!]${NC} No se pudo liberar IP (puede ser normal)"
    
    sleep 1
    
    # Renew DHCP
    echo -e "${YELLOW}[*]${NC} Renovando IP..."
    EXEC_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command="[\"dhclient\",\"$INTERFACE\"]" 2>/dev/null)
    RENEW_PID=$(echo "$EXEC_OUTPUT" | grep -oP '"pid":\K[0-9]+')
    
    sleep 2
    
    if [ -n "$RENEW_PID" ]; then
        echo -e "${GREEN}[✓]${NC} DHCP renovado exitosamente"
        
        # Mostrar la nueva IP
        IP_OUTPUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec -- command="[\"ip\",\"-4\",\"addr\",\"show\",\"$INTERFACE\"]" 2>/dev/null)
        IP_PID=$(echo "$IP_OUTPUT" | grep -oP '"pid":\K[0-9]+')
        sleep 1
        
        NEW_IP=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid=$IP_PID 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1)
        if [ -n "$NEW_IP" ]; then
            echo -e "${GREEN}[✓]${NC} Nueva IP: $NEW_IP"
        fi
    else
        echo -e "${RED}[✗]${NC} Error al renovar DHCP"
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "=========================================="
