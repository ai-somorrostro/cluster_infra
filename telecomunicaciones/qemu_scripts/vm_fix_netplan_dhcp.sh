#!/bin/bash

# vm_fix_netplan_dhcp.sh - Configura netplan para usar MAC como identificador DHCP

set -e

if [ $# -lt 2 ]; then
    echo "Uso: $0 <nodo> <vmid1> [vmid2] ..."
    echo "Ejemplo: $0 pve-node-3 127 128 129"
    exit 1
fi

NODE=$1
shift
VMIDS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "Nodo: $NODE"
echo "VMs: ${VMIDS[*]}"
echo "Fix: Agregar dhcp-identifier: mac a netplan"
echo "=========================================="

# --- Funciones Helper ---
wait_for_pid() {
    local pid=$1
    local timeout=$2
    local count=0
    while [ $count -lt $timeout ]; do
        sleep 1
        local status=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $pid --output-format json 2>/dev/null || echo "")
        if echo "$status" | grep -q '"exited"'; then
            echo "$status"
            return 0
        fi
        echo -n "."
        count=$((count+1))
    done
    echo ""
    return 1
}

run_cmd() {
    local cmd_arr=("$@")
    local pvesh_args=""
    for arg in "${cmd_arr[@]}"; do
        local escaped_arg=$(echo "$arg" | sed 's/"/\\"/g')
        pvesh_args="$pvesh_args --command \"$escaped_arg\""
    done
    local out=$(eval pvesh create /nodes/$NODE/qemu/$VMID/agent/exec $pvesh_args --output-format json 2>/dev/null)
    local pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+')
    if [ -z "$pid" ]; then return 1; fi
    local res=$(wait_for_pid $pid 60)
    local exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
    return $exitcode
}

# --- Loop Principal ---

for VMID in "${VMIDS[@]}"; do
    echo -e "\n${YELLOW}[*]${NC} Procesando VM $VMID..."

    # Verificar estado
    VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
    if echo "$VM_STATUS" | grep -q '"status":"running"' && echo "$VM_STATUS" | grep -q '"agent":1'; then
        echo -e "${GREEN}[✓]${NC} VM corriendo y agente activo"
    else
        echo -e "${RED}[✗]${NC} VM no disponible o agente inactivo"
        continue
    fi

    # 1. Backup del archivo netplan original
    echo -e "${YELLOW}[*]${NC} Haciendo backup de netplan..."
    BACKUP_CMD="cp /etc/netplan/00-installer-config.yaml /etc/netplan/00-installer-config.yaml.bak 2>/dev/null || cp /etc/netplan/*.yaml /etc/netplan/backup.yaml 2>/dev/null || true"
    run_cmd "sh" "-c" "$BACKUP_CMD"

    # 2. Agregar dhcp-identifier: mac si no existe
    echo -e "${YELLOW}[*]${NC} Modificando netplan para usar MAC como identificador DHCP..."
    
    # Script sed para añadir dhcp-identifier: mac después de dhcp4: true
    # Solo lo añade si no existe ya
    FIX_CMD="sed -i '/dhcp4: true/!b; n; /dhcp-identifier/b; i\      dhcp-identifier: mac' /etc/netplan/00-installer-config.yaml"
    
    if run_cmd "sh" "-c" "$FIX_CMD"; then
        echo -e "${GREEN}[✓]${NC} Netplan modificado"
    else
        echo -e "${RED}[✗]${NC} Error al modificar netplan"
        continue
    fi

    # 3. Verificar el cambio (opcional, para debug)
    echo -e "${YELLOW}[*]${NC} Verificando cambios..."
    CHECK_CMD="grep -A2 'dhcp4: true' /etc/netplan/00-installer-config.yaml"
    run_cmd "sh" "-c" "$CHECK_CMD"

    # 4. Aplicar netplan
    echo -e "${YELLOW}[*]${NC} Aplicando netplan..."
    if run_cmd "netplan" "apply"; then
        echo -e "${GREEN}[✓]${NC} Netplan aplicado correctamente"
    else
        echo -e "${RED}[✗]${NC} Error al aplicar netplan"
        echo -e "${YELLOW}[!]${NC} Puedes restaurar backup: cp /etc/netplan/00-installer-config.yaml.bak /etc/netplan/00-installer-config.yaml"
        continue
    fi

    # 5. Reiniciar interfaz para forzar renovación de IP
    echo -e "${YELLOW}[*]${NC} Reiniciando interfaz ens18..."
    RESTART_CMD="ip link set ens18 down && sleep 2 && ip link set ens18 up"
    if run_cmd "sh" "-c" "$RESTART_CMD"; then
        echo -e "${GREEN}[✓]${NC} Interfaz reiniciada"
    else
        echo -e "${YELLOW}[!]${NC} No se pudo reiniciar interfaz (puede ser normal)"
    fi

    # Esperar a que obtenga IP
    sleep 5

    # 6. Mostrar nueva IP
    echo -e "${YELLOW}[*]${NC} Obteniendo IP actual..."
    NEW_IPS=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/network-get-interfaces --output-format json 2>/dev/null | grep -oP '"ip-address":"\K[0-9.]+' | grep -v "127.0.0.1" | grep -v "^172.17" || echo "")
    
    if [ -n "$NEW_IPS" ]; then
        echo -e "${GREEN}[✓]${NC} IPs detectadas:"
        echo "$NEW_IPS" | while read ip; do
            echo "  - $ip"
        done
    else
        echo -e "${YELLOW}[?]${NC} No se detectaron IPs (puede tardar unos segundos)"
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "Ahora cada VM usará su MAC como identificador DHCP"
echo "Las VMs futuras clonadas de esta obtendrán IPs únicas"
echo "=========================================="

