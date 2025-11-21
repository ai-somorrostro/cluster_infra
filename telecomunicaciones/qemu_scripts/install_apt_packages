#!/bin/bash

# install_apt_packages - Instala paquetes apt en múltiples VMs via SSH

set -e

if [ $# -lt 3 ]; then
    echo "Uso: $0 <usuario> <paquete1>[,paquete2,...] <ip1> [ip2] [ip3] ..."
    echo "Ejemplo: $0 root vim,curl,htop 192.168.1.10 192.168.1.11"
    echo "Ejemplo: $0 mikel \"neovim git docker.io\" 192.168.1.20"
    exit 1
fi

USER=$1
PACKAGES=$2
shift 2
IPS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Convertir paquetes separados por comas a espacios
PACKAGES=$(echo "$PACKAGES" | tr ',' ' ')

echo "=========================================="
echo "Instalando paquetes: $PACKAGES"
echo "En ${#IPS[@]} máquinas..."
echo "=========================================="

for IP in "${IPS[@]}"; do
    echo -e "\n${YELLOW}[*]${NC} Procesando: $IP"
    
    # Verificar conexión SSH
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -q "$USER@$IP" exit 2>/dev/null; then
        echo -e "${RED}[✗]${NC} No se pudo conectar a $IP"
        continue
    fi
    
    echo -e "${GREEN}[✓]${NC} Conexión establecida"
    
    # Actualizar cache de apt
    echo -e "${YELLOW}[*]${NC} Actualizando cache de apt..."
    if ssh "$USER@$IP" "sudo apt update" >/dev/null 2>&1; then
        echo -e "${GREEN}[✓]${NC} Cache actualizado"
    else
        echo -e "${RED}[✗]${NC} Error al actualizar cache"
        continue
    fi
    
    # Instalar paquetes
    echo -e "${YELLOW}[*]${NC} Instalando paquetes..."
    if ssh "$USER@$IP" "sudo DEBIAN_FRONTEND=noninteractive apt install -y $PACKAGES" 2>&1 | grep -q "Setting up\|already the newest version"; then
        echo -e "${GREEN}[✓]${NC} Paquetes instalados exitosamente"
        
        # Verificar cada paquete
        for PKG in $PACKAGES; do
            if ssh "$USER@$IP" "dpkg -l | grep -q \"^ii  $PKG \"" 2>/dev/null; then
                VERSION=$(ssh "$USER@$IP" "dpkg -l $PKG 2>/dev/null | grep ^ii | awk '{print \$3}'")
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

