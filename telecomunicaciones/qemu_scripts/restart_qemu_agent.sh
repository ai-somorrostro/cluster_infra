#!/bin/bash

# restart_qemu_agent - Reinicia el qemu-guest-agent en múltiples VMs

set -e

if [ $# -lt 2 ]; then
    echo "Uso: $0 <usuario> <ip1> [ip2] [ip3] ..."
    echo "Ejemplo: $0 root 192.168.1.10 192.168.1.11 192.168.1.12"
    exit 1
fi

USER=$1
shift
IPS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "Procesando ${#IPS[@]} máquinas..."
echo "=========================================="

for IP in "${IPS[@]}"; do
    echo -e "\n${YELLOW}[*]${NC} Procesando: $IP"
    
    # Verificar conexión SSH
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -q "$USER@$IP" exit 2>/dev/null; then
        echo -e "${RED}[✗]${NC} No se pudo conectar a $IP"
        continue
    fi
    
    # Verificar si qemu-guest-agent está instalado
    if ! ssh "$USER@$IP" "which qemu-ga >/dev/null 2>&1 || systemctl status qemu-guest-agent >/dev/null 2>&1" 2>/dev/null; then
        echo -e "${RED}[✗]${NC} qemu-guest-agent no está instalado en $IP"
        continue
    fi
    
    echo -e "${GREEN}[✓]${NC} qemu-guest-agent encontrado"
    
    # Reiniciar el servicio
    if ssh "$USER@$IP" "systemctl restart qemu-guest-agent" 2>/dev/null; then
        echo -e "${GREEN}[✓]${NC} Servicio reiniciado exitosamente"
        
        # Verificar estado
        if ssh "$USER@$IP" "systemctl is-active qemu-guest-agent" 2>/dev/null | grep -q "active"; then
            echo -e "${GREEN}[✓]${NC} Servicio activo y funcionando"
        else
            echo -e "${RED}[✗]${NC} Servicio reiniciado pero no está activo"
        fi
    else
        echo -e "${RED}[✗]${NC} Error al reiniciar el servicio en $IP"
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "=========================================="

